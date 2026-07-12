#!/usr/bin/env bash
set -euo pipefail

REPO="sema-lisp/sema"
API="https://api.github.com/repos/${REPO}"
DL_BASE="https://github.com/${REPO}/releases/download"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON="$(command -v python3 || command -v python || true)"

: "${GH_TOKEN:=}"
: "${INPUT_SEMA_VERSION:=}"
: "${INPUT_VERSION:=}"          # deprecated alias for INPUT_SEMA_VERSION
: "${INPUT_CHECK_LATEST:=false}"
: "${INPUT_DOWNLOAD_URL:=}"

log()  { echo "$*"; }
warn() { echo "::warning::$*"; }
die()  { echo "::error::$*" >&2; exit 1; }

[ -n "$PYTHON" ] || die "python3 (or python) is required but was not found on PATH"

auth_hdr=()
[ -n "$GH_TOKEN" ] && auth_hdr=(-H "Authorization: Bearer ${GH_TOKEN}")

# Bounded, retrying network options shared by every curl call: retry transient
# failures (incl. connection-refused), cap the connect phase, and cap total time
# so a hard network stall fails closed in bounded time instead of hanging.
NET_OPTS=(--retry 3 --retry-connrefused --connect-timeout 30 --max-time 600)

gh_api() {
  # shellcheck disable=SC2086
  curl -fsSL "${NET_OPTS[@]}" ${auth_hdr[@]+"${auth_hdr[@]}"} \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" "$1"
}
# shellcheck disable=SC2086
dl() { curl -fsSL "${NET_OPTS[@]}" ${auth_hdr[@]+"${auth_hdr[@]}"} -o "$2" "$1"; }

# --- 1. Resolve requested version --------------------------------
REQUESTED="${INPUT_SEMA_VERSION:-$INPUT_VERSION}"
if [ -z "$REQUESTED" ]; then
  if [ -f .sema-version ]; then
    REQUESTED="$(tr -d '[:space:]' < .sema-version)"
  elif [ -f .tool-versions ]; then
    REQUESTED="$(awk '$1=="sema"{print $2; exit}' .tool-versions)"
  fi
fi
REQUESTED="${REQUESTED:-latest}"

if [ "$REQUESTED" = "latest" ]; then
  TAG="$(gh_api "${API}/releases/latest" | "$PYTHON" -c 'import json,sys;print(json.load(sys.stdin)["tag_name"])')"
else
  TAG="v${REQUESTED#v}"
fi
VERSION="${TAG#v}"
log "Resolved Sema version: ${VERSION} (${TAG})"

# --- 2. Map runner to target triple ------------------------------
case "${RUNNER_OS}-${RUNNER_ARCH}" in
  Linux-X64)   TARGET="x86_64-unknown-linux-gnu"  ;;
  Linux-ARM64) TARGET="aarch64-unknown-linux-gnu" ;;
  macOS-X64)   TARGET="x86_64-apple-darwin"       ;;
  macOS-ARM64) TARGET="aarch64-apple-darwin"      ;;
  Windows-X64) TARGET="x86_64-pc-windows-msvc"    ;;
  *) die "Unsupported platform: ${RUNNER_OS}-${RUNNER_ARCH}" ;;
esac

# --- 3. Tool-cache short-circuit ---------------------------------
INSTALL_DIR="${RUNNER_TOOL_CACHE}/sema/${VERSION}/${RUNNER_ARCH}"
CACHE_HIT=false
URL="cache"
if [ -x "${INSTALL_DIR}/sema" ] || [ -x "${INSTALL_DIR}/sema.exe" ]; then
  log "Sema ${VERSION} found in tool cache"
  CACHE_HIT=true
fi

if [ "$CACHE_HIT" = false ]; then
  mkdir -p "${INSTALL_DIR}"
  TMP="$(mktemp -d)"

  # --- 4. Resolve the asset (manifest-driven, with fallback) -----
  CHECKSUM_ASSET=""
  if [ -n "$INPUT_DOWNLOAD_URL" ]; then
    URL="$INPUT_DOWNLOAD_URL"
    ASSET="$(basename "$URL")"
  else
    if dl "${DL_BASE}/${TAG}/dist-manifest.json" "${TMP}/dist-manifest.json" 2>/dev/null \
       && MAP="$("$PYTHON" "${SCRIPT_DIR}/resolve_asset.py" "$TARGET" < "${TMP}/dist-manifest.json")"; then
      ASSET="$(printf '%s\n' "$MAP" | sed -n 1p)"
      CHECKSUM_ASSET="$(printf '%s\n' "$MAP" | sed -n 2p)"
    else
      warn "dist-manifest.json resolution failed; falling back to hardcoded asset name"
      case "$TARGET" in
        *windows*) ASSET="sema-lang-${TARGET}.zip" ;;
        *)         ASSET="sema-lang-${TARGET}.tar.xz" ;;
      esac
      CHECKSUM_ASSET="${ASSET}.sha256"
    fi
    if [ -z "$CHECKSUM_ASSET" ]; then CHECKSUM_ASSET="${ASSET}.sha256"; fi
    URL="${DL_BASE}/${TAG}/${ASSET}"
  fi

  log "Downloading ${URL}"
  dl "$URL" "${TMP}/${ASSET}"

  # --- 5. Checksum verify (mandatory when the checksum exists) ----
  # Distinguish a genuinely-absent checksum (HTTP 404 -> warn + proceed) from a
  # fetch failure for a checksum we expect to exist (-> hard fail, never install
  # unverified). No -f here so we can read the status code even on 4xx.
  if [ -n "$CHECKSUM_ASSET" ]; then
    # shellcheck disable=SC2086
    SUM_HTTP="$(curl -sSL "${NET_OPTS[@]}" ${auth_hdr[@]+"${auth_hdr[@]}"} \
      -o "${TMP}/${ASSET}.sha256" -w '%{http_code}' \
      "${DL_BASE}/${TAG}/${CHECKSUM_ASSET}" || true)"
    if [ "$SUM_HTTP" = "200" ]; then
      ( cd "$TMP"
        if command -v sha256sum >/dev/null 2>&1; then sha256sum -c "${ASSET}.sha256"
        else shasum -a 256 -c "${ASSET}.sha256"; fi )
    elif [ "$SUM_HTTP" = "404" ]; then
      warn "No checksum published for ${ASSET} (HTTP 404); skipping verification"
    else
      die "Failed to fetch checksum for ${ASSET} (HTTP ${SUM_HTTP:-unknown}); refusing to install unverified. Re-run the job; a persistent failure may indicate a network or GitHub Releases outage."
    fi
  else
    warn "No checksum available for ${ASSET}; skipping verification"
  fi

  # --- 6. Extract ------------------------------------------------
  case "$ASSET" in
    *.tar.xz) tar --xz -xf "${TMP}/${ASSET}" -C "${INSTALL_DIR}" --strip-components=1 ;;
    *.tar.gz) tar -xzf   "${TMP}/${ASSET}" -C "${INSTALL_DIR}" --strip-components=1 ;;
    *.zip)    unzip -q   "${TMP}/${ASSET}" -d "${INSTALL_DIR}" ;;
    *) die "Unknown archive type: ${ASSET}" ;;
  esac
  # defensive: flatten if the binary didn't land at the root
  if [ ! -e "${INSTALL_DIR}/sema" ] && [ ! -e "${INSTALL_DIR}/sema.exe" ]; then
    INNER="$(find "${INSTALL_DIR}" -maxdepth 3 \( -name sema -o -name sema.exe \) | head -1)"
    [ -n "$INNER" ] && mv "$(dirname "$INNER")"/* "${INSTALL_DIR}/"
  fi
  chmod +x "${INSTALL_DIR}/sema" 2>/dev/null || true
  rm -rf "$TMP"
fi

# --- 7. Expose to later steps ------------------------------------
echo "${INSTALL_DIR}" >> "${GITHUB_PATH}"
{
  echo "sema-version=${VERSION}"
  echo "version=${VERSION}"
  echo "sema-path=${INSTALL_DIR}"
  echo "cache-hit=${CACHE_HIT}"
  echo "cachekey=sema-${VERSION}-${TARGET}"
  echo "download-url=${URL}"
} >> "${GITHUB_OUTPUT}"

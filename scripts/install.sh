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
: "${INPUT_DOWNLOAD_URL:=}"

log()  { echo "$*"; }
warn() { echo "::warning::$*"; }
die()  { echo "::error::$*" >&2; exit 1; }

[ -n "$PYTHON" ] || die "python3 (or python) is required but was not found on PATH"

# A version/tag must be a plain version string. Rejecting '/', '..', and any
# non-version character is what stops a hostile .sema-version / .tool-versions in
# a fork's checkout from steering the download URL to another repo (path
# traversal): curl normalizes '../' in the path, so an unvalidated version would
# let an attacker serve their own archive AND a matching checksum. Fail closed.
require_safe_version() {  # $1 = value, $2 = where it came from (for the message)
  case "$1" in
    ""|*..*|*/*|*[!0-9A-Za-z.+-]*)
      die "Refusing unsafe Sema version '$1' (from $2): must match e.g. 1.30.0 / v1.30.0." ;;
  esac
  printf '%s' "$1" | grep -Eq '^v?[0-9]+([.][0-9]+)*([-+.][0-9A-Za-z.]+)?$' \
    || die "Refusing malformed Sema version '$1' (from $2): expected e.g. 1.30.0 / v1.30.0."
}

auth_hdr=()
[ -n "$GH_TOKEN" ] && auth_hdr=(-H "Authorization: Bearer ${GH_TOKEN}")

# Bounded, retrying network options shared by every curl call.
NET_OPTS=(--retry 3 --retry-connrefused --connect-timeout 30 --max-time 600)

# API calls carry the token (rate limits). Public release assets do NOT — sending
# Authorization to the github.com -> CDN redirect target risks leaking the token
# to a third-party host on older curl, and public assets need no auth anyway.
gh_api() {
  # shellcheck disable=SC2086
  curl -fsSL "${NET_OPTS[@]}" ${auth_hdr[@]+"${auth_hdr[@]}"} \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" "$1"
}
dl()      { curl -fsSL "${NET_OPTS[@]}" -o "$2" "$1"; }              # fail-closed download (no auth)
http_to() { curl -sSL "${NET_OPTS[@]}" -o "$2" -w '%{http_code}' "$1" || true; }  # status, no -f

# --- 1. Resolve requested version --------------------------------
# Precedence: sema-version input -> deprecated `version` input -> .sema-version
# -> .tool-versions -> latest. (sema-version defaults to "" in action.yml so the
# fallbacks actually fire.) Version-file lookup is skipped when download-url is set.
REQUESTED="${INPUT_SEMA_VERSION:-}"
SRC="input 'sema-version'"
if [ -z "$REQUESTED" ] && [ -n "$INPUT_VERSION" ]; then
  REQUESTED="$INPUT_VERSION"
  SRC="input 'version'"
  warn "input 'version' is deprecated; use 'sema-version' (the alias is removed in v2)"
fi
if [ -z "$REQUESTED" ] && [ -z "$INPUT_DOWNLOAD_URL" ]; then
  if [ -f .sema-version ]; then
    REQUESTED="$(tr -d '[:space:]' < .sema-version)"; SRC=".sema-version"
  elif [ -f .tool-versions ]; then
    REQUESTED="$(awk '$1=="sema"{print $2; exit}' .tool-versions)"; SRC=".tool-versions"
  fi
fi
REQUESTED="${REQUESTED:-latest}"

# --- 2. Map runner to target triple ------------------------------
case "${RUNNER_OS}-${RUNNER_ARCH}" in
  Linux-X64)   TARGET="x86_64-unknown-linux-gnu"  ;;
  Linux-ARM64) TARGET="aarch64-unknown-linux-gnu" ;;
  macOS-X64)   TARGET="x86_64-apple-darwin"       ;;
  macOS-ARM64) TARGET="aarch64-apple-darwin"      ;;
  Windows-X64) TARGET="x86_64-pc-windows-msvc"    ;;
  *) die "Unsupported platform: ${RUNNER_OS}-${RUNNER_ARCH}" ;;
esac

# --- 3. Resolve the concrete version/tag -------------------------
if [ -n "$INPUT_DOWNLOAD_URL" ]; then
  # Escape hatch: install exactly this archive. Report an honest version derived
  # from the URL when it looks like a release asset, else "custom".
  VERSION="$(printf '%s' "$INPUT_DOWNLOAD_URL" | grep -Eo 'v?[0-9]+\.[0-9]+\.[0-9]+' | head -1 | sed 's/^v//')"
  VERSION="${VERSION:-custom}"
  TAG=""
else
  if [ "$REQUESTED" = "latest" ]; then
    TAG="$(gh_api "${API}/releases/latest" | "$PYTHON" -c 'import json,sys;print(json.load(sys.stdin)["tag_name"])')"
    require_safe_version "$TAG" "GitHub releases API"
  else
    require_safe_version "$REQUESTED" "$SRC"
    TAG="v${REQUESTED#v}"
  fi
  VERSION="${TAG#v}"
fi
log "Resolved Sema version: ${VERSION}${TAG:+ ($TAG)}"

# --- 4. Tool-cache short-circuit ---------------------------------
INSTALL_DIR="${RUNNER_TOOL_CACHE}/sema/${VERSION}/${RUNNER_ARCH}"
CACHE_HIT=false
URL="cache"
if [ -x "${INSTALL_DIR}/sema" ] || [ -x "${INSTALL_DIR}/sema.exe" ]; then
  log "Sema ${VERSION} found in tool cache"
  CACHE_HIT=true
fi

if [ "$CACHE_HIT" = false ]; then
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT

  # --- 5. Resolve the asset (manifest-driven, with fallback) -----
  # CHECKSUM_MODE: "required" (known release triple — a missing checksum is fatal)
  # or "optional" (download-url escape hatch — the user owns the URL's trust).
  CHECKSUM_MODE="required"
  if [ -n "$INPUT_DOWNLOAD_URL" ]; then
    URL="$INPUT_DOWNLOAD_URL"
    ASSET="$(basename "$URL")"
    CHECKSUM_URL="${URL}.sha256"
    CHECKSUM_MODE="optional"
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
    [ -z "$CHECKSUM_ASSET" ] && CHECKSUM_ASSET="${ASSET}.sha256"
    URL="${DL_BASE}/${TAG}/${ASSET}"
    CHECKSUM_URL="${DL_BASE}/${TAG}/${CHECKSUM_ASSET}"
    # The manifest is release-controlled: never let its asset name be a path.
    case "$CHECKSUM_ASSET" in */*|*..*|"") die "Unsafe checksum name from manifest: '$CHECKSUM_ASSET'" ;; esac
  fi
  # Whatever produced ASSET, it must be a bare filename (no traversal into $TMP).
  case "$ASSET" in */*|*..*|"") die "Unsafe asset name: '$ASSET'" ;; esac

  log "Downloading ${URL}"
  dl "$URL" "${TMP}/${ASSET}" \
    || die "Failed to download ${URL} — does Sema version '${VERSION}' exist for ${TARGET}?"

  # --- 6. Checksum verify ----------------------------------------
  # Fail-closed for a real release asset: a 200 verifies, a 404 for a triple we
  # expect a checksum for is fatal, and any other status is fatal. Only the
  # explicit download-url escape hatch is allowed to proceed on a missing sidecar.
  SUM_HTTP="$(http_to "${CHECKSUM_URL}" "${TMP}/${ASSET}.sha256")"
  if [ "$SUM_HTTP" = "200" ]; then
    ( cd "$TMP"
      if command -v sha256sum >/dev/null 2>&1; then sha256sum -c "${ASSET}.sha256"
      else shasum -a 256 -c "${ASSET}.sha256"; fi )
  elif [ "$SUM_HTTP" = "404" ] && [ "$CHECKSUM_MODE" = "optional" ]; then
    warn "No checksum at ${CHECKSUM_URL} (HTTP 404); installing unverified (download-url escape hatch)"
  elif [ "$SUM_HTTP" = "404" ]; then
    die "No checksum published for ${ASSET} (HTTP 404); refusing to install unverified."
  else
    die "Failed to fetch checksum for ${ASSET} (HTTP ${SUM_HTTP:-unknown}); refusing to install unverified. Re-run the job; a persistent failure may indicate a network or GitHub Releases outage."
  fi

  # --- 7. Extract (unified; no unzip dependency, no strip assumption) ---
  # Extract into a staging dir, locate the binary wherever it landed (nested or
  # flat, tar.xz or zip — bsdtar on Windows/macOS reads zip, GNU tar auto-detects
  # xz), then populate INSTALL_DIR only on success so a partial extract can never
  # poison the tool cache for a later run.
  STAGE="${TMP}/extract"
  mkdir -p "$STAGE"
  case "$ASSET" in
    *.zip)
      # Git Bash's `tar` is GNU tar and can't read zip. Prefer unzip (present on
      # hosted Windows), fall back to PowerShell's Expand-Archive (always on
      # Windows) so minimal self-hosted runners without unzip still work.
      if command -v unzip >/dev/null 2>&1; then
        unzip -q "${TMP}/${ASSET}" -d "$STAGE"
      elif command -v powershell >/dev/null 2>&1; then
        powershell -NoProfile -NonInteractive -Command \
          "Expand-Archive -LiteralPath '$(cygpath -w "${TMP}/${ASSET}")' -DestinationPath '$(cygpath -w "$STAGE")' -Force"
      else
        die "No zip extractor found (need 'unzip' or PowerShell)."
      fi ;;
    *.tar.gz|*.tgz|*.tar.xz|*.txz|*.tar) tar -xf "${TMP}/${ASSET}" -C "$STAGE" ;;
    *) die "Unknown archive type: ${ASSET}" ;;
  esac
  BIN="$(find "$STAGE" -type f \( -name sema -o -name sema.exe \) | head -1)"
  [ -n "$BIN" ] || die "Archive ${ASSET} did not contain a 'sema' binary"
  mkdir -p "${INSTALL_DIR}"
  cp -R "$(dirname "$BIN")/." "${INSTALL_DIR}/"
  chmod +x "${INSTALL_DIR}/sema" 2>/dev/null || true

  rm -rf "$TMP"
  trap - EXIT
fi

# --- 8. Expose to later steps ------------------------------------
echo "${INSTALL_DIR}" >> "${GITHUB_PATH}"
{
  echo "sema-version=${VERSION}"
  echo "version=${VERSION}"
  echo "sema-path=${INSTALL_DIR}"
  echo "cache-hit=${CACHE_HIT}"
  echo "cache-key=sema-${VERSION}-${TARGET}"
  echo "download-url=${URL}"
} >> "${GITHUB_OUTPUT}"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  echo "Installed **Sema ${VERSION}** (\`${TARGET}\`)$([ "$CACHE_HIT" = true ] && echo ' — from tool cache')" >> "$GITHUB_STEP_SUMMARY"
fi

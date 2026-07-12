# setup-sema Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a best-in-class composite GitHub Action that installs the Sema language onto any supported CI runner, resolving assets from cargo-dist's `dist-manifest.json`, verifying checksums, caching in the runner tool cache, and exposing the installed version + path to later steps.

**Architecture:** A thin `action.yml` (composite) delegates to `scripts/install.sh`, which resolves the version (input / `.sema-version` / `.tool-versions` / `latest`), maps the runner to a Rust target triple, resolves the exact asset + checksum from `dist-manifest.json` (with a hardcoded fallback), downloads + verifies + extracts, and writes outputs. A tiny `scripts/resolve_asset.py` parses the manifest. Local acceptance runs the real script on this macOS-ARM64 host; the CI matrix (`.github/workflows/test.yml`) is the cross-OS acceptance gate.

**Tech Stack:** GitHub Actions (composite), bash, python3 (runner-provided), cargo-dist release artifacts, `gh` CLI for local testing.

## Global Constraints

- Target repo: `sema-lisp/sema`; release API base `https://api.github.com/repos/sema-lisp/sema`.
- Real asset naming (cargo-dist 0.30.4): `sema-lang-<triple>.tar.xz` (unix) / `sema-lang-<triple>.zip` (windows); per-file `<asset>.sha256`; a `dist-manifest.json` per release. **No version in the archive filename.**
- Binary inside every archive is named `sema` (Cargo package is `sema-lang`, binary target `sema`).
- Unix tarballs nest all files under one root dir → extract with `tar --strip-components=1`. Windows zip is flat → no strip.
- Supported runners: `Linux-X64`, `Linux-ARM64`, `macOS-X64`, `macOS-ARM64`, `Windows-X64`. Anything else → hard error.
- Canonical version input is `sema-version`; `version` is a deprecated alias.
- Checksum verification is mandatory when a checksum exists; only a genuinely-absent checksum downgrades to `::warning`.
- `set -euo pipefail` in every script; every `curl` uses `-fsSL --retry 3`.
- Manifest/API failure must **degrade** (warning + fallback), never hard-fail the job on a transient hiccup — except a checksum *mismatch*, which is a hard fail.
- Python may be `python3` or `python` (Windows Git Bash) — detect it, never assume.
- No `dist/`, no node build step, no `jq` dependency.

---

### Task 1: Repo scaffolding

**Files:**
- Create: `LICENSE` (MIT), `.gitignore`, `README.md` (skeleton, finalized in Task 8)
- The repo is already `git init`ed and holds the spec under `docs/superpowers/`.

**Interfaces:**
- Produces: a clean repo root ready for `action.yml` + `scripts/`.

- [ ] **Step 1: Create `.gitignore`**

```
# nothing to build; keep the repo clean of local test scratch
*.log
smoke.sema
/tmp-tool-cache/
```

- [ ] **Step 2: Create `LICENSE`** — standard MIT text, `Copyright (c) 2026 Helge Sverre`.

- [ ] **Step 3: Create `README.md` skeleton**

```markdown
# setup-sema

Install [Sema](https://sema-lang.com) — a Lisp with first-class LLM primitives — in your GitHub Actions workflow.

<!-- usage/inputs/outputs finalized in Task 8 -->
```

- [ ] **Step 4: Commit**

```bash
git add LICENSE .gitignore README.md
git commit -m "chore: repo scaffolding (license, gitignore, readme skeleton)"
```

---

### Task 2: `scripts/resolve_asset.py` — manifest parser

**Files:**
- Create: `scripts/resolve_asset.py`
- Test: `scripts/test_resolve_asset.sh`

**Interfaces:**
- Produces: `resolve_asset.py <triple>` reads `dist-manifest.json` on **stdin**, prints exactly two lines to stdout — line 1 = asset filename, line 2 = checksum filename (empty if none) — and exits 0; exits 1 with a stderr message if no artifact matches the triple.

- [ ] **Step 1: Write the failing test**

```bash
# scripts/test_resolve_asset.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIX="$SCRIPT_DIR/../test/fixtures/dist-manifest.json"
OUT="$(python3 "$SCRIPT_DIR/resolve_asset.py" aarch64-apple-darwin < "$FIX")"
NAME="$(printf '%s\n' "$OUT" | sed -n 1p)"
SUM="$(printf '%s\n' "$OUT" | sed -n 2p)"
test "$NAME" = "sema-lang-aarch64-apple-darwin.tar.xz" || { echo "FAIL name=$NAME"; exit 1; }
test "$SUM"  = "sema-lang-aarch64-apple-darwin.tar.xz.sha256" || { echo "FAIL sum=$SUM"; exit 1; }
# unknown triple must exit 1
if python3 "$SCRIPT_DIR/resolve_asset.py" mips-unknown-none < "$FIX" 2>/dev/null; then echo "FAIL: expected nonzero"; exit 1; fi
echo "PASS"
```

Also save the fetched real manifest as the fixture:

```bash
mkdir -p test/fixtures
gh release download v1.30.0 --repo sema-lisp/sema --pattern dist-manifest.json -O test/fixtures/dist-manifest.json
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash scripts/test_resolve_asset.sh`
Expected: FAIL (`resolve_asset.py` does not exist yet).

- [ ] **Step 3: Write `scripts/resolve_asset.py`**

```python
#!/usr/bin/env python3
"""Resolve the cargo-dist asset for a target triple from a dist-manifest.json.

Reads the manifest JSON on stdin. Prints two lines: the asset filename and its
checksum filename (empty if absent). Exits 1 if no artifact matches the triple.
Defensive across cargo-dist format epochs: iterates the `artifacts` map and
matches on `target_triples`, without assuming other structure.
"""
import json
import sys

def main() -> int:
    if len(sys.argv) != 2:
        sys.stderr.write("usage: resolve_asset.py <target-triple>\n")
        return 2
    triple = sys.argv[1]
    manifest = json.load(sys.stdin)
    for name, art in (manifest.get("artifacts") or {}).items():
        if art.get("kind") != "executable-zip":
            continue
        if triple in (art.get("target_triples") or []):
            print(name)
            print(art.get("checksum") or "")
            return 0
    sys.stderr.write(f"no artifact for triple {triple}\n")
    return 1

if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash scripts/test_resolve_asset.sh`
Expected: `PASS`

- [ ] **Step 5: Commit**

```bash
git add scripts/resolve_asset.py scripts/test_resolve_asset.sh test/fixtures/dist-manifest.json
git commit -m "feat: dist-manifest asset resolver + fixture test"
```

---

### Task 3: `scripts/install.sh` — the installer

**Files:**
- Create: `scripts/install.sh`
- Test: `scripts/test-local.sh`

**Interfaces:**
- Consumes: `resolve_asset.py` (Task 2); env vars `GH_TOKEN`, `INPUT_SEMA_VERSION`, `INPUT_VERSION`, `INPUT_CHECK_LATEST`, `INPUT_DOWNLOAD_URL`, plus runner-provided `RUNNER_OS`, `RUNNER_ARCH`, `RUNNER_TOOL_CACHE`, `GITHUB_PATH`, `GITHUB_OUTPUT`.
- Produces: an installed `sema` binary under `$RUNNER_TOOL_CACHE/sema/<version>/<arch>/`, that dir appended to `$GITHUB_PATH`, and outputs `sema-version`, `version`, `sema-path`, `cache-hit`, `cachekey`, `download-url` written to `$GITHUB_OUTPUT`.

- [ ] **Step 1: Write the failing local acceptance test**

```bash
# scripts/test-local.sh — real end-to-end run on THIS host (macOS-ARM64 by default)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export RUNNER_OS="${RUNNER_OS:-macOS}"
export RUNNER_ARCH="${RUNNER_ARCH:-ARM64}"
export RUNNER_TOOL_CACHE="$(mktemp -d)"
export GITHUB_PATH="$(mktemp)"
export GITHUB_OUTPUT="$(mktemp)"
export GH_TOKEN="${GH_TOKEN:-$(gh auth token 2>/dev/null || true)}"
export INPUT_SEMA_VERSION="${1:-latest}"
export INPUT_VERSION="" INPUT_CHECK_LATEST="false" INPUT_DOWNLOAD_URL=""

bash "$SCRIPT_DIR/install.sh"
echo "--- \$GITHUB_OUTPUT ---"; cat "$GITHUB_OUTPUT"
grep -q '^sema-version=' "$GITHUB_OUTPUT" || { echo "FAIL: no sema-version output"; exit 1; }

BIN_DIR="$(tail -1 "$GITHUB_PATH")"
"$BIN_DIR/sema" --version
D="$(mktemp -d)"; echo '(println (+ 1 2))' > "$D/smoke.sema"
OUT="$("$BIN_DIR/sema" "$D/smoke.sema")"
test "$OUT" = "3" || { echo "FAIL: smoke eval got '$OUT'"; exit 1; }

# second run must hit the tool cache
bash "$SCRIPT_DIR/install.sh"
grep -q '^cache-hit=true' "$GITHUB_OUTPUT" || { echo "FAIL: expected cache-hit=true on rerun"; exit 1; }
echo "PASS"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash scripts/test-local.sh`
Expected: FAIL (`install.sh` does not exist yet).

- [ ] **Step 3: Write `scripts/install.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail

REPO="sema-lisp/sema"
API="https://api.github.com/repos/${REPO}"
DL_BASE="https://github.com/${REPO}/releases/download"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON="$(command -v python3 || command -v python)"

: "${GH_TOKEN:=}"
: "${INPUT_SEMA_VERSION:=}"
: "${INPUT_VERSION:=}"          # deprecated alias for INPUT_SEMA_VERSION
: "${INPUT_CHECK_LATEST:=false}"
: "${INPUT_DOWNLOAD_URL:=}"

log()  { echo "$*"; }
warn() { echo "::warning::$*"; }
die()  { echo "::error::$*" >&2; exit 1; }

auth_hdr=()
[ -n "$GH_TOKEN" ] && auth_hdr=(-H "Authorization: Bearer ${GH_TOKEN}")

gh_api() {
  curl -fsSL --retry 3 "${auth_hdr[@]}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" "$1"
}
dl() { curl -fsSL --retry 3 "${auth_hdr[@]}" -o "$2" "$1"; }

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
    URL="${DL_BASE}/${TAG}/${ASSET}"
  fi

  log "Downloading ${URL}"
  dl "$URL" "${TMP}/${ASSET}"

  # --- 5. Checksum verify ----------------------------------------
  if [ -n "$CHECKSUM_ASSET" ] \
     && dl "${DL_BASE}/${TAG}/${CHECKSUM_ASSET}" "${TMP}/${ASSET}.sha256" 2>/dev/null; then
    ( cd "$TMP"
      if command -v sha256sum >/dev/null 2>&1; then sha256sum -c "${ASSET}.sha256"
      else shasum -a 256 -c "${ASSET}.sha256"; fi )
  else
    warn "No checksum published for ${ASSET}; skipping verification"
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash scripts/test-local.sh`
Expected: real download of `sema-lang-aarch64-apple-darwin.tar.xz`, checksum OK, `sema --version` prints, smoke eval prints `3`, rerun reports `cache-hit=true`, final `PASS`.

- [ ] **Step 5: Lint the script**

Run: `shellcheck scripts/install.sh scripts/test-local.sh` (install shellcheck via `brew install shellcheck` if missing)
Expected: no errors. Fix any warnings (quoting, unused vars).

- [ ] **Step 6: Test a pinned version too**

Run: `bash scripts/test-local.sh 1.30.0`
Expected: `PASS`, and `$GITHUB_OUTPUT` shows `sema-version=1.30.0`.

- [ ] **Step 7: Commit**

```bash
git add scripts/install.sh scripts/test-local.sh
git commit -m "feat: manifest-driven installer with checksum verify + tool-cache"
```

---

### Task 4: `action.yml` — composite wiring

**Files:**
- Create: `action.yml`
- Test: `scripts/test_action_yml.sh`

**Interfaces:**
- Consumes: `scripts/install.sh` via `${{ github.action_path }}`.
- Produces: the public action contract — inputs `sema-version`, `version`, `check-latest`, `github-token`, `download-url`; outputs `sema-version`, `version`, `sema-path`, `cache-hit`, `cachekey`, `download-url`.

- [ ] **Step 1: Write the failing validation test**

```bash
# scripts/test_action_yml.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY="$(command -v python3 || command -v python)"
"$PY" - "$SCRIPT_DIR/../action.yml" <<'EOF'
import sys, yaml
a = yaml.safe_load(open(sys.argv[1]))
assert a["runs"]["using"] == "composite", a["runs"]["using"]
ins = a["inputs"]
for k in ("sema-version","version","check-latest","github-token","download-url"):
    assert k in ins, f"missing input {k}"
outs = a["outputs"]
for k in ("sema-version","version","sema-path","cache-hit","cachekey","download-url"):
    assert k in outs, f"missing output {k}"
# every output must bind to the install step
for k,v in outs.items():
    assert "steps.install.outputs" in v["value"], f"output {k} not wired to install step"
print("PASS")
EOF
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash scripts/test_action_yml.sh`
Expected: FAIL (`action.yml` missing / not yet matching).

- [ ] **Step 3: Write `action.yml`**

```yaml
name: "Setup Sema"
description: "Install the Sema programming language (sema-lang.com) and add it to PATH"
author: "sema-lisp"

branding:
  icon: "code"
  color: "green"

inputs:
  sema-version:
    description: 'Sema version to install: "1.30.0", "v1.30.0", or "latest"'
    required: false
    default: "latest"
  version:
    description: "Deprecated alias for sema-version (used only if sema-version is unset)"
    required: false
    default: ""
  check-latest:
    description: "Always re-resolve 'latest' from the API instead of trusting a cached resolution"
    required: false
    default: "false"
  github-token:
    description: "Token for release API calls and asset download (avoids rate limits)"
    required: false
    default: ${{ github.server_url == 'https://github.com' && github.token || '' }}
  download-url:
    description: "Escape hatch: download the archive from this exact URL, bypassing version/manifest resolution"
    required: false
    default: ""

outputs:
  sema-version:
    description: "The concrete version installed, e.g. 1.30.0"
    value: ${{ steps.install.outputs.sema-version }}
  version:
    description: "Deprecated alias of sema-version"
    value: ${{ steps.install.outputs.version }}
  sema-path:
    description: "Absolute path to the install dir added to PATH"
    value: ${{ steps.install.outputs.sema-path }}
  cache-hit:
    description: "true if satisfied from the runner tool cache"
    value: ${{ steps.install.outputs.cache-hit }}
  cachekey:
    description: "Ready-made cache-key component for a downstream dependency cache"
    value: ${{ steps.install.outputs.cachekey }}
  download-url:
    description: "The asset URL actually used (or 'cache')"
    value: ${{ steps.install.outputs.download-url }}

runs:
  using: "composite"
  steps:
    - name: Install Sema
      id: install
      shell: bash
      env:
        GH_TOKEN: ${{ inputs.github-token }}
        INPUT_SEMA_VERSION: ${{ inputs.sema-version }}
        INPUT_VERSION: ${{ inputs.version }}
        INPUT_CHECK_LATEST: ${{ inputs.check-latest }}
        INPUT_DOWNLOAD_URL: ${{ inputs.download-url }}
      run: bash "${{ github.action_path }}/scripts/install.sh"

    - name: Verify installation
      shell: bash
      run: sema --version
```

Note: `sema-version` defaults to `latest`, so `INPUT_SEMA_VERSION` is only empty when a caller explicitly passes `sema-version: ""` — in that case the `.sema-version`/`.tool-versions` fallback in `install.sh` engages. `check-latest` is declared for forward-compat; because `latest` is always re-resolved from the API in this composite design, it is currently informational (documented in README).

- [ ] **Step 4: Run test to verify it passes**

Run: `bash scripts/test_action_yml.sh` (install pyyaml if needed: `"$PY" -m pip install --quiet pyyaml`)
Expected: `PASS`

- [ ] **Step 5: Commit**

```bash
git add action.yml scripts/test_action_yml.sh
git commit -m "feat: composite action.yml wiring install.sh with full input/output contract"
```

---

### Task 5: CI test matrix workflow

**Files:**
- Create: `.github/workflows/test.yml`

**Interfaces:**
- Consumes: the action at `./`.
- Produces: cross-OS acceptance proof (the real gate the local test can't provide).

- [ ] **Step 1: Write `.github/workflows/test.yml`**

```yaml
name: test
on:
  push:
    branches: [main]
  pull_request:
  schedule:
    - cron: "0 6 * * 1" # weekly: catch asset-shape breakage from new sema releases

jobs:
  test:
    strategy:
      fail-fast: false
      matrix:
        os: [ubuntu-latest, ubuntu-24.04-arm, macos-latest, macos-13, windows-latest]
        sema-version: [latest, "1.30.0"]
    runs-on: ${{ matrix.os }}
    steps:
      - uses: actions/checkout@v4

      - name: Setup Sema
        id: sema
        uses: ./
        with:
          sema-version: ${{ matrix.sema-version }}

      - name: Resolved version output is present
        shell: bash
        run: |
          test -n "${{ steps.sema.outputs.sema-version }}"
          echo "Installed: ${{ steps.sema.outputs.sema-version }}"

      - name: Pinned version matches request
        if: matrix.sema-version != 'latest'
        shell: bash
        run: test "${{ steps.sema.outputs.sema-version }}" = "${{ matrix.sema-version }}"

      - name: sema --version runs
        shell: bash
        run: sema --version

      - name: Sema evaluates code
        shell: bash
        run: |
          echo '(println (+ 1 2))' > smoke.sema
          OUT="$(sema smoke.sema)"
          test "$OUT" = "3"

      - name: Second run hits the tool cache
        id: sema2
        uses: ./
        with:
          sema-version: ${{ matrix.sema-version }}

      - name: Assert cache-hit on rerun
        shell: bash
        run: test "${{ steps.sema2.outputs.cache-hit }}" = "true"
```

- [ ] **Step 2: Validate the workflow YAML locally**

Run: `"$(command -v python3 || command -v python)" -c "import yaml,sys; yaml.safe_load(open('.github/workflows/test.yml')); print('ok')"`
Expected: `ok`

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/test.yml
git commit -m "test: cross-OS x version CI matrix with cache-hit + smoke-eval assertions"
```

---

### Task 6: Release workflow (moving `v1` tag)

**Files:**
- Create: `.github/workflows/release-tag.yml`

**Interfaces:**
- Produces: automation that force-moves the `v1` major tag to each `v1.x.y` release so users can pin `@v1`.

- [ ] **Step 1: Write `.github/workflows/release-tag.yml`**

```yaml
name: release-tag
on:
  release:
    types: [published]

permissions:
  contents: write

jobs:
  move-major-tag:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - name: Move major tag to this release
        shell: bash
        run: |
          set -euo pipefail
          TAG="${GITHUB_REF_NAME}"          # e.g. v1.2.3
          MAJOR="${TAG%%.*}"                # e.g. v1
          git config user.name "github-actions[bot]"
          git config user.email "github-actions[bot]@users.noreply.github.com"
          git tag -fa "$MAJOR" -m "Update $MAJOR tag to $TAG"
          git push origin "$MAJOR" --force
```

- [ ] **Step 2: Validate YAML**

Run: `"$(command -v python3 || command -v python)" -c "import yaml; yaml.safe_load(open('.github/workflows/release-tag.yml')); print('ok')"`
Expected: `ok`

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/release-tag.yml
git commit -m "ci: auto-move v1 major tag on each published release"
```

---

### Task 7: Finalize README

**Files:**
- Modify: `README.md`

**Interfaces:**
- Produces: the Marketplace-facing docs (usage, inputs/outputs, runners, SHA-pinning note).

- [ ] **Step 1: Write the full `README.md`**

```markdown
# setup-sema

Install [Sema](https://sema-lang.com) — a Lisp with first-class LLM primitives — in your GitHub Actions workflow.

## Usage

\`\`\`yaml
steps:
  - uses: sema-lisp/setup-sema@v1
  - run: sema my-script.sema
\`\`\`

Pin a version:

\`\`\`yaml
  - uses: sema-lisp/setup-sema@v1
    with:
      sema-version: "1.30.0"
\`\`\`

Or pin the version in a `.sema-version` file at your repo root and just call the action with no inputs.

## Inputs

| Input          | Default            | Description                                              |
| -------------- | ------------------ | -------------------------------------------------------- |
| `sema-version` | `latest`           | `latest`, `1.30.0`, or `v1.30.0`. Falls back to `.sema-version` / `.tool-versions` when set to `""`. |
| `version`      | —                  | Deprecated alias for `sema-version`.                     |
| `check-latest` | `false`            | Reserved; `latest` is always re-resolved in this action. |
| `github-token` | repo token         | Token for release API + downloads (avoids rate limits).  |
| `download-url` | —                  | Escape hatch: install from this exact archive URL.       |

## Outputs

| Output         | Description                                          |
| -------------- | --------------------------------------------------- |
| `sema-version` | Concrete version installed, e.g. `1.30.0`.          |
| `sema-path`    | Absolute path added to `PATH`.                      |
| `cache-hit`    | `true` if served from the runner tool cache.        |
| `cachekey`     | Cache-key component for a downstream dependency cache. |
| `download-url` | Asset URL actually used (or `cache`).               |

## Supported runners

Linux x64/arm64, macOS x64/arm64 (Intel + Apple Silicon), Windows x64.

## Example: run tests on every push

\`\`\`yaml
name: ci
on: [push, pull_request]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: sema-lisp/setup-sema@v1
      - run: sema test.sema
\`\`\`

## Security: pinning

`@v1` tracks the latest `v1.x`. For a fully reproducible, tamper-proof pin, use the commit SHA:

\`\`\`yaml
  - uses: sema-lisp/setup-sema@<40-char-sha>  # v1.2.3
\`\`\`

Dependabot understands SHA pins with a trailing version comment.

## License

MIT
```

(Replace the escaped `\`\`\`` fences with real triple-backticks when writing the file.)

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: finalize README (usage, inputs/outputs, runners, SHA-pinning)"
```

---

### Task 8: Publish & workspace integration (manual/remote — requires user)

**Files:**
- Modify (workspace repo, separate commit): `/Users/helge/code/sema/repos.tsv`

**Interfaces:**
- Produces: a live `sema-lisp/setup-sema` repo, green CI, a `v1.0.0` release + `v1` tag, and workspace registration.

- [ ] **Step 1: Create the GitHub remote and push** (confirm with the user first — this is outward-facing)

```bash
gh repo create sema-lisp/setup-sema --public --source=. --remote=origin --description "Install Sema in GitHub Actions" --push
```

- [ ] **Step 2: Confirm CI is green**

```bash
gh run list --repo sema-lisp/setup-sema --limit 5
```
Expected: the `test` matrix passes on all five OS × both versions. Fix any triple/extension/strip-components issue surfaced here (this is the real Windows/arm proof the local test cannot give).

- [ ] **Step 3: Cut the first release + Marketplace listing**

```bash
git tag v1.0.0 && git push origin v1.0.0
gh release create v1.0.0 --title "v1.0.0" --notes "First release of setup-sema."
```
Then in the release UI, check "Publish this Action to the GitHub Marketplace" (verify the `name: "Setup Sema"` is Marketplace-unique). The `release-tag` workflow moves `v1` automatically.

- [ ] **Step 4: Register as a workspace member** (commit in the workspace repo, not here)

Add to `/Users/helge/code/sema/repos.tsv`:
```
setup-sema	setup-sema
```
Commit in the workspace root (`cd /Users/helge/code/sema && git add repos.tsv && git commit -m "workspace: register setup-sema member"`). No Jakefile `@import` (no `@rooted` Jakefile).

---

## Self-Review

**Spec coverage:**
- Composite bash → Task 3/4. dist-manifest resolution + fallback → Task 2/3. Three real bugs fixed (prefix/version/ext) → Task 3 asset logic + `.tar.xz` extraction. `sema-version` + `version` alias → Task 4 inputs, Task 3 resolution. Version file (`.sema-version`/`.tool-versions`) → Task 3 step-1 logic. `check-latest` → Task 4 (declared, documented informational). Token GHES-aware default → Task 4. `download-url` escape hatch → Task 3. Checksum mandatory-when-present → Task 3 step-5. Tool-cache short-circuit → Task 3 step-3. Outputs incl. `cachekey` → Task 3/4. `--strip-components=1` tar vs flat zip → Task 3 step-6, matrix-tested Task 5. Test matrix (5 OS × 2 versions, cache-hit + smoke) + weekly cron → Task 5. Marketplace + moving `v1` + SHA-pin note → Task 6/7/8. Workspace integration → Task 8. **No gaps.**

**Placeholder scan:** No TBD/TODO. Every code step shows complete content. (README fences are escaped only to survive this markdown wrapper; step notes the substitution.)

**Type/name consistency:** Output keys (`sema-version`, `version`, `sema-path`, `cache-hit`, `cachekey`, `download-url`) match across `install.sh` (Task 3 step-7), `action.yml` (Task 4), the `action.yml` validation test (Task 4 step-1), and the CI assertions (Task 5). `resolve_asset.py` two-line contract matches its caller in `install.sh`. `INSTALL_DIR` layout consistent between the cache-check and the exposure. Consistent.

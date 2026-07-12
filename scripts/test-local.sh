#!/usr/bin/env bash
# scripts/test-local.sh — real end-to-end run on THIS host (macOS-ARM64 by default)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export RUNNER_OS="${RUNNER_OS:-macOS}"
export RUNNER_ARCH="${RUNNER_ARCH:-ARM64}"
RUNNER_TOOL_CACHE="$(mktemp -d)"; export RUNNER_TOOL_CACHE
GITHUB_PATH="$(mktemp)"; export GITHUB_PATH
GITHUB_OUTPUT="$(mktemp)"; export GITHUB_OUTPUT
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

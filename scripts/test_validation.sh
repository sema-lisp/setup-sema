#!/usr/bin/env bash
# Proves the version validation (C1 fix) rejects hostile version strings — from
# the input AND from a .sema-version file — before any network access, so a fork
# cannot steer the download URL to another repo via path traversal.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Run install.sh with a given version input in a scratch cwd; capture rc+output.
# No real version is downloaded: validation fails closed before curl runs.
run_install() { # $1=INPUT_SEMA_VERSION $2=cwd (optional)
  local cwd="${2:-$(mktemp -d)}"
  ( cd "$cwd" || exit 1
    RUNNER_OS=Linux RUNNER_ARCH=X64 \
    RUNNER_TOOL_CACHE="$(mktemp -d)" \
    GITHUB_PATH="$(mktemp)" GITHUB_OUTPUT="$(mktemp)" \
    GH_TOKEN="" INPUT_SEMA_VERSION="$1" INPUT_VERSION="" INPUT_DOWNLOAD_URL="" \
    bash "$SCRIPT_DIR/install.sh" 2>&1 )
}

fail() { echo "FAIL: $1"; exit 1; }

# 1. Path-traversal payload in the version input must be rejected (nonzero + message).
out="$(run_install '../../../../attacker/evilrepo/releases/download/vx')"; rc=$?
test "$rc" -ne 0 || fail "traversal version was NOT rejected (rc=0)"
echo "$out" | grep -qi "unsafe\|malformed" || fail "traversal rejection lacked a clear message: $out"

# 2. Command-substitution / injection characters must be rejected.
# shellcheck disable=SC2016  # these are deliberately-literal hostile payloads, not meant to expand
for bad in '1.30.0;rm -rf x' '1.30.0 && curl evil' '$(whoami)' '1.30.0/../..'; do
  out="$(run_install "$bad")"; rc=$?
  test "$rc" -ne 0 || fail "malformed version '$bad' was NOT rejected"
done

# 3. A hostile .sema-version file (empty sema-version input -> file is read) is rejected.
d="$(mktemp -d)"; printf '../../../../attacker/x' > "$d/.sema-version"
out="$(run_install '' "$d")"; rc=$?
test "$rc" -ne 0 || fail ".sema-version traversal was NOT rejected"
echo "$out" | grep -qi "unsafe\|malformed" || fail ".sema-version rejection lacked a clear message: $out"

# 4. Well-formed versions must PASS validation (they proceed to the network, which
#    we don't exercise here — we only assert they are NOT rejected as malformed).
for good in '1.30.0' 'v1.30.0' '1.30.0-rc.1'; do
  out="$(run_install "$good")"; rc=$?
  echo "$out" | grep -qi "Refusing.*version" && fail "well-formed version '$good' was wrongly rejected: $out"
done

echo "PASS"

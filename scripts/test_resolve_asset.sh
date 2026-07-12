#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY="$(command -v python3 || command -v python)"
FIX="$SCRIPT_DIR/../test/fixtures/dist-manifest.json"

# 1. Real fixture: resolves asset name AND checksum name for a known triple.
OUT="$("$PY" "$SCRIPT_DIR/resolve_asset.py" aarch64-apple-darwin < "$FIX")"
NAME="$(printf '%s\n' "$OUT" | sed -n 1p)"
SUM="$(printf '%s\n' "$OUT" | sed -n 2p)"
test "$NAME" = "sema-lang-aarch64-apple-darwin.tar.xz" || { echo "FAIL name=$NAME"; exit 1; }
test "$SUM"  = "sema-lang-aarch64-apple-darwin.tar.xz.sha256" || { echo "FAIL sum=$SUM"; exit 1; }

# 2. Unknown triple must exit nonzero.
if "$PY" "$SCRIPT_DIR/resolve_asset.py" mips-unknown-none < "$FIX" 2>/dev/null; then
  echo "FAIL: expected nonzero exit for unknown triple"; exit 1
fi

# 3. Wrong argument count must exit 2 (usage error).
"$PY" "$SCRIPT_DIR/resolve_asset.py" < "$FIX" >/dev/null 2>&1 && rc=0 || rc=$?
test "$rc" = "2" || { echo "FAIL: expected exit 2 for missing arg, got $rc"; exit 1; }

# 4. Artifact with no `checksum` field yields an empty second line (not absent/garbage).
SYNTH='{"artifacts":{"sema-lang-x86_64-unknown-linux-gnu.tar.xz":{"kind":"executable-zip","target_triples":["x86_64-unknown-linux-gnu"]}}}'
OUT2="$(printf '%s' "$SYNTH" | "$PY" "$SCRIPT_DIR/resolve_asset.py" x86_64-unknown-linux-gnu)"
NAME2="$(printf '%s\n' "$OUT2" | sed -n 1p)"
SUM2="$(printf '%s\n' "$OUT2" | sed -n 2p)"
test "$NAME2" = "sema-lang-x86_64-unknown-linux-gnu.tar.xz" || { echo "FAIL synth name=$NAME2"; exit 1; }
test -z "$SUM2" || { echo "FAIL: expected empty checksum line, got '$SUM2'"; exit 1; }

echo "PASS"

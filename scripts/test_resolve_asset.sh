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

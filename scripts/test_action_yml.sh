#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY="$(command -v python3 || command -v python)"
"$PY" - "$SCRIPT_DIR/../action.yml" <<'EOF'
import sys, yaml
a = yaml.safe_load(open(sys.argv[1]))
assert a["runs"]["using"] == "composite", a["runs"]["using"]

ins = a["inputs"]
for k in ("sema-version", "version", "github-token", "download-url", "verify"):
    assert k in ins, f"missing input {k}"
assert "check-latest" not in ins, "check-latest input should have been removed"
assert ins["sema-version"]["default"] == "", "sema-version must default to '' so version-file/latest fallbacks fire"

# Every output must bind to the install step's *matching* key.
outs = a["outputs"]
for k in ("sema-version", "version", "sema-path", "cache-hit", "cache-key", "download-url"):
    assert k in outs, f"missing output {k}"
    expected = f"steps.install.outputs.{k}"
    assert expected in outs[k]["value"], f"output {k} not wired to {expected}: {outs[k]['value']}"
assert "cachekey" not in outs, "output should be 'cache-key', not 'cachekey'"

steps = a["runs"]["steps"]
install = next(s for s in steps if s.get("id") == "install")
env = install["env"]
for k in ("GH_TOKEN", "INPUT_SEMA_VERSION", "INPUT_VERSION", "INPUT_DOWNLOAD_URL"):
    assert k in env, f"install step missing env var {k}"
assert "INPUT_CHECK_LATEST" not in env, "check-latest env should have been removed"

verify = next(s for s in steps if s.get("name") == "Verify installation")
assert "inputs.verify" in str(verify.get("if", "")), "verify step must be guarded by the 'verify' input"

print("PASS")
EOF

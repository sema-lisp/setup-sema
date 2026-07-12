#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY="$(command -v python3 || command -v python)"
"$PY" - "$SCRIPT_DIR/../action.yml" <<'EOF'
import sys, yaml
a = yaml.safe_load(open(sys.argv[1]))
assert a["runs"]["using"] == "composite", a["runs"]["using"]

ins = a["inputs"]
for k in ("sema-version", "version", "check-latest", "github-token", "download-url"):
    assert k in ins, f"missing input {k}"

# Every output must bind to the install step's *matching* key (guards against a
# silent swap like sema-version -> steps.install.outputs.version).
outs = a["outputs"]
for k in ("sema-version", "version", "sema-path", "cache-hit", "cachekey", "download-url"):
    assert k in outs, f"missing output {k}"
    expected = f"steps.install.outputs.{k}"
    assert expected in outs[k]["value"], f"output {k} not wired to {expected}: {outs[k]['value']}"

# The install step must forward every input the script reads under the exact
# env-var name install.sh expects; a mismatch silently drops the input.
install = next(s for s in a["runs"]["steps"] if s.get("id") == "install")
env = install["env"]
for k in ("GH_TOKEN", "INPUT_SEMA_VERSION", "INPUT_VERSION", "INPUT_CHECK_LATEST", "INPUT_DOWNLOAD_URL"):
    assert k in env, f"install step missing env var {k}"

print("PASS")
EOF

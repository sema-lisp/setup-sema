#!/bin/bash
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

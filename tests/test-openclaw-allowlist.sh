#!/bin/bash
# tests/test-openclaw-allowlist.sh — openclaw/exec-approvals.json limits the bridge agent to
# one binary, devbrain-queue (so no `devbrain plan` or `devbrain execute`). It does not limit
# which verbs of that binary the agent runs: that rests on openclaw/workspace/AGENTS.md.
[ -z "${OPENCLAW_CLI+x}" ] && [ "${OPENCLAW_SHELL-}" != exec ] || { echo "FAIL: these tests do not run under OpenClaw" >&2; exit 1; }
set -uo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $1"; exit 1; }

# check <file> -> prints OK, or what is wrong. One checker for the real file and the plant.
cat > "$T/check.py" <<'PY'
import json, os, sys
d = json.load(open(sys.argv[1]))
bad = []
if d.get("version") != 1:
    bad.append("version must be 1")
for k, v in {"security": "deny", "ask": "off", "askFallback": "deny", "autoAllowSkills": False}.items():
    if d.get("defaults", {}).get(k) != v:
        bad.append(f"defaults.{k} must be {v!r}")
main = d.get("agents", {}).get("main", {})
if main.get("security") != "allowlist":
    bad.append("agents.main.security must be 'allowlist'")
names = [os.path.basename(e.get("pattern", "")) for e in main.get("allowlist", [])]
if names != ["devbrain-queue"]:
    bad.append(f"the agent may run exactly devbrain-queue, got {names}")
for n in names:
    if not os.path.isfile(os.path.join(sys.argv[2], n)):
        bad.append(f"{n} is not a script in bin/")
print("; ".join(bad) if bad else "OK")
PY
check() { python3 -I "$T/check.py" "$1" "$DIR/bin"; }

OUT="$(check "$DIR/openclaw/exec-approvals.json")"
[ "$OUT" = OK ] || fail "$OUT"
echo "OK: the bridge agent is allowed to run devbrain-queue and nothing else (default deny)"

# The control: a copy that also allows `devbrain` must be caught by the same checker.
python3 -I - "$DIR/openclaw/exec-approvals.json" "$T/bad.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["agents"]["main"]["allowlist"].append({"pattern": "/x/bin/devbrain"})
json.dump(d, open(sys.argv[2], "w"))
PY
OUT2="$(check "$T/bad.json")"
[ "$OUT2" != OK ] || fail "the control (devbrain added to the allowlist) was not caught"
echo "OK: the checker catches a planted extra entry"
echo "PASS: openclaw-allowlist"

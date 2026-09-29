#!/bin/bash
# test-preflight.sh — every preflight check, planted RED.
#
# Each case is one way a night can be lost before it starts. If one stops being detected,
# that failure costs a whole day again.
set -uo pipefail
PF="$(cd "$(dirname "$0")/.." && pwd)/bin/devbrain-preflight"
export DEVBRAIN_PREFLIGHT_NO_FETCH=1
ok=0; bad=0
check() { # <name> <expected 0|1> <pattern that must appear, or -->
  local n="$1" want="$2" pat="$3"
  local out; out="$("$PF" 2>&1)"; local got=$?
  local good=1
  [ "$got" = "$want" ] || good=0
  [ "$pat" = "--" ] || grep -qi -- "$pat" <<<"$out" || good=0
  if [ "$good" = 1 ]; then ok=$((ok+1)); printf '  ok   %s\n' "$n"
  else bad=$((bad+1)); printf '  BAD  %s (rc=%s, expected %s)\n    %s\n' "$n" "$got" "$want" "$(head -3 <<<"$out" | tail -2)"; fi
}
setup() { # leaves a clean, valid scenario in $T
  rm -rf "$T"; mkdir -p "$T/queue" "$T/config" "$T/projects/demo"
  git -C "$T/projects/demo" init -q 2>/dev/null
  git -C "$T/projects/demo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
  printf 'demo\n' > "$T/config/devbrain-projects.allow"
  printf 'demo=npm test\n' > "$T/config/devbrain-verify.commands"
  printf -- '---\nrepo: demo\nstatus: approved\nprioridad: 10\ncreado: 2026-09-14\naprobado: 2026-09-14\n---\n\nA test task.\n' > "$T/queue/10-demo--task.plan.md"
}
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export DEVBRAIN_QUEUE_DIR="$T/queue" DEVBRAIN_MC_DIR="$T/config" DEVBRAIN_PROJECTS_DIR="$T/projects"
PLAN="$T/queue/10-demo--task.plan.md"

setup; check "a healthy scenario passes"                 0 "--"
setup; echo junk > "$T/projects/demo/stray.txt"
       check "a dirty checkout is detected"              1 "dirty"
setup; printf 'other\n' > "$T/config/devbrain-projects.allow"
       check "a repo outside the allowlist is detected"  1 "not in devbrain-projects.allow"
setup; printf 'other=npm test\n' > "$T/config/devbrain-verify.commands"
       check "a repo with no verification command"       1 "NO command"
setup; rm -rf "$T/projects/demo"
       check "a missing checkout"                        1 "no checkout"
setup; sed -i '' 's/^status: approved/status: solicitado/' "$PLAN"
       check "no approved plans warns and passes"        0 "no approved plans"

# check 5/7: commands that are never granted
setup; printf '\nRun `git clone https://example.com/x.git /tmp/x` first.\n' >> "$PLAN"
       check "a plan that ASKS to clone a repo"          1 "git clone"
setup; printf '\nNo need for git clone: the checkout already exists.\n' >> "$PLAN"
       check "a plan that says NOT to clone is not a false positive" 0 "--"
setup; printf '\nBefore testing, run `cd frontend && npm install`.\n' >> "$PLAN"
       check "a plan that ASKS for npm install"          1 "npm install"
setup; printf '\nnpm install is not needed: node_modules already exists.\n' >> "$PLAN"
       check "a plan that says npm install is NOT needed is not a false positive" 0 "--"

# check 6: the permission exists AND is usable
setup; echo 'frontend/' >> "$T/projects/demo/.git/info/exclude"; mkdir -p "$T/projects/demo/frontend"
       printf '{"scripts":{"build":"true"}}\n' > "$T/projects/demo/frontend/package.json"
       printf 'demo=npm run build@frontend\n' > "$T/config/devbrain-verify.commands"
       check "permission granted but node_modules is missing" 1 "node_modules"
setup; echo 'frontend/' >> "$T/projects/demo/.git/info/exclude"; mkdir -p "$T/projects/demo/frontend/node_modules"
       printf '{"scripts":{"build":"true"}}\n' > "$T/projects/demo/frontend/package.json"
       printf 'demo=npm run build@frontend\n' > "$T/config/devbrain-verify.commands"
       check "a usable @subdir permission passes"        0 "--"

# a plan that already blocked once on a command that is still not granted
setup; sed -i '' 's/^aprobado:.*/&\nbloqueado_por: make deploy-check/' "$PLAN"
       check "a plan blocked before on a still-ungranted command" 1 "already blocked"

# check 8: what bin/devbrain refuses regardless of any allowlist
setup; printf 'demo\n' > "$T/config/devbrain-migration-block.list"; printf '\nWrite a migration that adds the column.\n' >> "$PLAN"
       check "a migration write in a migration-blocked repo" 1 "migration"

# --plan mode: ONE plan, approved or not
plan_only() { # <name> <expected> <pattern>
  local out; out="$("$PF" --plan "$PLAN" 2>&1)"; local got=$?
  if [ "$got" = "$2" ] && { [ "$3" = "--" ] || grep -qi -- "$3" <<<"$out"; }; then ok=$((ok+1)); printf '  ok   %s\n' "$1"
  else bad=$((bad+1)); printf '  BAD  %s (rc=%s, expected %s)\n    %s\n' "$1" "$got" "$2" "$out"; fi
}
setup; sed -i '' 's/^status: approved/status: solicitado/;/^aprobado:/d' "$PLAN"
       plan_only "--plan: a healthy draft passes even if not approved" 0 "--"
setup; sed -i '' 's/^status: approved/status: solicitado/;/^aprobado:/d' "$PLAN"; printf '\nRun `npm install`.\n' >> "$PLAN"
       plan_only "--plan: a draft that asks for npm install is refused" 1 "npm install"
setup; echo junk > "$T/projects/demo/stray.txt"
       plan_only "--plan: a dirty checkout is refused too" 1 "dirty"
setup; printf 'demo\n' > "$T/config/devbrain-migration-block.list"; printf '\nWrite a migration.\n' >> "$PLAN"
       plan_only "--plan: the substring heuristics are warnings, not refusals" 0 "warning"

echo "test-preflight: $ok ok, $bad bad"
[ "$bad" = "0" ]

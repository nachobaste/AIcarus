#!/bin/bash
# tests/test-queue-contract.sh — the queue contract, checked by bin/devbrain-preflight over the
# whole queue (approved or not):
#   C1. `done` needs `pr:` or `sin_pr: <reason>`.
#   C2. `paused` needs `motivo_fallo: <reason>`.
# The writers (devbrain-night, devbrain-queue pause) are tested in test-night.sh and test-queue.sh.
[ -z "${OPENCLAW_CLI+x}" ] && [ "${OPENCLAW_SHELL-}" != exec ] || { echo "FAIL: these tests do not run under OpenClaw" >&2; exit 1; }
set -uo pipefail
PF="$(cd "$(dirname "$0")/.." && pwd)/bin/devbrain-preflight"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/config" "$T/projects"
export DEVBRAIN_QUEUE_DIR="$T/queue" DEVBRAIN_MC_DIR="$T/config" \
  DEVBRAIN_PROJECTS_DIR="$T/projects" DEVBRAIN_PREFLIGHT_NO_FETCH=1
ok=0; bad=0
case_() { # <name> <expected rc> <pattern that must appear, or -- for no contract finding> <extra frontmatter> [body]
  rm -rf "$T/queue"; mkdir -p "$T/queue"
  printf -- '---\nrepo: demo\nprioridad: 10\ncreado: 2026-10-03\n%b---\n\n%s\n' "$4" "${5:-body}" \
    > "$T/queue/10-demo--x.plan.md"
  local out rc good=1; out="$("$PF" 2>&1)"; rc=$?
  [ "$rc" = "$2" ] || good=0
  if [ "$3" = "--" ]; then grep -q "queue contract" <<<"$out" && good=0
  else grep -q -- "$3" <<<"$out" || good=0; fi
  if [ "$good" = 1 ]; then ok=$((ok+1)); echo "  ok   $1"
  else bad=$((bad+1)); echo "  BAD  $1 (rc=$rc, expected $2)"; echo "$out" | sed 's/^/    /'; fi
}

case_ "done with neither pr nor sin_pr is flagged"   1 'neither `pr:` nor `sin_pr' 'status: done\n'
case_ "done with pr passes"                           0 --  'status: done\npr: https://github.com/x/y/pull/1\n'
case_ "done with sin_pr passes"                       0 --  'status: done\nsin_pr: a decision plan, carries no code\n'
case_ "done with an empty pr is flagged"              1 "queue contract" 'status: done\npr:\n'
case_ "a pr: line in the body does not count"         1 "queue contract" 'status: done\n' 'pr: https://github.com/x/y/pull/1'
case_ "paused without a reason is flagged"            1 'paused` without `motivo_fallo' 'status: paused\n'
case_ "paused with motivo_fallo passes"               0 --  'status: paused\nmotivo_fallo: waiting on the owner'"'"'s decision\n'
case_ "other statuses are not touched"                0 --  'status: blocked\n'
# the contract applies to a plan that is not approved too, and sits next to the other problems
case_ "requested plans are not touched"               0 --  'status: requested\n'

echo "queue contract: $ok ok, $bad bad"
[ "$bad" = 0 ]

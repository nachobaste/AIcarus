#!/bin/bash
# tests/canary/verifier/run.sh — canary for bin/devbrain-verifier.
# Six premises over a tiny fixture: 3 that hold, 2 that are false, 1 nobody can check from the code.
# It runs the REAL verifier and compares the verdicts, in order, with expected.txt.
#
#   run.sh            real claude: ONE billed call (read-only session, a few small files). Not part of tests/*.sh.
#   run.sh --check    only the comparison, against the plan the verifier left in $2 (used by the free test)
#
# DEVBRAIN_CLAUDE_BIN swaps the claude binary; tests/test-verifier-canary-check.sh uses that to prove the
# comparison can fail. Exit 0 = every verdict as expected; 1 = at least one differs (each one is printed).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"

compare() { # <already verified plan> -> rc 0 if every verdict, in order, is the expected one
  local got exp i=0 bad=0 v
  got="$(sed -n -E 's/^.* :: [^ ]+:[0-9]+ :: (HOLDS|FALSE|UNVERIFIABLE)[[:space:]]*$/\1/p' "$1" | head -n 6)"
  exp="$(cat "$HERE/expected.txt")"
  [ "$(printf '%s\n' "$got" | grep -c .)" = "$(printf '%s\n' "$exp" | grep -c .)" ] \
    || { echo "FAIL canary: expected $(printf '%s\n' "$exp" | grep -c .) verdicts and got $(printf '%s\n' "$got" | grep -c .)"; return 1; }
  while IFS= read -r v; do
    i=$((i + 1))
    [ "$v" = "$(printf '%s\n' "$got" | sed -n "${i}p")" ] || { echo "FAIL canary: premise $i: expected $v and got $(printf '%s\n' "$got" | sed -n "${i}p")"; bad=1; }
  done < "$HERE/expected.txt"
  [ "$bad" = 0 ] && echo "OK canary: 3 HOLDS, 2 FALSE, 1 UNVERIFIABLE as expected"
  return "$bad"
}

if [ "${1:-}" = "--check" ]; then compare "${2:?usage: run.sh --check <plan>}"; exit $?; fi

W="$(mktemp -d "${TMPDIR:-/tmp}/canary-verifier.XXXXXX")"; trap 'rm -rf "$W"' EXIT
cp "$HERE/plan.md" "$W/plan.md"
DEVBRAIN_VERIFIER_LOG="$W/log" "$ROOT/bin/devbrain-verifier" --root "$HERE/fixture" "$W/plan.md" || { echo "FAIL canary: the verifier failed (log: $W/log)"; tail -5 "$W/log" 2>/dev/null; exit 1; }
compare "$W/plan.md"

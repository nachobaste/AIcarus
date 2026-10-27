#!/bin/bash
# tests/test-verifier-cmd-premises.sh — executable `cmd` premises of lib/verifier.py `gate`:
#   <claim> :: cmd `grep -c PATTERN PATH` == N     (also `wc -l PATH`, `test -f PATH`)
# The gate runs them itself: closed list, no shell, cwd in the plan's repo, 10 s timeout, realpath-confined, N <= 9 digits.
#
# Each case is a function `case_* <root>` that returns 0 if it passes. They run against the real tree (all must
# pass) and against MUTATED COPIES (the case that catches the mutation must go RED). A control mutation (a
# comment) must leave everything green. Every command that really runs in a "not allowed" case leaves a trace
# (`canary-executed`) that the case looks for: a mutation that opens the list must leave a trace AND go red.
[ -z "${OPENCLAW_CLI+x}" ] && [ "${OPENCLAW_SHELL-}" != exec ] || { echo "FAIL: these tests do not run under OpenClaw" >&2; exit 1; }
set -uo pipefail
die() { echo "FAIL: ${1:-test-verifier-cmd-premises.sh:${BASH_LINENO[0]}}"; exit 1; }
DIR="$(cd "$(dirname "$0")/.." && pwd)"
[ -f "$DIR/lib/verifier.py" ] || die "lib/verifier.py does not exist"
TMP="$(cd "$(mktemp -d)" && pwd -P)"; trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"; mkdir -p "$HOME"
TODAY="$(date +%Y-%m-%d)"
VCMD="$TODAY (0 claims)"

# test repo: lib/math.sh with 9 lines (all containing "line"), app.txt with 3
REPO="$TMP/repo"; mkdir -p "$REPO/lib"
for i in 1 2 3 4 5 6 7 8 9; do echo "line $i" >> "$REPO/lib/math.sh"; done
printf 'a\nb\nc\n' > "$REPO/app.txt"
printf 'secret\n' > "$TMP/outside.txt"   # really exists outside the repo: only the path check stops it

mkplan() { # <file> <verificado|-> <lines...>
  local f="$1" v="$2"; shift 2
  { printf -- '---\nrepo: demo\nstatus: approved\naprobado: 2026-01-01\nprioridad: 5\n'
    [ "$v" = - ] || printf 'verificado: %s\n' "$v"
    printf -- '---\n\n# Title\n\n## What was already verified\n\n'
    for l in "$@"; do printf '%s\n' "$l"; done
    printf '\n## Constraints\n\n- Nothing else.\n'; } > "$f"
}
gate() { # <root> <plan> -> rc of gate with an explicit root (the test repo); output in $GATE_OUT
  rm -f "$REPO/canary-executed"
  GATE_OUT="$(python3 -I "$1/lib/verifier.py" gate "$2" "$REPO" 2>&1 < /dev/null)"; return $?
}
gate_noroot() { # <root> <plan> [projects dir] -> gate WITHOUT root: it comes from the plan's `repo:`
  GATE_OUT="$(env -i HOME="$HOME" PATH="$PATH" DEVBRAIN_PROJECTS_DIR="${3:-$TMP/none}" DEVBRAIN_SELF_REPO=example-kit \
    python3 -I "$1/lib/verifier.py" gate "$2" 2>&1 < /dev/null)"; return $?
}
setrepo() { sed "s#^repo: demo\$#repo: $2#" "$1" > "$1.tmp" && mv "$1.tmp" "$1"; }   # <plan> <repo>
reason_is() { case "$GATE_OUT" in "premise $1"*) return 0 ;; *) echo "wrong reason (want $1): ${GATE_OUT:0:120}" >&2; return 1 ;; esac; }

case_cmd_holds() { local R="$1" P="$TMP/c1.plan.md"
  mkplan "$P" "$VCMD" '- nine mentions :: cmd `grep -c line lib/math.sh` == 9' '- nine lines :: cmd `wc -l lib/math.sh` == 9' \
    '- app exists :: cmd `test -f app.txt` == 1' '- nope absent :: cmd `test -f nope.txt` == 0' '- nothing says zzz :: cmd `grep -c zzz app.txt` == 0'
  gate "$R" "$P"
}
case_cmd_false_planted() { local R="$1" P="$TMP/c2.plan.md"
  mkplan "$P" "$VCMD" '- four lines say line :: cmd `grep -c line lib/math.sh` == 4'
  gate "$R" "$P" && return 1
  case "$GATE_OUT" in *"premise FALSE"*"four lines"*) ;; *) return 1 ;; esac
  mkplan "$P" "$VCMD" '- app exists :: cmd `test -f app.txt` == 0'; gate "$R" "$P" && return 1
  mkplan "$P" "$VCMD" '- nine :: cmd `wc -l lib/math.sh` == 8'; gate "$R" "$P" && return 1
  mkplan "$P" "$VCMD" '- ok :: cmd `grep -c line lib/math.sh` == 9' '- bad :: cmd `grep -c line lib/math.sh` == 10'   # one good, one false: the false decides
  gate "$R" "$P" && return 1
  return 0
}
case_cmd_outside_the_list_is_unverifiable() { local R="$1" P="$TMP/c3.plan.md" c
  for c in 'rm -rf x' 'touch canary-executed' 'grep -c line lib/math.sh | cat' 'grep -c line lib/math.sh; touch canary-executed' \
           'grep -c line lib/math.sh && touch canary-executed' 'grep -c line $(touch canary-executed)' 'wc -c app.txt' \
           'grep -rc line lib' 'grep -c line lib/math.sh app.txt' 'grep -c line lib/math.sh > canary-executed' \
           'grep -c -e canary-executed app.txt' 'grep -c -- app.txt' 'test -d lib' 'cat app.txt' 'grep -c "line" lib/math.sh' \
           'grep -c --include=x line lib/math.sh' 'grep -c -f lib/math.sh app.txt' ''; do
    mkplan "$P" "$VCMD" "- x :: cmd \`$c\` == 9"
    gate "$R" "$P" && { echo "passed: $c" >&2; return 1; }
    reason_is UNVERIFIABLE || { echo "  for: $c" >&2; return 1; }
    [ ! -e "$REPO/canary-executed" ] || { echo "executed: $c" >&2; return 1; }
  done
  # without == N, or with a malformed N, it is not a checkable premise either
  for c in '- x :: cmd `grep -c line lib/math.sh`' '- x :: cmd `grep -c line lib/math.sh` == nine' '- x :: cmd `grep -c line lib/math.sh` == 9 and more' \
           '- x :: cmd `grep -c line lib/math.sh` >= 9' '- x :: cmd grep -c line lib/math.sh == 9'; do
    mkplan "$P" "$VCMD" "$c"; gate "$R" "$P" && { echo "passed: $c" >&2; return 1; }
    reason_is UNVERIFIABLE || return 1
  done
  return 0
}
case_cmd_path_outside_the_repo_is_unverifiable() { local R="$1" P="$TMP/c4.plan.md" c rc
  ln -sf ../outside.txt "$REPO/link.txt"
  for c in 'grep -c secret ../outside.txt' 'grep -c secret /etc/passwd' 'wc -l ../outside.txt' 'test -f ../outside.txt' \
           'grep -c secret lib/../../outside.txt' 'grep -c secret link.txt' 'test -f link.txt' 'wc -l ~/x' 'grep -c secret -x'; do
    mkplan "$P" "$VCMD" "- x :: cmd \`$c\` == 1"
    gate "$R" "$P"; rc=$?
    reason_is UNVERIFIABLE || { rm -f "$REPO/link.txt"; echo "  for: $c" >&2; return 1; }
    [ "$rc" = 1 ] || { rm -f "$REPO/link.txt"; return 1; }
  done
  rm -f "$REPO/link.txt"
  mkplan "$P" "$VCMD" '- x :: cmd `grep -c line lib` == 0'; gate "$R" "$P" && return 1   # a directory is not read either
  # no checkout of the plan's repo and no explicit root: nowhere to check -> UNVERIFIABLE
  mkplan "$P" "$VCMD" '- x :: cmd `test -f app.txt` == 1'
  GATE_OUT="$(DEVBRAIN_PROJECTS_DIR="$TMP/none" python3 -I "$R/lib/verifier.py" gate "$P" 2>&1 < /dev/null)" && return 1
  reason_is UNVERIFIABLE
}
case_cmd_without_verificado_does_not_pass() { local R="$1" P="$TMP/c5.plan.md"
  mkplan "$P" - '- app exists :: cmd `test -f app.txt` == 1'     # true, but nobody ran the verifier
  gate "$R" "$P" && return 1
  case "$GATE_OUT" in *verificado*) ;; *) return 1 ;; esac
  mkplan "$P" "" '- app exists :: cmd `test -f app.txt` == 1'; gate "$R" "$P" && return 1
  return 0
}
case_cmd_exit_other_than_0_or_1_is_false() { local R="$1" P="$TMP/c6.plan.md"
  mkplan "$P" "$VCMD" '- x :: cmd `grep -c line missing.txt` == 0'    # grep exits 2: not a 0 you can believe
  gate "$R" "$P" && return 1
  reason_is FALSE || return 1
  mkplan "$P" "$VCMD" '- x :: cmd `wc -l missing.txt` == 0'; gate "$R" "$P" && return 1
  # with a closed list an error leaves no readable output: test the exit code with a fake subprocess that DOES print a 0 and exits 2
  python3 -I -c '
import sys, subprocess, types
sys.path.insert(0, sys.argv[1] + "/lib")
import verifier as v
subprocess.run = lambda *a, **k: types.SimpleNamespace(returncode=2, stdout=b"0\n", stderr=b"")
r = v.check_cmd(sys.argv[2], "`grep -c zzz app.txt` == 0")
sys.exit(0 if r[0] == "FALSE" else 1)' "$R" "$REPO" || return 1
  mkplan "$P" "$VCMD" '- x :: cmd `grep -c zzz app.txt` == 0'; gate "$R" "$P"   # grep exits 1 on zero matches: a legitimate 0
}
case_cmd_does_not_call_the_model() { local R="$1" P="$TMP/c7.plan.md"
  mkplan "$P" - '- multiply :: cmd `grep -c line lib/math.sh` == 9' '- app :: cmd `test -f app.txt` == 1'
  # cmd lines are not citations: the prompt has nothing to ask (rc 10) and no session opens
  python3 -I "$R/lib/verifier.py" prompt "$P" "$REPO" ctx > "$TMP/c7.prompt" 2>&1; [ $? = 10 ] || return 1
  python3 -I "$R/lib/verifier.py" apply "$P" "$REPO" - ctx > /dev/null 2>&1 || return 1
  grep -q '^- app :: cmd `test -f app.txt` == 1$' "$P" || return 1       # the script does not rewrite the line
  sed -n 's/^verificado: //p' "$P" | grep -q . || return 1
  gate "$R" "$P" || return 1
  # a hand-written HOLDS on a cmd line is not believed: it is re-run
  mkplan "$P" "$VCMD" '- four :: cmd `grep -c line lib/math.sh` == 4 :: HOLDS'; gate "$R" "$P" && return 1
  return 0
}
case_cmd_runs_with_a_10s_timeout() { local R="$1"
  # a fake subprocess records how it is called: timeout 10, no shell, cwd in the repo, argv a list; a timeout is UNVERIFIABLE
  python3 -I -c '
import sys, subprocess, types
sys.path.insert(0, sys.argv[1] + "/lib")
import verifier as v
seen = {}
def fake(argv, **k):
    seen.update(k, argv=argv)
    raise subprocess.TimeoutExpired(argv, k.get("timeout", 0))
subprocess.run = fake
r = v.check_cmd(sys.argv[2], "`grep -c zzz app.txt` == 0")
ok = (r[0] == "UNVERIFIABLE" and seen.get("timeout") == 10 and isinstance(seen["argv"], list)
      and not seen.get("shell") and seen.get("cwd") == sys.argv[2])
sys.exit(0 if ok else 1)' "$R" "$REPO"
}
case_cmd_arity_of_wc_and_test() { local R="$1" P="$TMP/c8.plan.md" c
  # wc -l and test -f take exactly ONE operand: with two, the second would skip the path check
  for c in 'wc -l app.txt /etc/passwd == 3' 'wc -l app.txt lib/math.sh == 3' 'wc -l == 3' 'test -f app.txt lib/math.sh == 1' \
           'test -f app.txt /etc/passwd == 1' 'test -f == 1'; do
    mkplan "$P" "$VCMD" "- x :: cmd \`${c% == *}\` == ${c##* == }"
    gate "$R" "$P" && { echo "passed: $c" >&2; return 1; }
    reason_is UNVERIFIABLE || return 1
  done
  mkplan "$P" "$VCMD" '- x :: cmd `wc -l app.txt` == 3' '- y :: cmd `test -f app.txt` == 1'; gate "$R" "$P"
}
case_cmd_bad_plan_repo_does_not_leave_projects() { local R="$1" P="$TMP/c9.plan.md" r
  mkdir -p "$TMP/pd"      # projects dir = $TMP/pd; `../repo` would point at $TMP/repo, which exists and has app.txt
  for r in '../../..' '../repo' '..' '/tmp' 'a/b' './repo' '../pd' '.hidden'; do
    mkplan "$P" "$VCMD" '- x :: cmd `test -f app.txt` == 1'; setrepo "$P" "$r"
    gate_noroot "$R" "$P" "$TMP/pd" && { echo "passed with repo: $r" >&2; return 1; }
    reason_is UNVERIFIABLE || { echo "  for repo: $r" >&2; return 1; }
  done
  return 0
}
case_cmd_fifo_does_not_hang() { local R="$1" P="$TMP/c10.plan.md" c t rc dt
  mkfifo "$REPO/pipe" || return 1
  for c in 'grep -c line pipe' 'wc -l pipe'; do
    mkplan "$P" "$VCMD" "- x :: cmd \`$c\` == 0"
    t=$SECONDS; gate "$R" "$P"; rc=$?; dt=$((SECONDS - t))
    [ "$rc" = 1 ] && case "$GATE_OUT" in "premise UNVERIFIABLE"*|"premise FALSE"*) true ;; *) false ;; esac && [ "$dt" -lt 3 ] \
      || { rm -f "$REPO/pipe"; echo "FIFO: $c rc=$rc in ${dt}s -> $GATE_OUT" >&2; return 1; }
  done
  rm -f "$REPO/pipe"
}
case_cmd_huge_n_is_unverifiable() { local R="$1" P="$TMP/c11.plan.md" n
  n="$(python3 -c 'print("9"*5000)')"
  mkplan "$P" "$VCMD" "- x :: cmd \`grep -c line lib/math.sh\` == $n"
  gate "$R" "$P" && return 1
  reason_is UNVERIFIABLE || return 1
  mkplan "$P" "$VCMD" '- x :: cmd `grep -c line lib/math.sh` == 9999999999'; gate "$R" "$P" && return 1   # 10 digits: neither
  reason_is UNVERIFIABLE || return 1
  mkplan "$P" "$VCMD" '- x :: cmd `grep -c line lib/math.sh` == 999999999'; gate "$R" "$P" && return 1   # 9 digits: compared, FALSE
  reason_is FALSE || return 1
  mkplan "$P" "$VCMD" '- x :: cmd `grep -c line lib/math.sh` == 9'; gate "$R" "$P"
}
case_cmd_in_the_exempt_section_is_not_run() { local R="$1" P="$TMP/c12.plan.md"
  mkplan "$P" "$VCMD" '- app exists :: cmd `test -f app.txt` == 1'
  { printf '\n## Tenth man (written by devbrain-tenth-man)\n\n'
    printf -- '- objection :: cmd `grep -c line lib/math.sh` == 4\n- other :: cmd `rm -rf x`\n'
    printf '\n## Another section\n\n- Nothing else.\n'; } >> "$P"
  gate "$R" "$P" || { echo "$GATE_OUT" >&2; return 1; }
  mkplan "$P" "$VCMD" '- false :: cmd `grep -c line lib/math.sh` == 4'; gate "$R" "$P" && return 1   # same line outside the exempt zone does run
  return 0
}
case_cmd_kit_root_fallback() { local R="$1" P="$TMP/c13.plan.md"
  # DEVBRAIN_SELF_REPO=example-kit (set in gate_noroot): no directory under the projects dir -> the root is this kit's checkout
  mkplan "$P" "$VCMD" '- the verifier exists :: cmd `test -f lib/verifier.py` == 1'; setrepo "$P" example-kit
  gate_noroot "$R" "$P" || { echo "$GATE_OUT" >&2; return 1; }
  mkplan "$P" "$VCMD" '- the verifier is absent :: cmd `test -f lib/verifier.py` == 0'; setrepo "$P" example-kit
  gate_noroot "$R" "$P" && return 1
  reason_is FALSE || return 1
  # not generalized: another repo with no directory has nowhere to be checked
  mkplan "$P" "$VCMD" '- the verifier exists :: cmd `test -f lib/verifier.py` == 1'; setrepo "$P" example-org-app
  gate_noroot "$R" "$P" && return 1
  reason_is UNVERIFIABLE || return 1
  # a real directory under the projects dir wins over the fallback
  mkdir -p "$TMP/pd-kit/example-kit"
  mkplan "$P" "$VCMD" '- the verifier exists :: cmd `test -f lib/verifier.py` == 1'; setrepo "$P" example-kit
  gate_noroot "$R" "$P" "$TMP/pd-kit" && return 1
  reason_is FALSE
}

CASES="cmd_holds cmd_false_planted cmd_outside_the_list_is_unverifiable cmd_path_outside_the_repo_is_unverifiable cmd_without_verificado_does_not_pass cmd_exit_other_than_0_or_1_is_false cmd_does_not_call_the_model cmd_runs_with_a_10s_timeout cmd_arity_of_wc_and_test cmd_bad_plan_repo_does_not_leave_projects cmd_fifo_does_not_hang cmd_huge_n_is_unverifiable cmd_in_the_exempt_section_is_not_run cmd_kit_root_fallback"
for c in $CASES; do "case_$c" "$DIR" && echo "OK: $c" || { echo "FAIL: case $c"; exit 1; }; done

# ---- mutations: each in a copy; the case that catches it must go RED ----
MUTD="$(mktemp -d "$TMP/mut.XXXXXX")"
mutate() { # <name> <file> <python expression s -> s>
  rm -rf "${MUTD:?}"/*; mkdir -p "$MUTD/lib"; cp "$DIR"/lib/*.py "$MUTD/lib/"
  F="$MUTD/$2" EXPR="$3" python3 -c '
import os,sys
p=os.environ["F"]; s=open(p,encoding="utf-8").read()
n=eval("lambda s: "+os.environ["EXPR"])(s)   # only expressions written in THIS file
if n==s: sys.exit(3)
open(p,"w",encoding="utf-8").write(n)' || { echo "FAIL: could not plant the mutation \"$1\""; die; }
}
must_go_red() { # <mutation> <case>
  "case_$2" "$MUTD" && { echo "FAIL: the mutation \"$1\" goes unnoticed: case $2 cannot fail"; die; }
  echo "OK: the mutation \"$1\" goes red in $2"
}
V=lib/verifier.py
mutate "no closed list (any command runs)" $V "s.replace('def allowed(argv, root):', 'def allowed(argv, root):\n    return \"\"\n\n\ndef _old_allowed(argv, root):')"
must_go_red "no closed list" cmd_outside_the_list_is_unverifiable
mutate "no path-in-repo check" $V "s.replace('def path_in_repo(root, path, regular):', 'def path_in_repo(root, path, regular):\n    return \"\"\n\n\ndef _old_path(root, path, regular):')"
must_go_red "no path-in-repo check" cmd_path_outside_the_repo_is_unverifiable
mutate "any exit code will do" $V "s.replace('if r.returncode not in (0, 1):', 'if False:')"
must_go_red "any exit code will do" cmd_exit_other_than_0_or_1_is_false
mutate "the count is not compared with N" $V "s.replace('if value == expected else', 'if True else')"
must_go_red "the count is not compared with N" cmd_false_planted
mutate "gate does not run cmd premises" $V "s.replace('for _, claim, rest in cmds:', 'for _, claim, rest in []:')"
must_go_red "gate does not run cmd premises" cmd_false_planted
mutate "a cmd without verificado: passes" $V "s.replace('if not verified:', 'if False:')"
must_go_red "a cmd without verificado: passes" cmd_without_verificado_does_not_pass
mutate "cmd lines go to the model as citations" $V "s.replace('    return classify(root, premises(body))[0]', '    return classify(root, premises(body))[0] or [(0, \"x\", \"app.txt:1\", None)]')"
must_go_red "always asks the model" cmd_does_not_call_the_model
mutate "a malformed cmd premise is ignored" $V "s.replace('return \"UNVERIFIABLE\", \"expected form', 'return \"HOLDS\", \"expected form')"
must_go_red "a malformed cmd premise is ignored" cmd_outside_the_list_is_unverifiable
mutate "wc -l without arity check" $V "s.replace('argv[:2] == [\"wc\", \"-l\"] and len(argv) == 3', 'argv[:2] == [\"wc\", \"-l\"]')"
must_go_red "wc -l without arity check" cmd_arity_of_wc_and_test
mutate "test -f without arity check" $V "s.replace('argv[:2] == [\"test\", \"-f\"] and len(argv) == 3', 'argv[:2] == [\"test\", \"-f\"]')"
must_go_red "test -f without arity check" cmd_arity_of_wc_and_test
mutate "plan repo: not validated" $V "s.replace('if not re.fullmatch(r\"[A-Za-z0-9][A-Za-z0-9._-]*\", repo):', 'if False:')"
must_go_red "plan repo: not validated" cmd_bad_plan_repo_does_not_leave_projects
mutate "no regular-file guard (FIFO)" $V "s.replace('if regular and os.path.exists(p)', 'if False and os.path.exists(p)')"
must_go_red "no regular-file guard" cmd_fifo_does_not_hang
mutate "N without a digit cap" $V "s.replace('([0-9]{1,9})\$', '([0-9]+)\$')"
must_go_red "N without a digit cap" cmd_huge_n_is_unverifiable
mutate "cmd_premises ignores the exempt zone" $V "s.replace('for i, l in zone(body):\n        m = CMD.match(l)', 'for i, l in enumerate(body):\n        m = CMD.match(l)')"
must_go_red "cmd_premises ignores the exempt zone" cmd_in_the_exempt_section_is_not_run
mutate "no kit root fallback" $V "s.replace('if repo == SELF_REPO else None', 'if False else None')"
must_go_red "no kit root fallback" cmd_kit_root_fallback
mutate "the fallback applies to any repo" $V "s.replace('if repo == SELF_REPO else None', 'if True else None')"
must_go_red "the fallback applies to any repo" cmd_kit_root_fallback
mutate "no timeout" $V "s.replace('timeout=CMD_SECS,', '')"
must_go_red "no timeout" cmd_runs_with_a_10s_timeout

# control: a mutation that does not change behavior leaves everything green (if not, "red" proved nothing)
mutate "control: a comment" $V "s + '\n# control\n'"
for c in $CASES; do "case_$c" "$MUTD" || { echo "FAIL: the control (only a comment) broke $c: the mutation setup is not reliable"; die; }; done
echo "OK: the control (comment) leaves the $(echo $CASES | wc -w | tr -d ' ') cases green"
echo "PASS: test-verifier-cmd-premises"

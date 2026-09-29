#!/bin/bash
# test-verify-run.sh — devbrain-verify-run: the real trap, and the cases that MUST fail.
#
# The trap: after `cd frontend && ...` the session's shell stays in frontend/, and the
# next `cd frontend && ...` fails. The script does the cd itself, so two calls in a row
# from ANY directory must work.
set -uo pipefail
VR="$(cd "$(dirname "$0")/.." && pwd)/bin/devbrain-verify-run"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

mkdir -p "$T/projects/demo/frontend/node_modules" "$T/projects/demo/otro" "$T/mc"
git -C "$T/projects/demo" init -q
printf '{"scripts":{"probe":"pwd > ../ran-in.txt","test:run":"echo TESTRUN"}}\n' > "$T/projects/demo/frontend/package.json"
printf 'demo=npm run probe@frontend,npm run test:run@frontend,npm test\n' > "$T/mc/devbrain-verify.commands"
export DEVBRAIN_PROJECTS_DIR="$T/projects" DEVBRAIN_VERIFY_COMMANDS_FILE="$T/mc/devbrain-verify.commands"

# 1. corre desde la raiz del repo
( cd "$T/projects/demo" && "$VR" demo npm run probe >/dev/null 2>&1 ) || fail "did not run from the repo root"
[ "$(cat "$T/projects/demo/ran-in.txt")" = "$(cd "$T/projects/demo/frontend" && pwd -P)" ] \
  || fail "ran in the wrong directory: $(cat "$T/projects/demo/ran-in.txt")"
echo "OK: runs in the declared subdir, not wherever the session is standing"

# 2. THE TRAP: two calls in a row, the second with the shell already INSIDE frontend/
# (capture before matching: `cmd | grep -q` under pipefail gives 141 from SIGPIPE, not a real failure)
OUT2="$( cd "$T/projects/demo/frontend" \
  && "$VR" demo npm run probe >/dev/null 2>&1 \
  && "$VR" demo npm run test:run 2>&1 )" || fail "the second call from inside frontend/ failed (the trap is still alive)"
[[ "$OUT2" == *TESTRUN* ]] || fail "the second call did not produce the expected output: $OUT2"
echo "OK: two consecutive calls from inside the subdir work"

# 3. the command's exit code propagates
printf '{"scripts":{"probe":"exit 7","test:run":"exit 7"}}\n' > "$T/projects/demo/frontend/package.json"
"$VR" demo npm run probe >/dev/null 2>&1; [ $? -eq 7 ] || fail "did not propagate the command exit code"
printf '{"scripts":{"probe":"pwd > ../ran-in.txt","test:run":"echo TESTRUN"}}\n' > "$T/projects/demo/frontend/package.json"
echo "OK: the exit code propagates"

# ---- the ones that MUST fail ---------------------------------------------------
reject() { # <description> <args...>
  local d="$1"; shift
  rm -f "$T/projects/demo/ran-in.txt"
  "$VR" "$@" >/dev/null 2>"$T/err"; local rc=$?
  [ "$rc" -ne 0 ] || fail "accepted: $d"
  [ -s "$T/err" ] || fail "rejected silently: $d"
  [ ! -e "$T/projects/demo/ran-in.txt" ] || fail "rejected but ran anyway: $d"
}
reject "undeclared command"                 demo npm run build
reject "extra argument"                     demo npm run probe -- --evil
reject "smuggled semicolon"                demo npm run probe ';' touch "$T/pwned"
reject "smuggled &&"                       demo npm run probe '&&' touch "$T/pwned"
reject "command declared WITHOUT @subdir"   demo npm test
reject "nonexistent repo"                 nothere npm run probe
reject "repo name with .."                ../demo npm run probe
reject "no arguments"
[ ! -e "$T/pwned" ] || fail "something smuggled through a separator was executed"
echo "OK: 8 cases that must fail do fail, with a message and without running anything"

# a subdir that escapes the repo through a symlink
ln -s /tmp "$T/projects/demo/escape"
printf 'demo=npm run probe@escape\n' > "$T/mc/devbrain-verify.commands"
reject "subdir that escapes via symlink" demo npm run probe
printf 'demo=npm run probe@../x,npm run probe@/etc\n' > "$T/mc/devbrain-verify.commands"
reject "subdir with .. or absolute (entry ignored)" demo npm run probe
echo "OK: symlink, .. and absolute path do not pass"

# ---- --check ---------------------------------------------------------------
printf 'demo=npm run probe@frontend,npm run test:run@frontend\n' > "$T/mc/devbrain-verify.commands"
"$VR" --check demo >/dev/null || fail "--check was red on a healthy repo"
echo "OK: --check green on a healthy repo"

check_red() { # <description> <pattern>
  local out; out="$("$VR" --check demo 2>&1)"; local rc=$?
  [ "$rc" -eq 1 ] || fail "--check was not red: $1"
  grep -qi -- "$2" <<<"$out" || fail "--check was red but did not explain ($1): $out"
}
mv "$T/projects/demo/frontend/node_modules" "$T/nm"
check_red "node_modules missing" "node_modules"
mv "$T/nm" "$T/projects/demo/frontend/node_modules"
printf '{"scripts":{"probe":"true","test:run":"true"},"devDependencies":{"jsdom":"^30"}}\n' > "$T/projects/demo/frontend/package.json"
printf 'demo=npm run probe@frontend\n' > "$T/mc/devbrain-verify.commands"
check_red "node_modules exists but a declared dependency is missing" "not installed"
mkdir -p "$T/projects/demo/frontend/node_modules/jsdom"
"$VR" --check demo >/dev/null || fail "--check was red with the dependency installed"
printf '{"scripts":{"probe":"pwd > ../ran-in.txt","test:run":"echo TESTRUN"}}\n' > "$T/projects/demo/frontend/package.json"
printf 'demo=npm run noexiste@frontend\n' > "$T/mc/devbrain-verify.commands"
check_red "the script is not in package.json" "does not define the script"
printf 'demo=npm run probe@fantasma\n' > "$T/mc/devbrain-verify.commands"
check_red "the subdir does not exist" "does not exist"
echo "OK: --check fires on missing node_modules, missing dependency, missing script, missing subdir"

echo "PASS: devbrain-verify-run"

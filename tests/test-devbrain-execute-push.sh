#!/bin/bash
# tests/test-devbrain-execute-push.sh — `devbrain execute`: every push of the branch goes
# through the secret review, a blocked plan keeps its work and pushes only after that review,
# and a failing `gh pr create` leaves a cause.
#
# The REAL bin/devbrain runs against temporary repos: a bare origin, a fake `claude` (the
# session is written by each case in $T/scene.sh) and a fake `gh`, a temporary HOME. Real gh,
# claude and curl are never reached: their stubs exit 97, and the fake claude ABORTS if `~` is
# not the temporary HOME. The key-shaped value is built at run time from two halves.
#
# Cases:
#   1  clean work: reviewed, pushed, PR created, result file says rama:
#   2  a key in the work: no push, no PR, exit 11, the value is never printed
#   3  blocked + clean work: committed, pushed, no PR, no reviewer, exit 9; the command's
#      arguments (a password) never reach the output
#   4  blocked + a key: committed but not pushed, exit 9
#   5  blocked + no work of its own: nothing pushed
#   6  `gh pr create` fails: exit 10 with its message, branch already pushed
#   7  the session's exit code is kept; a push-result.txt forged by the session is deleted
#   8  the session moves refs/remotes/origin/<base> to HEAD: the review still finds the key
#   9  origin cannot be refreshed: the review fails closed, nothing is pushed
#  10  an old push-result.txt does not survive an early exit
#  11  nor an exit before the execute case (not allowlisted, no stored plan)
[ -z "${OPENCLAW_CLI+x}" ] && [ "${OPENCLAW_SHELL-}" != exec ] || { echo "FAIL: these tests do not run under OpenClaw" >&2; exit 1; }
set -u
DIR="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; T="$(cd "$T" && pwd -P)"
SAFEPATH=/usr/bin:/bin:/opt/homebrew/bin
FAILS=""
trap 'rm -rf "$T"' EXIT
red() { FAILS="$FAILS $1 "; echo "FAIL $1: $2"; }
good() { case "$FAILS" in *" $1 "*) ;; *) echo "OK   $1: $2" ;; esac; }

mkdir -p "$T/home" "$T/stubs"
for s in gh curl claude openclaw; do
  printf '#!/bin/bash\necho "stub %s: must not be called" >> "%s/STUB-CALLED"\nexit 97\n' "$s" "$T" > "$T/stubs/$s"
  chmod +x "$T/stubs/$s"
done
cat > "$T/fake-claude" <<EOF
#!/bin/bash
[ "\$(cd ~ 2>/dev/null && pwd -P)" = "$T/home" ] || { echo "~ is not $T/home" > "$T/ABORT"; exit 99; }
cat >/dev/null
case "\$*" in
  *acceptEdits*) . "\$FAKE_SCENE" ;;
  *) echo review >> "\$FAKE_LOG/reviewer.log"; echo "VERDICT: APPROVE" ;;
esac
EOF
cat > "$T/fake-gh" <<'EOF'
#!/bin/bash
echo "$*" >> "$FAKE_LOG/gh.log"
if [ -n "${FAKE_GH_FAIL:-}" ]; then echo "GraphQL: simulated failure" >&2; exit 1; fi
echo https://example.test/pull/1
EOF
chmod +x "$T/fake-claude" "$T/fake-gh"
printf 'scratch\n' > "$T/allow"

# A key-shaped value, assembled at run time.
KEY="$(printf 'sk%s%s' '-' 'aB3dE6gH9jK2mN5pQ8sT1vX4')"

g() { env -i HOME="$T/home" PATH="$SAFEPATH" git -c user.email=t@t.t -c user.name=t "$@"; }

# fixture <name>: a shared checkout with its own bare origin. A new one per run: the branch is
# called devbrain/<slug>-<mmdd-HHMM>, so two runs in the same repo and minute would collide.
fixture() {
  F="$T/$1"; rm -rf "$F"; mkdir -p "$F/log" "$F/projects"
  PROJ="$F/projects"; SHARED="$PROJ/scratch"; ORIGIN="$F/origin.git"
  g init -q --bare -b main "$ORIGIN"
  g clone -q "$ORIGIN" "$SHARED" 2>/dev/null
  g -C "$SHARED" config user.email t@t.t; g -C "$SHARED" config user.name t
  printf '.devbrain/\n' > "$SHARED/.gitignore"; echo base > "$SHARED/a.txt"
  g -C "$SHARED" add -A; g -C "$SHARED" commit -qm base; g -C "$SHARED" push -q origin HEAD:main 2>/dev/null
  rm -f "$T/ABORT"
}
scene() { cat > "$T/scene.sh"; }

run_execute() { # -> OUT, RC
  mkdir -p "$SHARED/.devbrain"
  if [ -z "${NO_PLAN:-}" ]; then
    printf 'Add feature.txt\n' > "$SHARED/.devbrain/plan-latest.md"
    printf 'add feature\n' > "$SHARED/.devbrain/task-latest.txt"
  fi
  OUT="$(cd "$T" && env -i HOME="$T/home" PATH="$T/stubs:$SAFEPATH" LANG=en_US.UTF-8 DEVBRAIN_NO_TG=1 \
      DEVBRAIN_PROJECTS_DIR="$PROJ" DEVBRAIN_ALLOWFILE="${ALLOW_OVERRIDE:-$T/allow}" DEVBRAIN_CLAUDE_BIN="$T/fake-claude" \
      DEVBRAIN_GH_BIN="$T/fake-gh" FAKE_SCENE="$T/scene.sh" FAKE_LOG="$F/log" KEY_FOR_TEST="$KEY" ${FAKE_GH_FAIL:+FAKE_GH_FAIL=1} \
      perl -e 'alarm 120; exec @ARGV' "$DIR/bin/devbrain" execute scratch 2>&1)"; RC=$?
  [ ! -e "$T/ABORT" ] || { echo "ABORT: $(cat "$T/ABORT")"; exit 1; }
}
origin_branches() { git -C "$ORIGIN" for-each-ref --format='%(refname:short)' refs/heads/devbrain/; }
local_branches() { git -C "$SHARED" for-each-ref --format='%(refname:short)' refs/heads/devbrain/; }
result() { cat "$SHARED/.devbrain/push-result.txt" 2>/dev/null; }
pr_created() { grep -q 'pr create' "$F/log/gh.log" 2>/dev/null; }
reviewer_ran() { [ -s "$F/log/reviewer.log" ]; }
leaked() { printf '%s' "$OUT" | grep -qF -- "$1"; }

# ---- 1. clean work ---------------------------------------------------------------------------
fixture c1
scene <<'EOF'
echo "feature" > feature.txt
EOF
run_execute
[ "$RC" = 0 ] || red 1 "rc=$RC: $OUT"
printf '%s' "$OUT" | grep -q 'PR ready for review: https://example.test/pull/1' || red 1 "no PR line: $OUT"
[ -n "$(origin_branches)" ] || red 1 "the branch was not pushed"
case "$(result)" in "rama: devbrain/"*) ;; *) red 1 "push-result.txt: [$(result)]" ;; esac
pr_created && reviewer_ran || red 1 "the reviewer and the PR must both run"
good 1 "clean work: reviewed, pushed, PR created, push-result says rama:"

# ---- 2. a key in the work ----------------------------------------------------------------------
fixture c2
scene <<'EOF'
echo "feature" > feature.txt
printf 'token = %s\n' "$KEY_FOR_TEST" > conf.txt
EOF
run_execute
[ "$RC" = 11 ] || red 2 "rc=$RC (expected 11): $OUT"
printf '%s' "$OUT" | grep -q 'ERROR: push stopped by the secret review: conf.txt (pattern generic-sk)' || red 2 "message: $OUT"
[ -z "$(origin_branches)" ] || red 2 "a branch with a key reached origin"
[ -n "$(local_branches)" ] || red 2 "the commit must stay on a local branch"
pr_created && red 2 "a PR was created for a branch the review stopped"
leaked "$KEY" && red 2 "the output printed the key value"
case "$(result)" in "not pushed: "*) ;; *) red 2 "push-result.txt: [$(result)]" ;; esac
good 2 "a key in the work: exit 11, no push, no PR, no value in the output"

# ---- 3. blocked + clean work -------------------------------------------------------------------
fixture c3
scene <<'EOF'
echo "feature" > feature.txt
printf 'PGPASSWORD=correct-horse-battery psql -h db.example.test\n' > .devbrain/blocked-by.txt
EOF
run_execute
[ "$RC" = 9 ] || red 3 "rc=$RC (expected 9): $OUT"
printf '%s' "$OUT" | grep -q '^BLOCKED: psql$' || red 3 "the output must name only the program: $OUT"
leaked "correct-horse-battery" && red 3 "the password reached the output"
printf '%s' "$OUT" | grep -q 'Branch pushed: devbrain/' || red 3 "the branch was not pushed: $OUT"
[ -n "$(origin_branches)" ] || red 3 "origin has no branch"
case "$(result)" in "rama: devbrain/"*) ;; *) red 3 "push-result.txt: [$(result)]" ;; esac
pr_created && red 3 "a blocked plan must not get a PR"
reviewer_ran && red 3 "a blocked plan must not reach the reviewer"
[ -z "$(g -C "$SHARED" status --porcelain)" ] || red 3 "work left loose in the checkout: $(g -C "$SHARED" status --porcelain)"
g -C "$SHARED" show --name-only --format= HEAD | grep -q feature.txt || red 3 "the work was not committed"
good 3 "blocked + clean work: committed, pushed, no PR, no reviewer, no password"

# ---- 4. blocked + a key ------------------------------------------------------------------------
fixture c4
scene <<'EOF'
printf 'token = %s\n' "$KEY_FOR_TEST" > conf.txt
echo "psql" > .devbrain/blocked-by.txt
EOF
run_execute
[ "$RC" = 9 ] || red 4 "rc=$RC (expected 9): $OUT"
printf '%s' "$OUT" | grep -q 'Branch not pushed: conf.txt (pattern generic-sk)' || red 4 "message: $OUT"
[ -z "$(origin_branches)" ] || red 4 "a branch with a key reached origin"
[ -n "$(local_branches)" ] && [ -z "$(g -C "$SHARED" status --porcelain)" ] || red 4 "the work must be committed on a local branch"
leaked "$KEY" && red 4 "the output printed the key value"
good 4 "blocked + a key: committed locally, not pushed, exit 9"

# ---- 5. blocked + no work of its own -----------------------------------------------------------
fixture c5
scene <<'EOF'
echo "psql" > .devbrain/blocked-by.txt
EOF
run_execute
[ "$RC" = 9 ] || red 5 "rc=$RC (expected 9): $OUT"
[ -z "$(origin_branches)" ] || red 5 "an empty branch was pushed"
[ "$(result)" = "not pushed: no work of its own" ] || red 5 "push-result.txt: [$(result)]"
good 5 "blocked + no work of its own: nothing pushed"

# ---- 6. gh pr create fails ---------------------------------------------------------------------
fixture c6
scene <<'EOF'
echo "feature" > feature.txt
EOF
FAKE_GH_FAIL=1 run_execute
[ "$RC" = 10 ] || red 6 "rc=$RC (expected 10): $OUT"
printf '%s' "$OUT" | grep -q 'ERROR: creating the PR failed (gh pr create): GraphQL: simulated failure' || red 6 "the gh message is not in the output: $OUT"
[ -n "$(origin_branches)" ] || red 6 "the branch should already be pushed when gh fails"
good 6 "gh pr create fails: exit 10 with its own message"

# ---- 7. the session's exit code, and a forged result file --------------------------------------
fixture c7
scene <<'EOF'
echo "rama: devbrain/forged" > .devbrain/push-result.txt
exit 3
EOF
run_execute
[ "$RC" = 3 ] || red 7 "the session's exit code must be kept (rc=$RC): $OUT"
[ ! -e "$SHARED/.devbrain/push-result.txt" ] || red 7 "a forged push-result.txt survived the session"
fixture c7b
scene <<'EOF'
echo "rama: devbrain/forged" > .devbrain/push-result.txt
echo "psql" > .devbrain/blocked-by.txt
EOF
run_execute
[ "$(result)" = "not pushed: no work of its own" ] || red 7 "a forged push-result.txt reached the result: [$(result)]"
good 7 "the session's exit code is kept and a forged push-result.txt is deleted"

# ---- 8. the session moves origin/<base> --------------------------------------------------------
fixture c8
scene <<'EOF'
printf 'token = %s\n' "$KEY_FOR_TEST" > conf.txt
git add -A && git commit -q -m "work"
git update-ref refs/remotes/origin/main HEAD
EOF
run_execute
[ "$RC" = 11 ] || red 8 "with origin/main moved to HEAD the review must still run on the real history (rc=$RC): $OUT"
[ -z "$(origin_branches)" ] || red 8 "the key reached origin"
good 8 "the session cannot hide a key by moving origin/<base>"

# ---- 9. origin cannot be refreshed -------------------------------------------------------------
fixture c9
scene <<'EOF'
echo "feature" > feature.txt
git remote set-url origin /nonexistent/nowhere.git
EOF
run_execute
[ "$RC" = 11 ] || red 9 "rc=$RC (expected 11): $OUT"
printf '%s' "$OUT" | grep -q 'could not update origin/main' || red 9 "message: $OUT"
good 9 "when origin cannot be refreshed the review fails closed"

# ---- 10. an old result file does not survive an early exit ---------------------------------------
fixture c10
mkdir -p "$SHARED/.devbrain"; echo "rama: devbrain/stale-0101-0101" > "$SHARED/.devbrain/push-result.txt"
echo dirty > "$SHARED/dirty.txt"        # an untracked file: execute stops before any session
scene <<'EOF'
echo "feature" > feature.txt
EOF
run_execute
[ "$RC" = 7 ] || red 10 "rc=$RC (expected 7, dirty tree): $OUT"
[ ! -e "$SHARED/.devbrain/push-result.txt" ] || red 10 "the stale push-result.txt survived an early exit: [$(result)]"
good 10 "a stale push-result.txt is deleted when execute starts"

# ---- 11. ... nor an early exit before the case: not on the allowlist, no stored plan ----------------
fixture c11
mkdir -p "$SHARED/.devbrain"; echo "rama: devbrain/stale-0101-0101" > "$SHARED/.devbrain/push-result.txt"
printf 'someone-else\n' > "$T/allow-other"
ALLOW_OVERRIDE="$T/allow-other" run_execute
[ "$RC" = 3 ] || red 11 "not on the allowlist: rc=$RC (expected 3): $OUT"
[ ! -e "$SHARED/.devbrain/push-result.txt" ] || red 11 "the stale push-result.txt survived the allowlist exit"
fixture c11b
mkdir -p "$SHARED/.devbrain"; echo "rama: devbrain/stale-0101-0101" > "$SHARED/.devbrain/push-result.txt"
NO_PLAN=1 run_execute
[ "$RC" = 6 ] || red 11 "no stored plan: rc=$RC (expected 6): $OUT"
[ ! -e "$SHARED/.devbrain/push-result.txt" ] || red 11 "the stale push-result.txt survived the 'no stored plan' exit"
good 11 "a stale push-result.txt is gone after an allowlist exit and after 'no stored plan'"

[ -n "$FAILS" ] && { echo "RED: cases $(printf '%s\n' $FAILS | sort -nu | tr '\n' ' ')"; exit 1; }
echo "PASS: devbrain-execute-push"

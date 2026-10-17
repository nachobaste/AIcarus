#!/bin/bash
# tests/test-devbrain-planner.sh — bin/devbrain-planner with a fake queue, repo, gh, claude and
# Telegram. Never the real queue or the real Telegram: HOME points at a temporary directory
# (the Telegram token comes from there) and Telegram's curl is a binary that only records.
[ -z "${OPENCLAW_CLI+x}" ] && [ "${OPENCLAW_SHELL-}" != exec ] || { echo "FAIL: these tests do not run under OpenClaw" >&2; exit 1; }
set -uo pipefail
die() { echo "FAIL (line ${BASH_LINENO[0]})"; exit 1; }
DIR="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$DIR/bin/devbrain-planner"
[ -f "$BIN" ] || { echo "FAIL: $BIN does not exist"; exit 1; }
bash -n "$BIN" 2>/dev/null || die

TMP="$(cd "$(mktemp -d)" && pwd -P)"
trap '[ -n "${KEEP_TMP:-}" ] && echo "TMP=$TMP" || rm -rf "$TMP"' EXIT
export FAKE_DIR="$TMP/fake"
Q="$TMP/queue"; P="$TMP/projects"; CFG="$TMP/config"; T="$TMP/tmpdir"
mkdir -p "$FAKE_DIR" "$Q" "$P" "$CFG" "$T" "$TMP/home/.openclaw"
echo '{"channels":{"telegram":{"botToken":"FAKE"}}}' > "$TMP/home/.openclaw/openclaw.json"
printf 'demo\nother\n' > "$CFG/devbrain-projects.allow"
echo 'demo=make test' > "$CFG/devbrain-verify.commands"   # `other` has no verification command on purpose
G() { git -c user.name=t -c user.email=t@t -c init.defaultBranch=main "$@"; }

# Repo "demo": a bare origin and the shared checkout. What exists only in origin is what the
# temporary worktree has to see (the checkout may be behind).
G init -q --bare "$TMP/origin.git"
G clone -q "$TMP/origin.git" "$P/demo" 2>/dev/null
echo v1 > "$P/demo/app.txt"; G -C "$P/demo" add app.txt; G -C "$P/demo" commit -qm v1; G -C "$P/demo" push -q origin HEAD:main
G clone -q "$TMP/origin.git" "$TMP/elsewhere"; echo v2 > "$TMP/elsewhere/app.txt"
G -C "$TMP/elsewhere" commit -qam v2; G -C "$TMP/elsewhere" push -q origin HEAD:main
# Repo "other": a plain checkout (the planner reads its code too).
G clone -q "$TMP/origin.git" "$P/other" 2>/dev/null

cat > "$TMP/gh" <<'FAKE'
#!/bin/bash
printf '%s\n' "$*" >> "$FAKE_DIR/gh-calls"
echo "title: the button fails"; echo "ISSUE-CONTENT-XYZZY"
FAKE
cat > "$TMP/curl" <<'FAKE'
#!/bin/bash
echo "CALL $*" >> "$FAKE_DIR/tg-calls"
FAKE
# fake claude: records argv, cwd and prompt; answers according to $FAKE_DIR/mode.
cat > "$TMP/claude" <<'FAKE'
#!/bin/bash
in="$(cat)"
n=$(( $(cat "$FAKE_DIR/n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$FAKE_DIR/n"
printf '%s\n' "$*" >> "$FAKE_DIR/claude-args"
printf '%s\n' "$PWD" >> "$FAKE_DIR/claude-pwd"
printf '%s\n' "$in" > "$FAKE_DIR/prompt-$n"
cat app.txt >> "$FAKE_DIR/claude-app" 2>/dev/null
mode="$(cat "$FAKE_DIR/mode")"
[ "$mode" = question ] && { printf 'question: Which button, the top one or the bottom one?\nA) top\nB) bottom\n'; exit 0; }
repo=demo; [ "$mode" = badrepo ] && repo=other
[ "$mode" = nobody ] && { printf 'repo: demo\n---\n'; exit 0; }
[ "$mode" = otherrepo ] && repo=other
printf 'repo: %s\n---\n# Fix the button\n\n## Requested task\n\nFix the button.\n\n' "$repo"
printf '## Why it exists\n\nThe button does not respond.\n\n'
printf '## What was already verified (2026-10-03, against `origin/main` of demo)\n\n- app.txt:1 says v2.\n\n'
printf '## Files it touches\n\n- app.txt — the text\n\n'
printf '## Cases that must pass\n\n1. The button responds.\n2. Mutations that must go red: plant a broken button and see case 1 fail.\n\n'
printf '## Constraints\n\n- Nothing else.\n\nCloses demo#3\n'
FAKE
chmod +x "$TMP/gh" "$TMP/curl" "$TMP/claude"

run() { # [hour]
  HOME="$TMP/home" TMPDIR="$T" DEVBRAIN_QUEUE_DIR="$Q" DEVBRAIN_PROJECTS_DIR="$P" \
  DEVBRAIN_CONFIG_DIR="$CFG" DEVBRAIN_PREFLIGHT_NO_FETCH=1 DEVBRAIN_TG_CHAT_ID=1 DEVBRAIN_NO_TG=0 \
  DEVBRAIN_GH_BIN="$TMP/gh" DEVBRAIN_CLAUDE_BIN="$TMP/claude" TELEGRAM_CURL_BIN="$TMP/curl" \
  DEVBRAIN_PLANNER_LOG="$TMP/log" DEVBRAIN_PLANNER_HOUR="${1:-10}" \
  "$BIN" > "$TMP/out" 2>&1
}
reset() { rm -f "$Q"/*.plan.md "$FAKE_DIR"/{claude-args,claude-pwd,claude-app,gh-calls,tg-calls,n,prompt-*}; }
request() { # <prio> <repo> <text>
  printf -- '---\nrepo: %s\nstatus: requested\nprioridad: %s\ncreado: 2026-10-03\nfuente: telegram\n---\n\n## Requested task\n\n%s\n' \
    "$2" "$1" "$3" > "$Q/$1-$2--request.plan.md"
}
fm() { awk -v k="$2" 'NR==1{next} /^---$/{exit} index($0,k": ")==1{print substr($0,length(k)+3)}' "$1"; }
cnt() { [ -f "$1" ] && grep -c -e "${2:-.}" "$1" | tr -d ' ' || echo 0; }
lint() { DEVBRAIN_CONFIG_DIR="$CFG" DEVBRAIN_PROJECTS_DIR="$P" \
         DEVBRAIN_PREFLIGHT_NO_FETCH=1 "$DIR/bin/devbrain-preflight" --plan "$1" >/dev/null 2>&1; }
TODAY="$(date +%Y-%m-%d)"

# --- The planner reads no personal sources: no mention of a personal-data CLI in its text ---
! grep -qiE '\bgog\b|gmail|calendar' "$BIN" || die

# --- Outside the window it does not run ---
reset; echo ok > "$FAKE_DIR/mode"; request 100 demo "fix the button"
for h in 6 22 23; do
  run "$h" || die
  [ ! -f "$FAKE_DIR/claude-args" ] || die
  [ -z "$(fm "$Q/100-demo--request.plan.md" planificado)" ] || die
done

# --- With .night.lock taken it touches nothing and does not release someone else's lock ---
mkdir "$Q/.night.lock"; cp "$Q/100-demo--request.plan.md" "$TMP/before"
run || die
cmp -s "$TMP/before" "$Q/100-demo--request.plan.md" || die
[ ! -f "$FAKE_DIR/claude-args" ] || die
[ -d "$Q/.night.lock" ] || die
rmdir "$Q/.night.lock"

# --- The shared checkout is behind: the session reads origin/main (v2) in a temporary worktree,
#     and since the only thing that fails is the ENVIRONMENT, the plan is written and the
#     message says so (`approve` runs the preflight again and does not approve until it is up to date) ---
reset; request 105 demo "fix the button"
run || die
F="$Q/105-demo--request.plan.md"
[ "$(cat "$FAKE_DIR/claude-app")" = v2 ] || die
[ "$(fm "$F" planificado)" = "$TODAY" ] || die
! lint "$F" || die                                            # the environment is still behind
grep -q 'Before approving' "$FAKE_DIR/tg-calls" && grep -q 'behind origin' "$FAKE_DIR/tg-calls" || die
[ "$(cnt "$FAKE_DIR/claude-args")" = 1 ] || die               # no second session: it is not the plan's fault
G -C "$P/demo" merge -q --ff-only origin/main

# --- A valid plan, with a linked issue ---
reset; request 100 demo "the button fails, see https://github.com/x/demo/issues/3 and https://github.com/x/demo/issues/9"
run || die
F="$Q/100-demo--request.plan.md"
[ "$(fm "$F" planificado)" = "$TODAY" ] || die
[ "$(fm "$F" repo)" = demo ] || die
[ "$(fm "$F" prioridad)" = 100 ] || die
[ "$(fm "$F" status)" = requested ] || die
[ -z "$(fm "$F" aprobado)" ] || die
lint "$F" || die
grep -q '^# Fix the button' "$F" || die
grep -q '^> the button fails' "$F" || die                     # the original request stays, quoted
# only the FIRST GitHub link, read-only; its content reached the session
[ "$(cnt "$FAKE_DIR/gh-calls")" = 1 ] || die
grep -qx 'issue view https://github.com/x/demo/issues/3 --comments' "$FAKE_DIR/gh-calls" || die
grep -q 'ISSUE-CONTENT-XYZZY' "$FAKE_DIR/prompt-1" || die
# the plan session read the worktree at origin/main (v2), not the stale checkout (v1)
grep -q 'origin/main' "$FAKE_DIR/prompt-1" || die
WTP="$(sed -n 1p "$FAKE_DIR/claude-pwd")"
[ "$WTP" != "$P/demo" ] || die
case "$WTP" in "$T"/*) ;; *) die ;; esac
# exactly one message: "ready", with the number and the three verbs
[ "$(cnt "$FAKE_DIR/tg-calls" '^CALL')" = 1 ] || die
grep -q 'Plan #100 ready to approve' "$FAKE_DIR/tg-calls" && grep -q 'Fix the button' "$FAKE_DIR/tg-calls" || die
grep -q 'approve 100' "$FAKE_DIR/tg-calls" && grep -q 'change 100:' "$FAKE_DIR/tg-calls" && grep -q 'deny 100' "$FAKE_DIR/tg-calls" || die
grep -q 'show 100' "$FAKE_DIR/tg-calls" || die
grep -q 'app.txt' "$FAKE_DIR/tg-calls" || die
# the temporary worktree does not stay
[ "$(G -C "$P/demo" worktree list | wc -l | tr -d ' ')" = 1 ] || die
[ -z "$(ls -A "$T")" ] || die
[ ! -d "$Q/.night.lock" ] || die
# no write tools: only Read/Glob/Grep, narrowed to the directory
[ "$(cnt "$FAKE_DIR/claude-args")" = 1 ] || die
[ "$(cnt "$FAKE_DIR/claude-args" '--tools Read,Glob,Grep --disallowedTools')" = 1 ] || die
[ "$(cnt "$FAKE_DIR/claude-args" '--permission-mode plan')" = 1 ] || die
! grep -Eq 'Write|Edit|Bash|NotebookEdit|WebFetch' "$FAKE_DIR/claude-args" || die
grep -qF -- "--allowedTools Read(/$WTP/**),Glob(/$WTP/**),Grep(/$WTP/**)" "$FAKE_DIR/claude-args" || die
# a second run does not plan it again
rm -f "$FAKE_DIR/claude-args"; run || die
[ ! -f "$FAKE_DIR/claude-args" ] || die

# --- The preflight rejects it twice: a question with the reason, nothing approved ---
# `other` has no verification command: every plan for it fails the preflight by name.
reset; echo otherrepo > "$FAKE_DIR/mode"; request 120 other "fix the button"
run || die
F="$Q/120-other--request.plan.md"
[ "$(fm "$F" status)" = question ] || die
[ -z "$(fm "$F" planificado)" ] && [ -z "$(fm "$F" aprobado)" ] || die
[ "$(fm "$F" prioridad)" = 120 ] || die
grep -q 'NO command in devbrain-verify.commands' "$F" || die   # the preflight's reason
[ "$(cnt "$FAKE_DIR/claude-args")" = 2 ] || die                # one attempt and its correction
grep -q 'previous_answer' "$FAKE_DIR/prompt-2" || die
[ "$(cnt "$FAKE_DIR/tg-calls" '^CALL')" = 1 ] || die
! grep -q 'ready to approve' "$FAKE_DIR/tg-calls" || die
[ "$(G -C "$P/demo" worktree list | wc -l | tr -d ' ')" = 1 ] && [ -z "$(ls -A "$T")" ] || die

# --- An invalid header (a repo that is not the request's) or a missing body: never written ---
reset; echo badrepo > "$FAKE_DIR/mode"; request 125 demo "fix the button"
run || die
F="$Q/125-demo--request.plan.md"
[ "$(fm "$F" status)" = question ] && [ -z "$(fm "$F" planificado)" ] || die
[ "$(cnt "$FAKE_DIR/claude-args")" = 2 ] || die
reset; echo nobody > "$FAKE_DIR/mode"; request 126 demo "fix the button"
run || die
[ "$(fm "$Q/126-demo--request.plan.md" status)" = question ] && [ -z "$(fm "$Q/126-demo--request.plan.md" planificado)" ] || die

# --- A question: status question, ONE message; `change` returns it to requested ---
reset; echo question > "$FAKE_DIR/mode"; request 130 demo "fix the button"
run || die
F="$Q/130-demo--request.plan.md"
[ "$(fm "$F" status)" = question ] && [ -z "$(fm "$F" planificado)" ] || die
grep -q 'Which button, the top one or the bottom one' "$F" && grep -q 'B) bottom' "$F" || die
[ "$(cnt "$FAKE_DIR/tg-calls" '^CALL')" = 1 ] || die
grep -q 'change 130:' "$FAKE_DIR/tg-calls" || die
HOME="$TMP/home" DEVBRAIN_QUEUE_DIR="$Q" DEVBRAIN_NO_TG=1 "$DIR/bin/devbrain-queue" change "130: the bottom one" >/dev/null 2>&1 || die
[ "$(fm "$F" status)" = requested ] && [ -z "$(fm "$F" planificado)" ] || die
grep -q 'the bottom one' "$F" || die
# and it is planned again with the answer in front of the session
echo ok > "$FAKE_DIR/mode"; rm -f "$FAKE_DIR/tg-calls"
run || die
[ "$(fm "$F" planificado)" = "$TODAY" ] || die
grep -q 'the bottom one' "$FAKE_DIR/prompt-2" || die

# --- A link to a shared Google document: a direct question, no session ---
reset; request 140 demo "look at https://docs.google.com/document/d/abc/edit"
run || die
F="$Q/140-demo--request.plan.md"
[ "$(fm "$F" status)" = question ] || die
grep -q 'links a Google document that I cannot open' "$F" || die
[ ! -f "$FAKE_DIR/claude-args" ] || die
[ "$(cnt "$FAKE_DIR/tg-calls" '^CALL')" = 1 ] || die
# with the text pasted it does not ask the same thing again
HOME="$TMP/home" DEVBRAIN_QUEUE_DIR="$Q" DEVBRAIN_NO_TG=1 "$DIR/bin/devbrain-queue" change "140: the text of the doc" >/dev/null 2>&1 || die
run || die
[ "$(fm "$F" planificado)" = "$TODAY" ] || die

# --- A repo outside the allowlist: a question, no session ---
reset; request 150 secret "something"
run || die
[ "$(fm "$Q/150-secret--request.plan.md" status)" = question ] && [ ! -f "$FAKE_DIR/claude-args" ] || die

# --- No repo (`-`): a question, no session; with `repo: demo` in the body it plans ---
reset; request 160 - "something with no repo"
run || die
[ "$(fm "$Q/160----request.plan.md" status)" = question ] && [ ! -f "$FAKE_DIR/claude-args" ] || die
grep -q 'does not say which repo' "$Q/160----request.plan.md" || die   # the question is the repo one, not another
reset; request 161 - "something with no repo"; printf '\n## Owner note\n\nrepo: demo\n' >> "$Q/161----request.plan.md"
run || die
[ -n "$(fm "$Q/161----request.plan.md" planificado)" ] || die

echo "PASS: devbrain-planner"

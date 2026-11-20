#!/bin/bash
# tests/test-close-merged.sh — bin/devbrain-close-merged: a plan whose PR is MERGED moves to done; nothing else.
# Fake queue (git repo with a fake origin) and a stubbed `gh`. Never touches ~/dev/queue or the network.
[ -z "${OPENCLAW_CLI+x}" ] && [ "${OPENCLAW_SHELL-}" != exec ] || { echo "FAIL: these tests do not run under OpenClaw" >&2; exit 1; }
set -uo pipefail
die() { echo "FAIL (line ${BASH_LINENO[0]}): ${1-}"; exit 1; }
DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(cd "$(mktemp -d)" && pwd -P)"; trap 'rm -rf "$TMP"' EXIT
source "$DIR/lib/queue.sh"
G() { git -c user.email=t@t -c user.name=t "$@"; }

# fake gh: answers by URL or number; "down" fails; logs every call with its cwd
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'EOF'
#!/bin/bash
echo "$PWD $*" >> "$GH_LOG"
[ "$1 $2" = "pr view" ] || exit 9
case "$3" in
  */pull/1)  echo '{"headRefName":"feat/1","state":"MERGED","url":"https://github.com/o/repoa/pull/1"}' ;;
  */pull/2)  echo '{"headRefName":"feat/2","state":"OPEN","url":"https://github.com/o/repoa/pull/2"}' ;;
  */pull/3)  echo '{"headRefName":"feat/3","state":"CLOSED","url":"https://github.com/o/repoa/pull/3"}' ;;
  */pull/4)  echo "error connecting to api.github.com" >&2; exit 1 ;;
  */pull/5)  echo 'not json' ;;
  */pull/6)  echo '{"headRefName":"other-branch","state":"MERGED","url":"https://github.com/o/repoa/pull/6"}' ;;
  */pull/7)  echo '{"headRefName":"x","state":"MERGED","url":"https://github.com/o/repob/pull/7"}' ;;
  42)        case "$(basename "$PWD")" in
               repoa) echo '{"headRefName":"feat/42","state":"MERGED","url":"https://github.com/o/repoa/pull/42"}' ;;
               other) echo '{"headRefName":"x","state":"MERGED","url":"https://github.com/o/repoa/pull/42"}' ;;
               *)     echo "no repo" >&2; exit 1 ;;
             esac ;;
  *)         echo "not found" >&2; exit 1 ;;
esac
EOF
chmod +x "$TMP/bin/gh"
export GH_LOG="$TMP/gh.log" DEVBRAIN_GH_BIN="$TMP/bin/gh" DEVBRAIN_NO_TG=1

Q="$TMP/home/queue"; mkdir -p "$Q" "$TMP/projects/repoa/.git" "$TMP/projects/other/.git"
export DEVBRAIN_QUEUE_DIR="$Q" DEVBRAIN_PROJECTS_DIR="$TMP/projects"
plan() { local f="$Q/$1"; shift; { echo "---"; for l in "$@"; do echo "$l"; done; echo "---"; echo "body"; } > "$f"; }
U=https://github.com/o/repoa/pull
plan 10-repoa--merged.plan.md      'repo: repoa' 'status: approved' "pr: $U/1"
plan 11-repoa--open.plan.md        'repo: repoa' 'status: approved' "pr: $U/2"
plan 12-repoa--closed.plan.md      'repo: repoa' 'status: blocked'  "pr: $U/3"
plan 13-repoa--gh-down.plan.md     'repo: repoa' 'status: failed'   "pr: $U/4"
plan 14-repoa--unreadable.plan.md  'repo: repoa' 'status: failed'   "pr: $U/5"
plan 15-repoa--other-branch.plan.md 'repo: repoa' 'status: failed'  "pr: $U/6" 'rama: feat/15'
plan 16-repob--running.plan.md     'repo: repob' 'status: running'  "pr: https://github.com/o/repob/pull/7"
plan 17-repoa--number.plan.md      'repo: repoa' 'status: blocked'  'pr: 42' 'rama: feat/42'
plan 18-other--foreign-number.plan.md 'repo: other' 'status: approved' 'pr: 42'
plan 19-none--no-checkout.plan.md  'repo: none'  'status: approved' 'pr: 42'
plan 20-repoa--list.plan.md        'repo: repoa' 'status: approved' 'pr: 333, 334, 335'
plan 21-repoa--no-pr.plan.md       'repo: repoa' 'status: approved'
plan 22-repoa--already-done.plan.md 'repo: repoa' 'status: done'    "pr: $U/1"
plan 23-repoa--paused.plan.md      'repo: repoa' 'status: paused'   "pr: $U/1"

# the queue is a git repo with an origin, like ~/dev/queue
G init -q -b main "$TMP/home"; G -C "$TMP/home" add -A; G -C "$TMP/home" commit -qm seed
G clone -q --bare "$TMP/home" "$TMP/origin.git"; G -C "$TMP/home" remote add origin "$TMP/origin.git"; G -C "$TMP/home" fetch -q origin
G -C "$TMP/home" branch -q -u origin/main

run() { GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t \
  bash "${1:-$DIR}/bin/devbrain-close-merged" > "$TMP/out" 2>&1; echo $? > "$TMP/rc"; }
st() { fm_get "$Q/$1" status; }

run
[ "$(st 10-repoa--merged.plan.md)" = done ] && echo "OK: MERGED -> done" || die "$(cat "$TMP/out")"
git -C "$TMP/home" log --format=%s | grep -qxF "queue: done 10-repoa--merged.plan.md -> $U/1 (PR merged)" \
  && echo "OK: commit with the exact message" || die "$(git -C "$TMP/home" log --format=%s)"
[ "$(git -C "$TMP/origin.git" rev-parse main)" = "$(git -C "$TMP/home" rev-parse HEAD)" ] && echo "OK: pushed to origin" || die
[ "$(st 11-repoa--open.plan.md)" = approved ] && echo "OK: OPEN -> unchanged" || die
[ "$(st 12-repoa--closed.plan.md)" = blocked ] && echo "OK: CLOSED without merge -> unchanged" || die
[ "$(st 13-repoa--gh-down.plan.md)" = failed ] && grep -q "13-repoa--gh-down.plan.md not closed -- gh failed" "$TMP/out" \
  && echo "OK: gh down -> unchanged, with a notice" || die
[ "$(st 14-repoa--unreadable.plan.md)" = failed ] && grep -q "14-.*unreadable" "$TMP/out" && echo "OK: unreadable answer -> unchanged, with a notice" || die
[ "$(st 15-repoa--other-branch.plan.md)" = failed ] && grep -q "15-.*its branch is feat/15" "$TMP/out" && echo "OK: PR from another branch -> unchanged, with a notice" || die
[ "$(st 16-repob--running.plan.md)" = done ] && echo "OK: a dead runner's running plan (lock free) also closes" || die
[ "$(st 17-repoa--number.plan.md)" = done ] && [ "$(fm_get "$Q/17-repoa--number.plan.md" pr)" = "$U/42" ] \
  && grep -q "^$TMP/projects/repoa pr view 42 " "$GH_LOG" \
  && echo "OK: numeric pr -> resolved in repo:'s checkout, done, and pr: becomes the URL" || die "$(cat "$TMP/out")"
[ "$(st 18-other--foreign-number.plan.md)" = approved ] && grep -q "18-.*not from repo other" "$TMP/out" \
  && echo "OK: number resolving to another repo's PR -> unchanged, with a notice" || die
[ "$(st 19-none--no-checkout.plan.md)" = approved ] && grep -q "19-.*no checkout of none" "$TMP/out" \
  && echo "OK: number without a checkout -> unchanged, with a notice" || die
[ "$(st 20-repoa--list.plan.md)" = approved ] && grep -q "20-.*nor a single number" "$TMP/out" && echo "OK: list of PRs -> unchanged, with a notice" || die
[ "$(st 21-repoa--no-pr.plan.md)" = approved ] && ! grep -q "21-" "$TMP/out" "$GH_LOG" && echo "OK: plan without pr -> unchanged, not queried" || die
[ "$(st 23-repoa--paused.plan.md)" = paused ] && ! grep -q "2[23]-" "$TMP/out" && echo "OK: paused and done are left alone" || die
[ "$(cat "$TMP/rc")" = 2 ] && tail -1 "$TMP/out" | grep -qx "plans with a merged PR closed 3; gh failed on 2; unresolved 4" \
  && echo "OK: rc 2 when gh failed; the last line is the summary" || die "rc=$(cat "$TMP/rc") $(tail -1 "$TMP/out")"
[ ! -d "$Q/.night.lock" ] && echo "OK: lock released" || die

# lock held (a plan is running): touches nothing, doesn't even query gh
plan 30-repoa--another-merged.plan.md 'repo: repoa' 'status: running' "pr: $U/1"
: > "$GH_LOG"; mkdir "$Q/.night.lock"; run
[ "$(st 30-repoa--another-merged.plan.md)" = running ] && [ ! -s "$GH_LOG" ] && [ -d "$Q/.night.lock" ] \
  && echo "OK: lock held -> nothing closed, the other holder's lock stays" || die "$(cat "$TMP/out")"
rmdir "$Q/.night.lock"

# arguments: --help and any other exit before touching the queue (no lock, no gh)
for a in --help -h --dry-run x; do
  : > "$GH_LOG"
  "$DIR/bin/devbrain-close-merged" "$a" > "$TMP/out" 2>&1; rc=$?
  case "$a" in -h|--help) want=0 ;; *) want=64 ;; esac
  [ "$rc" = "$want" ] && [ "$(st 30-repoa--another-merged.plan.md)" = running ] && [ ! -s "$GH_LOG" ] && [ ! -d "$Q/.night.lock" ] \
    && echo "OK: '$a' -> rc $rc, nothing closed" || die "'$a' rc=$rc $(cat "$TMP/out")"
done

# canary: without the status write, the MERGED check must go red
C="$TMP/canary"; mkdir -p "$C/bin" "$C/lib"; cp "$DIR"/lib/* "$C/lib/" 2>/dev/null
python3 - "$DIR/bin/devbrain-close-merged" "$C/bin/devbrain-close-merged" <<'PY'
import sys; s = open(sys.argv[1]).read(); a = '&& fm_set "$f" status done'
assert s.count(a) == 1; open(sys.argv[2], "w").write(s.replace(a, "&& true"))
PY
run "$C"
[ "$(st 30-repoa--another-merged.plan.md)" = running ] && echo "OK: canary — without fm_set status done the MERGED plan does not close (the check can fail)" \
  || die "canary: the plan closed without the status write"
run
[ "$(st 30-repoa--another-merged.plan.md)" = done ] && echo "OK: control — with the real code, the same plan closes" || die

echo "PASS: test-close-merged"

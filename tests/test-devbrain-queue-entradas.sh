#!/bin/bash
[ -z "${OPENCLAW_CLI+x}" ] && [ "${OPENCLAW_SHELL-}" != exec ] || { echo "FAIL: these tests do not run under OpenClaw" >&2; exit 1; }
# tests/test-devbrain-queue-entradas.sh — `devbrain-queue pause|resume` only act on a plan in
# the queue, named with a file name (not a path).
#
#   9. a valid name keeps working (pause adds 1 commit, resume restores the status)
#  10. paths, symlinks, directories and odd names exit 2 without touching anything
#  11. a valid name that only exists outside the queue still gives rc 4
#
# Temporary queue (git without origin) with a canary outside it: a 0640 plan and a symlink
# from the queue to it. Never the real queue. Example:
#   env -i HOME="$(mktemp -d)" PATH=/usr/bin:/bin:/opt/homebrew/bin LANG=en_US.UTF-8 /bin/bash tests/test-devbrain-queue-entradas.sh
set -uo pipefail
export DEVBRAIN_NO_TG=1
DIR="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$DIR/bin/devbrain-queue"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
TMP_REAL="$(cd "$TMP" && pwd -P)"
Q="$TMP/queue"; O="$TMP/outside"
mkdir -p "$Q/sub" "$O" "$Q/d.plan.md"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t.t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t.t
export GIT_AUTHOR_DATE=2026-10-15T00:00:00 GIT_COMMITTER_DATE=2026-10-15T00:00:00
export DEVBRAIN_QUEUE_DIR="$Q"
FAILS=0
red() { echo "RED: $1"; FAILS=$((FAILS+1)); }
good() { echo "ok: $1"; }
plan() { printf -- '---\nrepo: demo\nstatus: approved\n---\n\nBody.\n' > "$1"; }
state() { awk '/^status: /{print $2; exit}' "$1"; }
source "$DIR/lib/queue.sh"; fmode() { file_mode "$1"; }

for n in 10-demo--x.plan.md "a b.plan.md" 10-demo--x.md .hidden.plan.md x..plan.md sub/x.plan.md; do plan "$Q/$n"; done
plan "$O/c.plan.md"; chmod 0640 "$O/c.plan.md"
ln -s "$O/c.plan.md" "$Q/l.plan.md"          # symlink from the queue to the canary
ln -s "$O/nothing.plan.md" "$Q/broken.plan.md"   # broken symlink
git -C "$Q" init -q && git -C "$Q" add -A && git -C "$Q" commit -qm init
commits() { git -C "$Q" rev-list --count HEAD; }
snap() { printf '%s|%s|%s|%s|%s\n' "$(ls "$O")" "$(fmode "$O/c.plan.md")" "$(cksum < "$O/c.plan.md")" "$(readlink "$Q/l.plan.md")" "$(commits)"; }
S11="$(snap)"; N0="$(commits)"

# ---- 11. a valid name that only exists outside the queue ---------------------------------------
out="$("$BIN" pause c.plan.md "valid reason" 2>&1)"; rc=$?
[ $rc -eq 4 ] && [ "$(snap)" = "$S11" ] && good "11 only exists outside: rc 4, canary intact" \
  || red "11 only exists outside: rc=$rc, snapshot=$(snap)"

# ---- 9. a valid name keeps working -------------------------------------------------------------
"$BIN" pause 10-demo--x.plan.md "valid reason" >/dev/null 2>&1; rc=$?; N1="$(commits)"
[ $rc -eq 0 ] && [ "$(state "$Q/10-demo--x.plan.md")" = paused ] && [ "$N1" -eq $((N0+1)) ] \
  && good "9 pause by name: rc 0, paused, +1 commit" || red "9 pause by name: rc=$rc status=$(state "$Q/10-demo--x.plan.md") commits $N0->$N1"
"$BIN" resume 10-demo--x.plan.md >/dev/null 2>&1; rc=$?
[ $rc -eq 0 ] && [ "$(state "$Q/10-demo--x.plan.md")" = approved ] \
  && good "9 resume by name restores the previous status" || red "9 resume: rc=$rc status=$(state "$Q/10-demo--x.plan.md")"

S0="$(snap)"

# ---- 10. refusals (the snapshot is taken right before: 11 and 9 do not touch the canary) -------
bad=0
for verb in pause resume; do
  for arg in "../outside/c.plan.md" "$O/c.plan.md" "a b.plan.md" "$(printf 'a\nb.plan.md')" 10-demo--x.md \
             d.plan.md l.plan.md broken.plan.md sub/x.plan.md .hidden.plan.md x..plan.md ./10-demo--x.plan.md \
             -x.plan.md "" "10-demo--x.plan.md/"; do
    out="$("$BIN" "$verb" "$arg" "valid reason" 2>&1)"; rc=$?
    base="$(basename -- "$arg")"
    if [ $rc -ne 2 ]; then
      bad=1; echo "  [$verb] [$arg]: rc=$rc (expected 2)"
    elif [[ "$out" == *"$TMP"* || "$out" == *"$TMP_REAL"* ]]; then
      bad=1; echo "  [$verb] [$arg]: the output carries the temporary path: $out"
    elif [[ "$out" != *"$verb"* || ( -n "$base" && "$out" != *"$base"* ) ]]; then
      bad=1; echo "  [$verb] [$arg]: the message does not name the verb and the basename: $out"
    fi
  done
done
[ "$(snap)" = "$S0" ] || { bad=1; echo "  the canary or the queue changed: $(snap) vs $S0"; }
[ $bad -eq 0 ] && good "10 refusals with rc 2, canary intact" || red "10 refusals"

# pause needs a reason (queue contract): no reason -> rc 2, status untouched
before="$(state "$Q/10-demo--x.plan.md")"
"$BIN" pause 10-demo--x.plan.md >/dev/null 2>&1; rc=$?
[ $rc -eq 2 ] && [ "$(state "$Q/10-demo--x.plan.md")" = "$before" ] \
  && good "pause without a reason: rc 2, status untouched" || red "pause without a reason: rc=$rc"

[ $FAILS -eq 0 ] && { echo "PASS: tests/test-devbrain-queue-entradas.sh"; exit 0; }
echo "FAIL: $FAILS case(s) red"; exit 1

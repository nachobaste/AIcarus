#!/bin/bash
# tests/test-devbrain-blocked-static.sh — static checks that bin/devbrain's execute
# mode is wired for 'blocked'. `claude` is invoked bare inside bin/devbrain,
# with no override variable, and adding one is out of this plan's scope — the same
# call this session made for devbrain-wiki-lint in an earlier change. So these are static/
# structural checks, matching that precedent; the pure detector this wiring calls
# (queue_blocked_command) is exercised live in tests/test-queue-blocked.sh, and the
# consumer side (devbrain-night deciding status: blocked) is exercised live in
# tests/test-night.sh.
[ -z "${OPENCLAW_CLI+x}" ] && [ "${OPENCLAW_SHELL-}" != exec ] || { echo "FAIL: these tests do not run under OpenClaw" >&2; exit 1; }
set -uo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
DB="$DIR/bin/devbrain"

fail() { echo "FAIL: $1"; exit 1; }

grep -q 'blocked-by.txt' "$DB" || fail "bin/devbrain never mentions blocked-by.txt"
echo "OK: bin/devbrain references blocked-by.txt"

# The session must be TOLD to write it — without an instruction in the prompt, no
# session will ever produce this file, and the whole mechanism is dead on arrival.
grep -q 'blocked-by.txt' "$DB" && grep -q '.devbrain/blocked-by.txt' "$DB" \
  || fail "no instruction in the execute prompt tells the session to write the file"
echo "OK: the execute prompt instructs the session to write blocked-by.txt"

# Stale state from an earlier, unrelated attempt must be cleared before the NEW
# session runs, or a leftover file would falsely block a run that never asked for
# anything new.
grep -q 'rm -f \.devbrain/blocked-by\.txt' "$DB" \
  || fail "stale blocked-by.txt is never cleared before a fresh execute run"
echo "OK: stale blocked-by.txt is cleared before each execute run"

# The detection must happen via the SHARED function, not a second hand-rolled read
# of the file — otherwise this and devbrain-night could disagree about what counts
# as blocked (an empty file, for instance).
grep -q 'queue_blocked_command "\$DIR"' "$DB" \
  || fail "bin/devbrain does not call the shared queue_blocked_command detector"
echo "OK: bin/devbrain uses the shared detector, not its own file read"

# A blocked session commits its work locally BEFORE the blocked exit (the work used to be lost
# as loose files in the checkout), and the blocked path reaches no PR and no review. The only
# push on that path is the one inside review_and_push (the secret review and the push, together,
# defined before the blocked path). Anchors are the statements, not comments that mention them:
# an earlier version of this check anchored on a comment and failed while the code was right.
COMMIT_LINE=$(grep -n 'git commit -q -m "devbrain: task changes"' "$DB" | head -1 | cut -d: -f1)
BLOCKED_LINE=$(grep -n 'BLOCKED_CMD="\$(queue_blocked_command' "$DB" | head -1 | cut -d: -f1)
PUSH_LINE=$(grep -nE '^[[:space:]]*(if |elif |while |! )*review_and_push([[:space:]]|$)' "$DB" | head -1 | cut -d: -f1)
PR_LINE=$(grep -n 'gh pr create' "$DB" | head -1 | cut -d: -f1)
for pair in "COMMIT_LINE:$COMMIT_LINE" "BLOCKED_LINE:$BLOCKED_LINE" \
            "PUSH_LINE:$PUSH_LINE" "PR_LINE:$PR_LINE"; do
  [ -n "${pair#*:}" ] || fail "could not locate ${pair%%:*} in bin/devbrain"
done
[ "$COMMIT_LINE" -lt "$BLOCKED_LINE" ] \
  || fail "the local commit happens AFTER the blocked exit — a blocked session loses its work"
echo "OK: a blocked session commits its work locally before exiting"
[ "$BLOCKED_LINE" -lt "$PUSH_LINE" ] && [ "$PUSH_LINE" -lt "$PR_LINE" ] \
  || fail "the order commit < blocked check < push < PR is broken (blocked $BLOCKED_LINE, push call $PUSH_LINE, PR $PR_LINE)"
echo "OK: the blocked check runs before the push call, and the push call before the PR step"
EXIT9_LINE=$(grep -nE '^[[:space:]]*exit 9[[:space:]]*$' "$DB" | head -1 | cut -d: -f1)
[ -n "$EXIT9_LINE" ] || fail "could not locate the blocked exit"
SEGMENT="$(sed -n "${COMMIT_LINE},${EXIT9_LINE}p" "$DB")"
printf '%s' "$SEGMENT" | grep -qE 'gh pr create' && fail "the blocked path opens a PR; blocked work gets no PR"
printf '%s' "$SEGMENT" | grep -qE 'git push' && fail "the blocked path has a bare git push: it must go through review_and_push"
CALLS="$(printf '%s\n' "$SEGMENT" | grep -cE '^[[:space:]]*(if |elif |while |! )*review_and_push([[:space:]]|$)' || true)"
[ "$CALLS" = 1 ] || fail "the blocked path must call review_and_push exactly once, it calls it $CALLS times"
echo "OK: the blocked path has one review_and_push call, no bare git push and no PR"

# A distinct exit code, so devbrain-night's caller can tell 'blocked' apart from an
# ordinary failure without parsing free-text output.
grep -q 'exit 9' "$DB" || fail "no distinct exit code for the blocked path"
echo "OK: the blocked path exits with its own distinct code"

echo "PASS: devbrain-blocked-static"

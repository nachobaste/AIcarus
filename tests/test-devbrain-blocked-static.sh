#!/bin/bash
# tests/test-devbrain-blocked-static.sh — static checks that bin/devbrain's execute
# mode is wired for 'blocked' (plan 290). `claude` is invoked bare inside bin/devbrain,
# with no override variable, and adding one is out of this plan's scope — the same
# call this session made for devbrain-wiki-lint in plan 260. So these are static/
# structural checks, matching that precedent; the pure detector this wiring calls
# (queue_blocked_command) is exercised live in tests/test-queue-blocked.sh, and the
# consumer side (devbrain-night deciding status: blocked) is exercised live in
# tests/test-night.sh.
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

# A blocked session must exit BEFORE the commit-leftovers/PR/review flow — never
# push, never open a PR, for work that stopped on a missing permission.
BLOCKED_LINE=$(grep -n 'BLOCKED_CMD="\$(queue_blocked_command' "$DB" | head -1 | cut -d: -f1)
COMMIT_LEFTOVERS_LINE=$(grep -n 'commit any leftovers, push, open PR' "$DB" | head -1 | cut -d: -f1)
[ -n "$BLOCKED_LINE" ] && [ -n "$COMMIT_LEFTOVERS_LINE" ] \
  || fail "could not locate both the blocked check and the commit-leftovers step"
[ "$BLOCKED_LINE" -lt "$COMMIT_LEFTOVERS_LINE" ] \
  || fail "the blocked check happens AFTER the PR flow starts — too late to prevent it"
echo "OK: the blocked check runs before any commit/push/PR/review step"

# A distinct exit code, so devbrain-night's caller can tell 'blocked' apart from an
# ordinary failure without parsing free-text output.
grep -q 'exit 9' "$DB" || fail "no distinct exit code for the blocked path"
echo "OK: the blocked path exits with its own distinct code"

echo "PASS: devbrain-blocked-static"

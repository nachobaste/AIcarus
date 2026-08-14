#!/bin/bash
# tests/test-devbrain-base-comparison.sh — devbrain must compare against origin, not the
# local base branch.
#
# Lived failure: a run produced no commits of its own, but the "no commits produced"
# guard passed anyway because the LOCAL main was 3 commits behind origin/main — so
# `main..HEAD` listed three already-merged commits. An empty branch was pushed and the
# adversarial reviewer rejected code that had already been merged days earlier.
#
# The branch-creation step was fixed to branch off origin/$DEFAULT_BRANCH. The
# "no commits produced" guard and the reviewer's diff were not, and both need the
# same fix — this suite is what caught that the fix was incomplete.
#
# Part 1 builds the exact repo state and proves the two comparisons disagree — without that,
# the static assertions in part 2 are just string matching against a rule nobody verified.
set -uo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
DB="$DIR/bin/devbrain"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1"; exit 1; }

# ---- part 1: the failure mode is real --------------------------------------
git init -q --bare "$TMP/origin.git"
git clone -q "$TMP/origin.git" "$TMP/work" 2>/dev/null
cd "$TMP/work"
git config user.email t@t.t; git config user.name t
echo one > a.txt; git add a.txt; git commit -qm one
git push -q origin HEAD:main 2>/dev/null
git branch -q -M main 2>/dev/null || true
git branch --set-upstream-to=origin/main main >/dev/null 2>&1 || true

# Someone else merges three commits to origin while this clone sits still.
git clone -q "$TMP/origin.git" "$TMP/other" 2>/dev/null
cd "$TMP/other"; git config user.email t@t.t; git config user.name t
for i in 1 2 3; do echo "m$i" > "m$i.txt"; git add "m$i.txt"; git commit -qm "merged $i"; done
git push -q origin HEAD:main

# Back in the stale clone: fetch (so origin/main is current) but never move local main.
cd "$TMP/work"
git fetch -q origin main
LOCAL_BEHIND=$(git rev-list --count main..origin/main)
[ "$LOCAL_BEHIND" -eq 3 ] || fail "fixture wrong: local main should be 3 behind, is $LOCAL_BEHIND"

# A session branches off origin/main (as :165 already does) and produces NOTHING.
git checkout -q -b devbrain/empty origin/main

BUGGY=$(git log main..HEAD --oneline | wc -l | tr -d ' ')
CORRECT=$(git log origin/main..HEAD --oneline | wc -l | tr -d ' ')

[ "$CORRECT" -eq 0 ] || fail "origin/main..HEAD should be empty for a branch with no commits, got $CORRECT"
[ "$BUGGY" -eq 3 ] || fail "the fixture does not reproduce the bug: main..HEAD gave $BUGGY, expected 3"
echo "OK: reproduced — local base reports 3 commits where origin reports 0 (an empty branch looks productive)"

# And the guard must still fire correctly when there IS real work.
echo real > real.txt; git add real.txt; git commit -qm "real work"
REAL=$(git log origin/main..HEAD --oneline | wc -l | tr -d ' ')
[ "$REAL" -eq 1 ] || fail "a branch with one real commit should show 1 against origin, got $REAL"
echo "OK: a branch with real work still reports it against origin"

# ---- part 2: devbrain uses the correct ref ---------------------------------
cd "$DIR"

grep -q 'git log "origin/\$DEFAULT_BRANCH"\.\.HEAD' "$DB" \
  || fail "the 'no commits produced' guard still compares against the local base branch"
echo "OK: the no-commits guard compares against origin"

grep -q 'git diff "origin/\$DEFAULT_BRANCH"\.\.HEAD' "$DB" \
  || fail "the reviewer's diff still compares against the local base branch"
echo "OK: the reviewer's diff compares against origin"

# The PR base is a branch NAME for gh, not a remote-tracking ref. Fixing it would break
# `gh pr create`, so it must stay bare — this test exists to stop a well-meaning fix.
grep -q -- '--base "origin/\$DEFAULT_BRANCH"' "$DB" \
  && fail "gh pr create --base must be a branch name, not a remote ref"
grep -q -- '--base "\$DEFAULT_BRANCH"' "$DB" \
  || fail "gh pr create --base is neither the plain branch name nor the remote ref"
echo "OK: gh pr create --base stays a plain branch name"

# No other comparison against the bare local base slipped back in.
LEFTOVER=$(grep -nE 'git (log|diff) "\$DEFAULT_BRANCH"\.\.' "$DB" || true)
[ -z "$LEFTOVER" ] || fail "still comparing against the local base branch: $LEFTOVER"
echo "OK: no comparison against the bare local base remains"

echo "PASS: devbrain-base-comparison"

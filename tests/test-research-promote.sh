#!/bin/bash
# tests/test-research-promote.sh — promotion: raw backlog -> 2-3 proposals the owner can decide.
#
# Two jobs, both here because both are where promotion can quietly go wrong:
#
#   select   picks which findings get the expensive deep pass. The criteria must live in
#            code, not in a prompt, or nobody can audit or change why something was chosen.
#            It must also be deterministic: same backlog, same picks.
#   validate enforces the owner's stated definition of "done" (2026-08-08): at least two real
#            options with pros/cons. A second option that touches the same files as the
#            first is filler dressed as a choice, and it is the easiest thing for a model
#            to produce when asked for "two options".
set -uo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$DIR/lib/research_promote.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1"; exit 1; }

mkdir -p "$TMP/repo/src"
printf 'a\nb\nc\nd\ne\n' > "$TMP/repo/src/one.js"
printf 'a\nb\nc\n'       > "$TMP/repo/src/two.js"
printf 'a\nb\nc\n'       > "$TMP/repo/src/three.js"

sel() { RESEARCH_PROMOTE_MAX="${MAXP:-3}" python3 "$BIN" select; }
val() { RESEARCH_REPO_ROOT="$TMP/repo" python3 "$BIN" validate; }

finding() { # $1=title $2=evidence $3=why $4=size
  printf '### %s\n- repo: demo\n- evidence: %s\n- why: %s\n- size: %s\n\n' "$1" "$2" "$3" "$4"
}

# ---- SELECT ----------------------------------------------------------------

# 1. it picks a few, not everything
{ for i in 1 2 3 4 5 6; do finding "Finding $i" "src/one.js:1" "ordinary thing" "1 night"; done; } \
  | sel > "$TMP/out" 2> "$TMP/err"
N=$(grep -c '^### ' "$TMP/out")
[ "$N" -eq 3 ] || fail "6 findings should promote 3, promoted $N"
echo "OK: six findings promote three, not six"

# 2. deterministic — the same backlog must not shuffle between runs
{ for i in 1 2 3 4 5 6; do finding "Finding $i" "src/one.js:1" "ordinary thing" "1 night"; done; } \
  | sel > "$TMP/out2" 2>/dev/null
diff -q "$TMP/out" "$TMP/out2" >/dev/null || fail "selection is not deterministic between runs"
echo "OK: selection is deterministic"

# 3. a finding that declares it blocks other work outranks a plain one
{ finding "Plain" "src/one.js:1" "would be nice to fix" "1 night"
  finding "Blocker" "src/two.js:1" "blocks the other repos until this is resolved" "3 nights"; } \
  | MAXP=1 sel > "$TMP/out" 2>/dev/null
grep -q "Blocker" "$TMP/out" || fail "a declared blocker did not win the top slot"
grep -q "Plain" "$TMP/out" && fail "the plain finding was promoted over the blocker"
echo "OK: a finding that declares it blocks others ranks first"

# 4. more distinct files cited beats fewer, all else equal
{ finding "One citation" "src/one.js:1" "ordinary thing" "1 night"
  finding "Three citations" "src/one.js:1, src/two.js:1, src/three.js:1" "ordinary thing" "1 night"; } \
  | MAXP=1 sel > "$TMP/out" 2>/dev/null
grep -q "Three citations" "$TMP/out" || fail "harder evidence did not outrank thinner evidence"
echo "OK: more distinct files cited outranks fewer"

# 5. smaller effort breaks the tie
{ finding "Big"   "src/one.js:1" "ordinary thing" "5 nights"
  finding "Small"  "src/two.js:1" "ordinary thing" "1 night"; } \
  | MAXP=1 sel > "$TMP/out" 2>/dev/null
grep -q "Small" "$TMP/out" || fail "the smaller task did not win the tie"
echo "OK: smaller effort wins the tie"

# 6. something already promoted is not promoted again
# Otherwise the same proposal reaches the owner every single night until the owner acts on it.
{ finding "Already promoted" "src/one.js:1" "ordinary thing" "1 night"
  printf '## Proposals — 2026-08-08\n\n### Old proposal\n- source: Already promoted\n\n'; } \
  | MAXP=3 sel > "$TMP/out" 2> "$TMP/err"
grep -q "Already promoted" "$TMP/out" && fail "an already-promoted finding was promoted again"
grep -q "nothing to promote" "$TMP/err" || fail "should say there is nothing left to promote"
echo "OK: an already-promoted finding is not promoted twice"

# 7. an empty backlog invents nothing
printf '' | sel > "$TMP/out" 2> "$TMP/err"; RC=$?
[ "$RC" -eq 0 ] || fail "empty backlog should exit 0, got $RC"
[ ! -s "$TMP/out" ] || fail "empty backlog produced output: $(cat "$TMP/out")"
grep -q "nothing to promote" "$TMP/err" || fail "empty backlog should say so"
echo "OK: an empty backlog promotes nothing and invents nothing"

# ---- VALIDATE --------------------------------------------------------------

proposal() { # $1=title $2=filesA $3=filesB(or empty)
  printf '### %s\n- source: H\n- repo: demo\n- effort: 1 night\n- risks: some\n- verify: run the tests\n\n' "$1"
  printf '#### Option A — one\n- files: %s\n- pros: fast\n- cons: partial\n\n' "$2"
  [ -n "$3" ] && printf '#### Option B — another\n- files: %s\n- pros: complete\n- cons: expensive\n\n' "$3"
}

# 8. the happy path first, or every rejection below proves nothing
proposal "Good" "src/one.js" "src/two.js" | val > "$TMP/out" 2> "$TMP/err"; RC=$?
[ "$RC" -eq 0 ] || fail "a valid proposal should exit 0, got $RC ($(cat "$TMP/err"))"
grep -q "Good" "$TMP/out" || fail "a valid proposal was rejected: $(cat "$TMP/err")"
echo "OK: a proposal with two options touching different files is kept"

# 9. one option is not a choice
proposal "No options" "src/one.js" "" | val > "$TMP/out" 2> "$TMP/err"
grep -q "No options" "$TMP/out" && fail "a proposal with a single option was kept"
grep -q "insufficient-options" "$TMP/err" || fail "did not report the reason"
echo "OK: a proposal with one option is rejected"

# 10. two options over the same files are one option written twice
proposal "Filler" "src/one.js" "src/one.js" | val > "$TMP/out" 2> "$TMP/err"
grep -q "Filler" "$TMP/out" && fail "filler second option was accepted"
grep -q "identical-options" "$TMP/err" || fail "did not report identical options"
echo "OK: two options touching the same files are rejected as filler"

# 11. a proposal may name a file it would CREATE
# Findings cite evidence, so their paths must exist. Proposals name what they would
# touch, and creating a file is normal work — the finding "there is no package.json"
# can only be answered by a proposal that names one. Applying the finding rule here
# rejected 3 of 3 real proposals on 2026-08-08.
proposal "Creates a file" "src/one.js" "package.json" | val > "$TMP/out" 2> "$TMP/err"
grep -q "Creates a file" "$TMP/out" || fail "a proposal creating a new file was rejected: $(cat "$TMP/err")"
grep -q "package.json (new)" "$TMP/out" || fail "a file that does not exist yet is not marked as new"
echo "OK: a proposal may name a file it would create, marked (new)"

# ...but it must be anchored in the real repo somewhere
# A proposal where NOTHING resolves is either about another repo or invented whole.
proposal "No anchor" "does-not-exist-a.js" "does-not-exist-b.js" | val > "$TMP/out" 2> "$TMP/err"
grep -q "No anchor" "$TMP/out" && fail "a proposal with no real file was kept"
grep -q "no-anchor" "$TMP/err" || fail "did not report the reason"
echo "OK: a proposal where no named file exists is rejected as unanchored"

# 12. the system owns the attribution, not the model
# A model that misattributes a proposal marks the wrong finding as promoted, and the
# real one comes back every night. It is also the guard against re-promotion, so it
# cannot depend on the model remembering to write a line.
{ proposal "With source" "src/one.js" "src/two.js"
  printf -- '- source: WHAT THE MODEL MADE UP\n'; } \
  | RESEARCH_REPO_ROOT="$TMP/repo" python3 "$BIN" validate --source "Real finding" > "$TMP/out" 2>/dev/null
grep -q '^- source: Real finding$' "$TMP/out" || fail "the authoritative source was not written"
grep -q "WHAT THE MODEL MADE UP" "$TMP/out" && fail "the model's own source line survived"
[ "$(grep -c '^- source:' "$TMP/out")" -eq 1 ] || fail "more than one source line"
echo "OK: validate writes the authoritative source and drops the model's"

# 13. the anchor must be INSIDE the repo, not just somewhere on the machine
# An absolute path defeats os.path.join, so "/etc/hosts" resolved and counted as
# anchoring. Cross-repo options are legitimate and stay allowed — a real proposal on
# 2026-08-08 had one — but at least one file must be in the repo the finding is about,
# or the check is not checking anything.
proposal "Only outside" "/etc/hosts" "/usr/bin/env" | val > "$TMP/out" 2> "$TMP/err"
grep -q "Only outside" "$TMP/out" && fail "a proposal anchored only outside the repo was kept"
grep -q "no-anchor" "$TMP/err" || fail "did not report it as unanchored"
echo "OK: files outside the repo do not count as an anchor"

proposal "Mixed" "src/one.js" "/etc/hosts" | val > "$TMP/out" 2> "$TMP/err"
grep -q "Mixed" "$TMP/out" || fail "a cross-repo option was rejected even with a real in-repo anchor"
echo "OK: a cross-repo option is fine when something in the repo anchors it"

# ---- DIGEST -----------------------------------------------------------------
# What reaches the owner's phone at 6am: numbered, terse, and only what has not
# already been decided on. The number is load-bearing — plan 250 lets the owner
# reply "dale 2" from Telegram, so it must stay stable and exact, never reworded.

dig() { python3 "$BIN" digest; }

backlog_with_proposal() { # $1=finding_title $2=why $3=proposal_title $4=extra(optional, after the proposal)
  {
    printf '## 2026-08-08 — demo\n\n'
    finding "$1" "src/one.js:1" "$2" "1 night"
    printf '## Proposals — 2026-08-08\n\n'
    printf '### %s\n- source: %s\n- repo: demo\n- effort: 2 nights\n- risks: some\n- verify: tests\n\n' "$3" "$1"
    printf '#### Option A\n- files: src/one.js\n\n#### Option B\n- files: src/two.js\n\n'
    [ -n "${4:-}" ] && printf '%s\n' "$4"
  }
}

# 14. a pending proposal is numbered 1, with title / why / effort — three lines
backlog_with_proposal "Finding A" "this blocks the other repos" "Fix the blocker" \
  | dig > "$TMP/out" 2>"$TMP/err"
grep -q "^1\. Fix the blocker$" "$TMP/out" || fail "the proposal was not numbered 1 with its exact title: $(cat "$TMP/out")"
grep -q "this blocks the other repos" "$TMP/out" || fail "the source finding's why line is missing"
grep -q "2 nights" "$TMP/out" || fail "the effort estimate is missing"
[ "$(sed -n '1,3p' "$TMP/out" | wc -l | tr -d ' ')" = "3" ] || fail "a proposal must be exactly 3 lines"
echo "OK: a pending proposal is numbered 1 in exactly 3 lines"

# 15. an empty backlog, or one with no promoted proposals, produces nothing
printf '' | dig > "$TMP/out" 2>/dev/null
[ ! -s "$TMP/out" ] || fail "an empty backlog produced digest output"
finding "Just a finding" "src/one.js:1" "something" "1 night" | dig > "$TMP/out" 2>/dev/null
[ ! -s "$TMP/out" ] || fail "a backlog with findings but no proposals produced digest output"
echo "OK: nothing to decide means nothing is printed, never invented"

# 16. a proposal already decided (by devbrain-day / Telegram, plan 240/250) is not repeated
# The decision line format is the forward-compatible contract for those plans, not built yet.
backlog_with_proposal "Finding B" "matters" "Already decided" "- decision: approved" \
  | dig > "$TMP/out" 2>/dev/null
grep -q "Already decided" "$TMP/out" && fail "a decided proposal was shown again"
echo "OK: a proposal marked decided is not shown"

# 17. two pending proposals number 1 and 2, in backlog order — never shuffled
{ backlog_with_proposal "H1" "first" "First proposal"
  backlog_with_proposal "H2" "second" "Second proposal"; } | dig > "$TMP/out" 2>/dev/null
grep -q "^1\. First proposal$" "$TMP/out" || fail "first proposal is not numbered 1"
grep -q "^2\. Second proposal$" "$TMP/out" || fail "second proposal is not numbered 2"
echo "OK: multiple pending proposals number in backlog order"

# 18. missing source (edge case: hand-edited backlog) does not crash, degrades honestly
printf '### Orphaned\n- source: Does Not Exist\n- repo: demo\n- effort: 1 night\n- risks: x\n- verify: y\n\n#### A\n- files: a\n\n#### B\n- files: b\n\n' \
  | dig > "$TMP/out" 2>"$TMP/err"; RC=$?
[ "$RC" -eq 0 ] || fail "a proposal with a dangling source crashed the digest, rc=$RC"
grep -q "Orphaned" "$TMP/out" || fail "a proposal with a dangling source should still show, degraded"
echo "OK: a dangling source degrades honestly instead of crashing"

# 19. the cap is visible, never a silent truncation
{ for i in 1 2 3 4 5 6 7; do backlog_with_proposal "HC$i" "reason $i" "Proposal $i"; done; } \
  | RESEARCH_DIGEST_MAX=3 dig > "$TMP/out" 2>"$TMP/err"
[ "$(grep -c '^[0-9]\+\. ' "$TMP/out")" -eq 3 ] || fail "the cap of 3 was not honoured"
grep -qi "4 m" "$TMP/out" || fail "the digest hides the other 4 pending proposals in silence"
echo "OK: proposals beyond the cap are reported, not hidden"

# ---- AGE (2026-08-12): the "## Proposals — YYYY-MM-DD" heading is a real date,
# already written when a finding is promoted — not a proxy like Bloqueadas' mtime.
# Age must not touch the numbered title line (plan 250's "dale N"), so it is folded
# into the Effort line, which is why every assertion above about "exactly 3 lines"
# and the exact title regex must keep passing unchanged (they do, re-run above).
days_ago() { date -v-"$1"d +%Y-%m-%d 2>/dev/null || date -d "-$1 days" +%Y-%m-%d; }

backlog_with_proposal_dated() { # $1=finding_title $2=why $3=proposal_title $4=date_iso
  {
    printf '## 2026-08-08 — demo\n\n'
    finding "$1" "src/one.js:1" "$2" "1 night"
    printf '## Proposals — %s\n\n' "$4"
    printf '### %s\n- source: %s\n- repo: demo\n- effort: 2 nights\n- risks: some\n- verify: tests\n\n' "$3" "$1"
    printf '#### Option A\n- files: src/one.js\n\n#### Option B\n- files: src/two.js\n\n'
  }
}

# 20. a fresh proposal (promoted yesterday, default threshold 3) shows its age,
# no escalation marker
backlog_with_proposal_dated "HFresh" "something" "Fresh proposal" "$(days_ago 1)" \
  | dig > "$TMP/out" 2>/dev/null
grep -q "^1\. Fresh proposal$" "$TMP/out" || fail "title line changed for a fresh proposal: $(cat "$TMP/out")"
grep -q "waiting 1 day" "$TMP/out" || fail "a fresh proposal should still show its age: $(cat "$TMP/out")"
grep -q "⚠️" "$TMP/out" && fail "a fresh proposal (1 day, threshold 3) must NOT show the stale marker"
echo "OK: a fresh proposal shows its age, no escalation"

# 21. a stale proposal (10 days, past the default 3-day threshold) DOES escalate,
# and the escalation never touches the numbered title line
backlog_with_proposal_dated "HOld" "something" "Old proposal" "$(days_ago 10)" \
  | dig > "$TMP/out" 2>/dev/null
grep -q "^1\. Old proposal$" "$TMP/out" || fail "title line was mangled by the stale marker: $(cat "$TMP/out")"
grep -q "⚠️.*waiting 10 days" "$TMP/out" || fail "a 10-day-old proposal past the threshold must show ⚠️: $(cat "$TMP/out")"
echo "OK: a stale proposal escalates visually without disturbing its numbered title"

# 22. DEVBRAIN_DIGEST_STALE_DAYS is overridable and actually changes the cutoff —
# planting the case that must NOT fire is the only way to trust the case that must
grep -q "⚠️" "$TMP/out" || fail "sanity check failed: previous run should have had ⚠️"
backlog_with_proposal_dated "HOld2" "something" "Old proposal 2" "$(days_ago 10)" \
  | DEVBRAIN_DIGEST_STALE_DAYS=100 dig > "$TMP/out" 2>/dev/null
grep -q "⚠️" "$TMP/out" && fail "raising the threshold to 100 must suppress escalation for a 10-day-old item"
grep -q "waiting 10 days" "$TMP/out" || fail "raising the threshold must not hide the age itself, only the marker"
echo "OK: DEVBRAIN_DIGEST_STALE_DAYS=100 suppresses escalation for the same 10-day-old item"

backlog_with_proposal_dated "HFresh2" "something" "Fresh proposal 2" "$(days_ago 2)" \
  | DEVBRAIN_DIGEST_STALE_DAYS=1 dig > "$TMP/out" 2>/dev/null
grep -q "⚠️" "$TMP/out" || fail "lowering the threshold to 1 must escalate a 2-day-old item"
echo "OK: DEVBRAIN_DIGEST_STALE_DAYS=1 escalates the same 2-day-old item"

# 23. a proposal with no '## Proposals — DATE' heading (hand-edited backlog, same
# case as test 18's Orphaned) shows no age at all rather than guessing one — and
# still keeps the 3-line contract
printf '### No date\n- source: Does Not Exist\n- repo: demo\n- effort: 1 night\n- risks: x\n- verify: y\n\n#### A\n- files: a\n\n#### B\n- files: b\n\n' \
  | dig > "$TMP/out" 2>/dev/null
grep -q "waiting" "$TMP/out" && fail "a proposal with no promotion date should not show a fabricated age"
grep -q "⚠️" "$TMP/out" && fail "a proposal with no promotion date should not escalate"
[ "$(sed -n '1,3p' "$TMP/out" | wc -l | tr -d ' ')" = "3" ] || fail "still must be exactly 3 lines with no date"
echo "OK: a proposal with no promotion date shows no age, no crash, still 3 lines"

# 24. the escalation marker survives the AI-summarizer boundary untouched — proven
# at the integration level in tests/test-devbrain-digest-proposals.sh (the block is
# appended verbatim AFTER the summarizer call, same mechanism as the numbering).

echo "PASS: research-promote"

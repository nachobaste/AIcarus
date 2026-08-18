#!/bin/bash
# tests/test-devbrain-research.sh — the orchestrator around the research session.
#
# Two things here are security properties, not features:
#   1. the session is read-only (no Write, no Edit, no MCP) — the model must not
#      be able to touch a repo it is only supposed to read;
#   2. a repo outside the allowlist is refused BEFORE any model runs, and
#      machine-config is never allowed at all
#      (wiki/lessons/machine-config-nunca-nocturno.md).
#
# The model is stubbed with a fake `claude` that records its arguments, so the
# whole pipeline is exercised without tokens and without depending on what a
# model happens to say today.
set -uo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$DIR/bin/devbrain-research"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1"; exit 1; }

# ---- fixtures ---------------------------------------------------------------
mkdir -p "$TMP/projects/demo/src" "$TMP/wiki/status" "$TMP/wiki/projects"
printf 'a\nb\nc\nd\ne\n' > "$TMP/projects/demo/src/real.js"
git -C "$TMP/projects/demo" init -q 2>/dev/null
printf '# demo — status\n\n- **Last update:** nothing\n' > "$TMP/wiki/status/demo.md"
printf 'demo\n' > "$TMP/allow"

BACKLOG="$TMP/wiki/projects/mejoras-propuestas.md"
ARGS="$TMP/claude-args"

# Fake claude: records argv, prints one real finding and one fabricated one.
cat > "$TMP/fake-claude" <<'FAKE'
#!/bin/bash
printf '%s\n' "$@" > "$CLAUDE_ARGS_FILE"
cat "$CLAUDE_FIXTURE"
FAKE
chmod +x "$TMP/fake-claude"

cat > "$TMP/fixture-mixed" <<'FIX'
Sure, here are the findings I came up with:

### Real debt in the scraper
- repo: demo
- evidence: src/real.js:2
- why: the pattern is duplicated
- size: 1 night

### Invented finding
- repo: demo
- evidence: src/does-not-exist.js:10
- why: sounds plausible
- size: 1 night
FIX

cat > "$TMP/fixture-cross" <<'FIX'
### Real connection between two repos
- repo: demo + other
- evidence: src/real.js:2, lib/other.py:2
- why: one has the data the other is missing
- size: 2 nights
FIX

run() {
  RESEARCH_CLAUDE_BIN="$TMP/fake-claude" \
  CLAUDE_ARGS_FILE="$ARGS" CLAUDE_FIXTURE="${FIXTURE:-$TMP/fixture-mixed}" \
  RESEARCH_PROJECTS_DIR="$TMP/projects" RESEARCH_ALLOWFILE="$TMP/allow" \
  RESEARCH_BACKLOG="$BACKLOG" RESEARCH_WIKI="$TMP/wiki" \
  RESEARCH_LOG="$TMP/log" RESEARCH_STATE_DIR="${STATEDIR:-$TMP/state}" "$BIN" "$@"
}

# ---- 1. a repo outside the allowlist is refused before any model runs -------
rm -f "$ARGS"
run does-not-exist > "$TMP/out" 2>&1; RC=$?
[ "$RC" -eq 3 ] || fail "unlisted repo should exit 3, got $RC ($(cat "$TMP/out"))"
[ ! -f "$ARGS" ] || fail "the model was invoked for a repo outside the allowlist"
echo "OK: a repo outside the allowlist is refused and no model runs"

# ---- 2. machine-config is refused even if someone lists it -----------------
# The allowlist is not the only barrier for this repo, and must not become it.
printf 'demo\nmachine-config\n' > "$TMP/allow"
rm -f "$ARGS"
run machine-config > "$TMP/out" 2>&1; RC=$?
[ "$RC" -ne 0 ] || fail "machine-config must never be researched by this tool"
[ ! -f "$ARGS" ] || fail "the model was invoked against machine-config"
grep -qi "machine-config" "$TMP/out" || fail "the refusal should name the repo"
printf 'demo\n' > "$TMP/allow"
echo "OK: machine-config is refused even when present in the allowlist"

# ---- 3. the session is read-only -------------------------------------------
rm -f "$ARGS"
run demo > "$TMP/out" 2>&1; RC=$?
[ "$RC" -eq 0 ] || fail "valid run should exit 0, got $RC ($(cat "$TMP/out"))"
[ -f "$ARGS" ] || fail "the model was never invoked"
ALLOWED=$(grep -A1 -- '--allowedTools' "$ARGS" | tail -1)
DISALLOWED=$(grep -A1 -- '--disallowedTools' "$ARGS" | tail -1)
case "$ALLOWED" in
  *Write*) fail "Write is allowed in a read-only research session: $ALLOWED" ;;
  *Edit*)  fail "Edit is allowed in a read-only research session: $ALLOWED" ;;
esac
case "$ALLOWED" in *Read*) ;; *) fail "Read missing from allowedTools: $ALLOWED" ;; esac
case "$ALLOWED" in *Grep*) ;; *) fail "Grep missing from allowedTools: $ALLOWED" ;; esac
case "$DISALLOWED" in *'mcp__*'*) ;; *) fail "MCP is not denied: $DISALLOWED" ;; esac
case "$DISALLOWED" in *.ssh*) ;; *) fail "~/.ssh is not denied: $DISALLOWED" ;; esac
echo "OK: the research session is read-only and denies MCP and secrets"

# ---- 4. only the finding that survives the filter reaches the backlog ------
[ -f "$BACKLOG" ] || fail "the backlog file was not created"
grep -q "Real debt in the scraper" "$BACKLOG" || fail "the valid finding was not recorded"
grep -q "Invented finding" "$BACKLOG" && fail "a fabricated finding reached the backlog"
grep -q "src/does-not-exist.js" "$BACKLOG" && fail "a fabricated path reached the backlog"
echo "OK: fabricated findings never reach the backlog"

# ---- 5. a second run does not repeat what is already there -----------------
BEFORE=$(grep -c "Real debt in the scraper" "$BACKLOG")
run demo > "$TMP/out" 2>&1
AFTER=$(grep -c "Real debt in the scraper" "$BACKLOG")
[ "$BEFORE" -eq "$AFTER" ] || fail "a known finding was recorded twice ($BEFORE -> $AFTER)"
echo "OK: re-running does not duplicate known findings"

# ---- 6. appending never destroys what was already written ------------------
printf '\n### Human finding\n- repo: demo\n' >> "$BACKLOG"
FIXTURE="$TMP/fixture-new" && cat > "$TMP/fixture-new" <<'FIX'
### Another real finding
- repo: demo
- evidence: src/real.js:5
- why: something else
- size: 2 nights
FIX
FIXTURE="$TMP/fixture-new" run demo > "$TMP/out" 2>&1
grep -q "Human finding" "$BACKLOG" || fail "an existing hand-written entry was destroyed"
grep -q "Another real finding" "$BACKLOG" || fail "the new finding was not appended"
echo "OK: the backlog is appended to, never overwritten"

# ---- 7. the run is logged, including what was discarded --------------------
grep -q "dropped" "$TMP/log" || fail "the log does not record discarded findings"
echo "OK: the run logs what it discarded"

# ---- 8. when everything is discarded, the raw output is kept ---------------
# Lived regression (2026-08-08): the first real run against repoa threw
# away all 5 findings and there was no way to see why, because the raw output
# was deleted on exit. "Discarded everything" is exactly when a human needs the
# evidence — a filter you cannot inspect is a filter you cannot trust.
cat > "$TMP/fixture-allbad" <<'FIX'
### All invented
- repo: demo
- evidence: src/ghost.js:1
- why: nothing real
- size: 1 night
FIX
rm -f "$TMP"/raw-*
FIXTURE="$TMP/fixture-allbad" run demo > "$TMP/out" 2>&1
RAWKEPT=$(grep -o '/[^ ]*raw[^ ]*' "$TMP/log" | tail -1)
[ -n "$RAWKEPT" ] || fail "nothing was discarded-and-kept: the log never names a raw file"
[ -f "$RAWKEPT" ] || fail "the log names a raw file that does not exist: $RAWKEPT"
grep -q "src/ghost.js" "$RAWKEPT" || fail "the kept raw output does not hold what was rejected"
grep -q "All invented" "$BACKLOG" && fail "a rejected finding still reached the backlog"
echo "OK: when everything is discarded the raw output is kept for inspection"

# ---- the attention budget: 50/30/20 by rotation ----------------------------
# the owner fixed this split in the 2026-08-08 interview. It is asserted exactly, not
# statistically, because the cycle is deterministic on purpose — a random draw
# would need a tolerance, and a tolerance is where a broken selector hides.
STATEDIR="$TMP/state-budget"; rm -rf "$STATEDIR"
: > "$TMP/buckets"
for _ in $(seq 10); do run --next-bucket >> "$TMP/buckets" 2>/dev/null; done
[ "$(grep -c '^internas$'   "$TMP/buckets")" -eq 5 ] || fail "expected 5 internas, got $(grep -c '^internas$' "$TMP/buckets")"
[ "$(grep -c '^conexiones$' "$TMP/buckets")" -eq 3 ] || fail "expected 3 conexiones, got $(grep -c '^conexiones$' "$TMP/buckets")"
[ "$(grep -c '^externo$'    "$TMP/buckets")" -eq 2 ] || fail "expected 2 externo, got $(grep -c '^externo$' "$TMP/buckets")"
echo "OK: 10 runs of the selector give exactly 50/30/20"

# It must ADVANCE. A selector stuck on its first value would also produce a
# plausible-looking file if the loop above only ever read slot 0.
[ "$(sort -u "$TMP/buckets" | wc -l | tr -d ' ')" -eq 3 ] || fail "the selector never left one bucket"
echo "OK: the selector advances through all three buckets"

# Corrupt state must not be what stops a night.
mkdir -p "$STATEDIR"; printf 'garbage' > "$STATEDIR/research-budget"
run --next-bucket > "$TMP/b2" 2>/dev/null || fail "corrupt budget state broke the selector"
grep -qE '^(internas|conexiones|externo)$' "$TMP/b2" || fail "corrupt state produced a non-bucket"
echo "OK: corrupt budget state falls back instead of failing"

# ---- the external bucket is routed but refuses ----------------------------
# It needs network tools that no unattended session has. Routing it without
# running it is the point: the decision stays the owner's, in its own discussion.
STATEDIR="$TMP/state-ext"
rm -f "$ARGS"
run --scope externo > "$TMP/out" 2>&1; RC=$?
[ "$RC" -eq 0 ] || fail "externo should exit 0, got $RC"
grep -qi "pending.*decision" "$TMP/out" || fail "externo did not say why it refused"
[ ! -f "$ARGS" ] || fail "externo invoked a model"
echo "OK: --scope externo refuses, explains itself, and runs no model"

grep -qE 'WebSearch|WebFetch' "$BIN" &&   grep -vqE '^\s*#' <(grep -E 'WebSearch|WebFetch' "$BIN") &&   fail "a network tool appears outside a comment"
echo "OK: no network tool anywhere in the script"

# ---- scope validation ------------------------------------------------------
run --scope invalid > "$TMP/out" 2>&1; RC=$?
[ "$RC" -eq 2 ] || fail "an invalid scope should exit 2, got $RC"
echo "OK: an invalid scope is refused"

# ---- conexiones needs at least two repos ----------------------------------
STATEDIR="$TMP/state-one"; printf 'demo
' > "$TMP/allow"
rm -f "$ARGS"
run --scope conexiones > "$TMP/out" 2>&1; RC=$?
[ "$RC" -eq 3 ] || fail "conexiones with one repo should exit 3, got $RC"
[ ! -f "$ARGS" ] || fail "conexiones ran a model with a single repo"
echo "OK: conexiones refuses when the allowlist has fewer than two repos"

# ---- conexiones rotates instead of always reading the same repos ----------
mkdir -p "$TMP/projects/other/lib"
printf 'x
y
z
' > "$TMP/projects/other/lib/other.py"
printf 'a
b
c
' > "$TMP/projects/third.txt"   # not a repo, must be ignored
mkdir -p "$TMP/projects/third/src"; printf 'q
w
' > "$TMP/projects/third/src/x.js"
printf 'demo
other
third
' > "$TMP/allow"
STATEDIR="$TMP/state-rot"; rm -rf "$STATEDIR"
RESEARCH_MAX_REPOS=2 FIXTURE="$TMP/fixture-cross" run --scope conexiones >/dev/null 2>&1
FIRST="$(head -1 "$STATEDIR/research-rotation" 2>/dev/null)"
RESEARCH_MAX_REPOS=2 FIXTURE="$TMP/fixture-cross" run --scope conexiones >/dev/null 2>&1
SECOND="$(head -1 "$STATEDIR/research-rotation" 2>/dev/null)"
[ -n "$FIRST" ] && [ "$FIRST" != "$SECOND" ] || fail "the repo rotation did not advance ($FIRST -> $SECOND)"
echo "OK: connection nights rotate which repos they read"

# ---- promotion: raw backlog -> proposals the owner can decide -------------------
# The backlog is raw material. What reaches the owner is a handful of deep proposals,
# and the section they live in must never eat the findings underneath it.
cat > "$TMP/fixture-promote" <<'FIX'
### Proposal about the scraper
- source: Real debt in the scraper
- repo: demo
- effort: 1 night
- risks: nothing serious
- verify: run the tests

#### Option A — point fix
- files: src/real.js
- pros: cheap
- cons: does not solve the whole class

#### Option B — extract the pattern
- files: src/other.js
- pros: closes the whole class
- cons: more expensive
FIX
printf 'x\ny\n' > "$TMP/projects/demo/src/other.js"

BEFORE_RAW=$(grep -c '^### ' "$BACKLOG")
FIXTURE="$TMP/fixture-promote" run --promote demo > "$TMP/out" 2>&1; RC=$?
[ "$RC" -eq 0 ] || fail "promote should exit 0, got $RC ($(cat "$TMP/out"))"
grep -q '^## Proposals' "$BACKLOG" || fail "no proposals section was written"
grep -q "Proposal about the scraper" "$BACKLOG" || fail "the proposal was not recorded"
echo "OK: promotion writes a proposals section"

# the raw findings must survive underneath it
AFTER_RAW=$(grep -c '^### ' "$BACKLOG")
[ "$AFTER_RAW" -gt "$BEFORE_RAW" ] || fail "promotion destroyed raw findings ($BEFORE_RAW -> $AFTER_RAW)"
grep -q "Real debt in the scraper" "$BACKLOG" || fail "the original finding was removed"
echo "OK: the raw backlog survives promotion"

# the deep pass is read-only too — it reads more, so it must not gain a pen
ALLOWED=$(grep -A1 -- '--allowedTools' "$ARGS" | tail -1)
case "$ALLOWED" in
  *Write*) fail "the promotion pass may write: $ALLOWED" ;;
  *Edit*)  fail "the promotion pass may edit: $ALLOWED" ;;
esac
echo "OK: the promotion pass is read-only"

# a filler second option must not reach the owner
cat > "$TMP/fixture-filler" <<'FIX'
### Filler proposal
- source: Another real finding
- repo: demo
- effort: 1 night
- risks: none
- verify: nothing

#### Option A — one
- files: src/real.js
- pros: a
- cons: b

#### Option B — another
- files: src/real.js
- pros: c
- cons: d
FIX
FIXTURE="$TMP/fixture-filler" run --promote demo > "$TMP/out" 2>&1
grep -q "Filler proposal" "$BACKLOG" && fail "a proposal with two identical options was recorded"
echo "OK: a filler second option never reaches the backlog"

# the system, not the model, owns the attribution — and it is what stops a proposal
# from reaching the owner again every night until the owner acts on it
grep -q "^- source: " "$BACKLOG" || fail "no source line was written; re-promotion is unguarded"
SOURCE=$(grep -m1 "^- source: " "$BACKLOG" | sed 's/^- source: //')
grep -q "^### $SOURCE$" "$BACKLOG" || fail "source '$SOURCE' does not name a finding in the backlog"
echo "OK: the system writes source, pointing at a real finding"

# and the promoted finding must not come back on the next cycle
BEFORE_PROP=$(grep -c '^## Proposals' "$BACKLOG")
python3 "$DIR/lib/research_promote.py" select < "$BACKLOG" 2>/dev/null > "$TMP/resel"
grep -q "^### $SOURCE$" "$TMP/resel" && fail "an already-promoted finding was selected again"
echo "OK: an already-promoted finding is not selected on the next cycle"

# when a deep pass yields nothing valid, keep its raw output too
# Same lesson as the survey path (2026-08-08): "discarded everything" is exactly when a
# human needs the evidence to tell a fabricating model from a wrong validator. The
# promotion path was written without it and cost the same diagnosis twice in one day.
cat > "$TMP/fixture-nada" <<'FIX'
### Unanchored proposal
- repo: demo
- effort: 1 night
- risks: x
- verify: y

#### Option A — one
- files: does-not-exist-a.js
- pros: a
- cons: b

#### Option B — another
- files: does-not-exist-b.js
- pros: c
- cons: d
FIX
rm -f "$TMP"/raw-promote-* 2>/dev/null
printf '### Finding to promote\n- repo: demo\n- evidence: src/real.js:1\n- why: something\n- size: 1 night\n\n' >> "$BACKLOG"
FIXTURE="$TMP/fixture-nada" RESEARCH_RAW_DIR="$TMP" run --promote demo > "$TMP/out" 2>&1
RAWP=$(ls "$TMP"/raw-promote-* 2>/dev/null | head -1)
[ -n "$RAWP" ] || fail "a promotion pass discarded everything without keeping the raw output"
grep -q "does-not-exist-a.js" "$RAWP" || fail "the kept raw does not hold what was rejected"
echo "OK: a promotion pass that yields nothing keeps its raw output"

echo "PASS: devbrain-research"

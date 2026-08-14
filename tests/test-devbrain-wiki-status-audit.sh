#!/bin/bash
# tests/test-devbrain-wiki-status-audit.sh — narrow PR-state and workflow-state
# claims in wiki/status/*.md and wiki/services/*.md get checked against a fake
# `gh`, never the network. Same discipline as test-devbrain-repo-audit.sh:
# every detection assertion paired with a silence assertion, plus quote- and
# table-masking cases modeled on real stale-status pages that motivated this
# script (a status page with a corrected "PR merged" line, a services page
# with a corrected job entry, and a "how it used to be" table).
set -uo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$DIR/bin/devbrain-wiki-status-audit"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1"; exit 1; }

mkdir -p "$TMP/wiki/status" "$TMP/wiki/services" "$TMP/bin" "$TMP/gh-data/workflows"

# ---- fake `gh`: pr view + workflow list, driven by fixture files -----------
cat > "$TMP/bin/gh" <<'FAKEGH'
#!/bin/bash
DATA="$FAKE_GH_DATA"
if [ "$1" = "--version" ]; then
  echo "gh version 2.99.9 (fake)"
  exit 0
fi
if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
  NUM="$3"
  REPO=""
  shift 3
  while [ $# -gt 0 ]; do
    case "$1" in --repo) REPO="$2"; shift 2 ;; *) shift ;; esac
  done
  KEY="${REPO}#${NUM}"
  LINE="$(awk -F'\t' -v k="$KEY" '$1==k{print $2; found=1} END{if(!found) exit 1}' "$DATA/pr-states.tsv")"
  RC=$?
  if [ $RC -ne 0 ] || [ -z "$LINE" ]; then
    echo "no such PR: $KEY" >&2
    exit 1
  fi
  echo "{\"state\":\"$LINE\",\"mergedAt\":null}"
  exit 0
fi
if [ "$1" = "workflow" ] && [ "$2" = "list" ]; then
  REPO=""
  shift 2
  while [ $# -gt 0 ]; do
    case "$1" in --repo) REPO="$2"; shift 2 ;; *) shift ;; esac
  done
  FILE="$DATA/workflows/$(echo "$REPO" | tr '/' '_').json"
  if [ -f "$FILE" ]; then cat "$FILE"; else echo "[]"; fi
  exit 0
fi
echo "fake gh: unhandled invocation: $*" >&2
exit 1
FAKEGH
chmod +x "$TMP/bin/gh"
export FAKE_GH_DATA="$TMP/gh-data"

export WIKI_STATUS_AUDIT_WIKI="$TMP/wiki"
export WIKI_STATUS_AUDIT_ALLOWFILE="$TMP/allow"
export WIKI_STATUS_AUDIT_SCRAPERS_TSV="$TMP/scrapers.tsv"
export WIKI_STATUS_AUDIT_GH="$TMP/bin/gh"
export WIKI_STATUS_AUDIT_OWNER="testowner"

cat > "$TMP/allow" <<'EOF'
testrepo
machine-config
EOF

cat > "$TMP/scrapers.tsv" <<'EOF'
# id	repo	schedule	timeout_min	script
sync-acc	repob	weekly:1:8	20	scrapers/repob/sync-acc.sh
repoc-jobs	repoc	daily:6,14	180	scrapers/repoc/repoc-jobs.sh
EOF

# ---- PR-state fixture data --------------------------------------------------
# One row per owner/repo#N the fixtures below reference.
cat > "$TMP/gh-data/pr-states.tsv" <<'EOF'
testowner/testrepo#10	MERGED
testowner/testrepo#11	MERGED
testowner/testrepo#12	MERGED
testowner/testrepo#20	MERGED
testowner/testrepo#21	OPEN
testowner/testrepo#22	MERGED
testowner/testrepo#40	OPEN
otherowner/otherrepo#30	CLOSED
testowner/machine-config#4	OPEN
EOF

mkdir -p "$TMP/gh-data/workflows"
cat > "$TMP/gh-data/workflows/testowner_repob.json" <<'EOF'
[{"name":"Sync ACC Documents","path":".github/workflows/sync-acc.yml","state":"disabled_manually"}]
EOF
cat > "$TMP/gh-data/workflows/testowner_repoc.json" <<'EOF'
[{"name":"Scrape Job Listings","path":".github/workflows/scrape-jobs.yml","state":"active"}]
EOF

# ---- wiki/status/testrepo.md ------------------------------------------------
# Bullets are kept clean (no annotations inside the "- " text itself) on
# purpose: an earlier draft of this fixture put "SILENCE"/"DETECTION"
# explanations inside the bullets, and words like "MERGED" and "activo"
# inside those very annotations were then picked up by the regex they were
# describing -- a self-inflicted false positive. What each bullet must
# produce is documented here in the script instead:
#   #10  MERGED link, actual MERGED             -> silent
#   #11  inside a quoted past claim ("sin mergear") -> silent regardless of
#        actual (11 is set to MERGED to prove this isn't silent by luck)
#   #12  bare "sin mergear", actual MERGED       -> DETECTION (a stale
#        "not yet merged" claim outliving the actual merge)
#   #20/#22 bare "mergeados", actual MERGED      -> silent
#   #21  same bullet, actual OPEN                -> DETECTION
#   #30  cross-owner link, "sin mergear", actual CLOSED -> DETECTION
#   #40  only ever appears inside a markdown table row  -> never scanned
cat > "$TMP/wiki/status/testrepo.md" <<'EOF'
# testrepo — status

- **Mergeado:** [PR #10](https://github.com/testowner/testrepo/pull/10) (2026-08-01).
- **Corregido 2026-08-12:** este board decia "PR #11 sin mergear, bloqueado" -- desactualizado. Verificado en vivo: se mergeo #11 hace rato.
- **Bloqueado por:** nada. PR #12 sin mergear, esperando revision.
- **Multi:** PRs #20/#21/#22 mergeados en esta sesion.
- **Cruzado:** [PR #30](https://github.com/otherowner/otherrepo/pull/30) sin mergear todavia.
- **Tabla ejemplo:**

| Job | Nota |
|---|---|
| foo | mergeado PR #40 |

Texto simple despues de la tabla, no es un bullet.
EOF

# ---- wiki/status/TEMPLATE.md: must be skipped entirely ----------------------
cat > "$TMP/wiki/status/TEMPLATE.md" <<'EOF'
# <repo> — status

- **Ultimo avance:** PR #999 mergeado.
EOF

# ---- wiki/services/testautomations.md --------------------------------------
#   #4   backtick-repo `machine-config`, claim OPEN, actual OPEN -> silent
#   #5   bare mention, no link, no backtick-repo -> skipped (services pages
#        never fall back to a filename-derived repo)
#   sync-acc:RESUELTO, qualified by "apagado" elsewhere in the bullet,
#        actual disabled_manually -> silent
#   repoc-jobs:RESUELTO, no unquoted apagado/activo/pendiente qualifier
#        (the only "pendiente" is inside quotes, the only "active" is the
#        English word quoting `gh`'s own output, not the Spanish "activo")
#        -> skipped, ambiguous, must NOT be silent by accident
#   sync-acc:pendiente (second, separate bullet), actual disabled_manually
#        -> DETECTION (still claimed pending after the workflow was
#        actually disabled)
cat > "$TMP/wiki/services/testautomations.md" <<'EOF'
# Test automations

- **PR abierto, pendiente de merge:** `machine-config` PR #4 (rama foo).
- **Sin repo:** PR #5, sin mergear, prioridad baja.
- **`sync-acc`: RESUELTO** (2026-08-02). Su workflow de GitHub quedo **apagado** (`gh workflow disable`).
- **`repoc-jobs`: RESUELTO** (2026-08-04, corregida el 2026-08-12 -- seguia marcada "pendiente" 8 dias despues). Mecanismo distinto: se quito el trigger `on: schedule`; el workflow sigue `active` a proposito.
- **`sync-acc`: pendiente** de resolver el doble agendamiento (bullet de prueba).
EOF

OUT="$("$BIN")"
RC=$?
[ "$RC" = 1 ] || fail "expected exit 1 (findings present), got $RC -- output:
$OUT"

assert_line() { printf '%s\n' "$OUT" | grep -qF "$1" || fail "missing line: $1 -- full output:
$OUT"; }
assert_absent() { printf '%s\n' "$OUT" | grep -qF "$1" && fail "unexpected line: $1 -- full output:
$OUT"; }

# ---- detection assertions (must all appear) --------------------------------
assert_line "testowner/testrepo#12	claim=OPEN	actual=MERGED"
assert_line "testowner/testrepo#21	claim=MERGED	actual=OPEN"
assert_line "otherowner/otherrepo#30	claim=OPEN	actual=CLOSED"
assert_line "sync-acc (testowner/repob)	claim=pendiente	actual=disabled_manually"

# ---- silence assertions (must never appear) --------------------------------
assert_absent "testrepo#10"
assert_absent "testrepo#11"
assert_absent "testrepo#20	claim"
assert_absent "testrepo#22	claim"
assert_absent "testrepo#40"
assert_absent "machine-config#4"
assert_absent "#5	claim"
assert_absent "#999"
assert_absent "repoc-jobs (testowner/repoc)"
# sync-acc's RESUELTO bullet must not add a SECOND workflow finding beyond
# the one pendiente detection above (it must resolve to bucket OFF and match
# the actual disabled_manually state, i.e. be silent on its own).
[ "$(printf '%s\n' "$OUT" | grep -c 'sync-acc (testowner/repob)')" = "1" ] \
  || fail "expected exactly 1 sync-acc finding (the pendiente one), got:
$OUT"

echo "$OUT" | grep -q "^wiki-status-audit: 4$" \
  || fail "expected count line 'wiki-status-audit: 4', got:
$OUT"
echo "OK: all detection + silence assertions passed"

# ---- --quiet: no output, same exit code ------------------------------------
QOUT="$("$BIN" --quiet)"
RCQ=$?
[ -z "$QOUT" ] || fail "--quiet must print nothing, got:
$QOUT"
[ "$RCQ" = 1 ] || fail "--quiet must keep the same exit code, got $RCQ"
echo "OK: --quiet suppresses output, keeps exit code"

# ---- error paths -------------------------------------------------------------
WIKI_STATUS_AUDIT_WIKI="$TMP/does-not-exist" "$BIN" >/dev/null 2>&1
[ $? = 2 ] || fail "missing WIKI dir must exit 2"

cat > "$TMP/bin/gh-broken" <<'EOF'
#!/bin/bash
exit 1
EOF
chmod +x "$TMP/bin/gh-broken"
WIKI_STATUS_AUDIT_GH="$TMP/bin/gh-broken" "$BIN" >/dev/null 2>&1
[ $? = 2 ] || fail "gh --version failing must exit 2"
echo "OK: error paths (missing wiki dir, unusable gh) exit 2"

# ---- mutation check ----------------------------------------------------------
# Copy the checker, then flip its PR-state comparison from "!=" to "==" so a
# real mismatch (claim OPEN, actual MERGED) reads as consistent instead of
# flagged. If the mutated copy still reports the same finding, this test
# suite was never actually exercising the comparison -- it would be a
# checker nobody tried to fool. Operates on a COPY, never on $BIN itself.
MUTANT="$TMP/mutated-devbrain-wiki-status-audit"
cp "$BIN" "$MUTANT"
python3 - "$MUTANT" <<'PYEOF'
import sys
path = sys.argv[1]
with open(path) as fh:
    text = fh.read()
needle = "if actual and actual != claim:"
assert needle in text, "mutation target line not found -- test fixture drifted from implementation"
text = text.replace(needle, "if actual and actual == claim:", 1)
with open(path, "w") as fh:
    fh.write(text)
PYEOF
chmod +x "$MUTANT"

MUT_OUT="$("$MUTANT")"
MUT_RC=$?

if [ "$MUT_RC" = 1 ] && printf '%s\n' "$MUT_OUT" | grep -qF "testrepo#12	claim=OPEN	actual=MERGED"; then
  fail "mutation check failed: inverting the comparison did NOT change detection of testrepo#12 -- the check was never really checking this"
fi
echo "OK: mutation check -- breaking the core comparison changes the result, confirming the check can fail"

# ---- confirm the real (unmutated) implementation still passes -------------
FINAL_OUT="$("$BIN")"
printf '%s\n' "$FINAL_OUT" | grep -qF "testrepo#12	claim=OPEN	actual=MERGED" \
  || fail "the real implementation stopped detecting testrepo#12 -- should never happen, $BIN was never touched"
echo "OK: real implementation still detects testrepo#12"

echo "PASS"

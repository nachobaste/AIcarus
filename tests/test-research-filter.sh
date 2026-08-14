#!/bin/bash
# tests/test-research-filter.sh — the gate between "the model said it" and
# "it goes in the backlog".
#
# devbrain-research asks a model to report gaps. A model that invents a
# plausible finding costs more than no research at all: the owner would approve
# work against a file that does not exist. So every finding must carry a
# citation that resolves to a real file AND a real line, and this suite is the
# only thing proving the filter can actually reject one.
#
# Each rejection assertion is paired with a silence assertion (the discarded
# text must not reach stdout), following tests/test-devbrain-drift.sh.
set -uo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$DIR/lib/research_filter.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1"; exit 1; }

# ---- a repo with known contents --------------------------------------------
mkdir -p "$TMP/repo/src" "$TMP/wiki"
printf 'uno\ndos\ntres\ncuatro\ncinco\n' > "$TMP/repo/src/real.js"   # 5 lines
printf '# Mejoras propuestas\n' > "$TMP/wiki/mejoras.md"

run() { RESEARCH_REPO_ROOT="$TMP/repo" RESEARCH_EXISTING="$TMP/wiki/mejoras.md" \
        RESEARCH_MAX="${MAXV:-5}" python3 "$BIN"; }

finding() { # $1=titulo $2=evidencia
  printf '### %s\n- repo: demo\n- evidencia: %s\n- porque: importa por X\n- tamano: 1 noche\n\n' "$1" "$2"
}

# ---- 1. the happy path, first: a real citation survives --------------------
# If this fails, every rejection assertion below proves nothing (a filter that
# drops everything would pass them all).
finding "Hallazgo bueno" "src/real.js:3" | run > "$TMP/out" 2> "$TMP/err"; RC=$?
[ "$RC" -eq 0 ] || fail "valid finding should exit 0, got $RC ($(cat "$TMP/err"))"
grep -q "Hallazgo bueno" "$TMP/out" || fail "valid finding was not kept"
grep -q "hallazgos: 1" "$TMP/err" || fail "summary should report 1 kept, got: $(cat "$TMP/err")"
grep -q "descartados: 0" "$TMP/err" || fail "summary should report 0 discarded"
echo "OK: a finding citing a real file:line is kept"

# ---- 2. canary: a citation to a file that does not exist -------------------
finding "Hallazgo inventado" "src/fantasma.js:3" | run > "$TMP/out" 2> "$TMP/err"
grep -q "Hallazgo inventado" "$TMP/out" && fail "invented file reached stdout"
grep -q "src/fantasma.js" "$TMP/out" && fail "invented path reached stdout"
grep -q "cita-no-resuelve" "$TMP/err" || fail "did not report the discard reason"
echo "OK: a citation to a nonexistent file is discarded and never printed"

# ---- 3. canary: real file, line beyond end of file -------------------------
# The cheap version of this check only stats the file. That would accept
# 'real.js:99999' and let a fabricated line number through.
finding "Linea inventada" "src/real.js:99999" | run > "$TMP/out" 2> "$TMP/err"
grep -q "Linea inventada" "$TMP/out" && fail "out-of-range line reached stdout"
grep -q "cita-no-resuelve" "$TMP/err" || fail "did not discard an out-of-range line"
echo "OK: a real file with a fabricated line number is discarded"

# ---- 4. escaping the repo is not a valid citation --------------------------
finding "Fuera del repo" "../../etc/hosts:1" | run > "$TMP/out" 2> "$TMP/err"
grep -q "Fuera del repo" "$TMP/out" && fail "path escaping the repo was accepted"
echo "OK: a citation outside the repo root is discarded"

# ---- 4b. a citation wrapped in backticks is still a citation ---------------
# Lived regression (2026-08-08): the first real run against repoa lost
# 3 of 3 valid findings because the model wrote `index.js:1` in code formatting.
# Rejecting a real file over a markdown backtick is the filter being wrong, not
# the model — and it looks identical to fabrication in the summary.
finding "Con backticks" '`src/real.js:3`' | run > "$TMP/out" 2> "$TMP/err"
grep -q "Con backticks" "$TMP/out" || fail "a backticked real citation was rejected: $(cat "$TMP/err")"
echo "OK: a citation in backticks is accepted"

# ...but backticks must not become a way to smuggle a fake path through
finding "Backticks falso" '`src/fantasma.js:3`' | run > "$TMP/out" 2> "$TMP/err"
grep -q "Backticks falso" "$TMP/out" && fail "backticks let a fabricated path through"
echo "OK: backticks do not excuse a fabricated path"

# ---- 4c. accented field names are the same field ---------------------------
# Lived regression (2026-08-08): the first real run against repoc lost 5 of 5
# findings because the prompt asks for 'tamano' and the model, writing Spanish,
# produced 'tamaño'. Demanding a misspelling from the model is the filter's bug.
printf '### Con enie\n- repo: demo\n- evidencia: src/real.js:2\n- porque: importa\n- tamaño: 1 noche\n\n' \
  | run > "$TMP/out" 2> "$TMP/err"
grep -q "Con enie" "$TMP/out" || fail "an accented field name was rejected: $(cat "$TMP/err")"
echo "OK: 'tamaño' and 'tamano' are the same field"

# ---- 5. dedup against what the backlog already holds -----------------------
printf '### Hallazgo bueno\n- repo: demo\n' >> "$TMP/wiki/mejoras.md"
finding "Hallazgo bueno" "src/real.js:1" | run > "$TMP/out" 2> "$TMP/err"
grep -q "Hallazgo bueno" "$TMP/out" && fail "already-known finding was reported again"
grep -q "duplicado" "$TMP/err" || fail "did not report the duplicate reason"
printf '# Mejoras propuestas\n' > "$TMP/wiki/mejoras.md"   # restore
echo "OK: a finding already in the backlog is not repeated"

# ---- 6. an incomplete finding is not half-accepted -------------------------
printf '### Sin evidencia\n- repo: demo\n- porque: x\n- tamano: 1 noche\n\n' \
  | run > "$TMP/out" 2> "$TMP/err"
grep -q "Sin evidencia" "$TMP/out" && fail "a finding with no citation was kept"
grep -q "incompleto" "$TMP/err" || fail "did not report the incomplete reason"
echo "OK: a finding missing its citation is discarded"

# ---- 7. the cap holds ------------------------------------------------------
{ for i in 1 2 3 4 5 6 7; do finding "Hallazgo $i" "src/real.js:2"; done; } \
  | MAXV=5 run > "$TMP/out" 2> "$TMP/err"
COUNT=$(grep -c '^### ' "$TMP/out")
[ "$COUNT" -eq 5 ] || fail "cap of 5 not honoured, kept $COUNT"
grep -q "Hallazgo 7" "$TMP/out" && fail "kept a finding beyond the cap"
echo "OK: the per-run cap is honoured"

# ---- 7b. the cap must not be silent ----------------------------------------
# A truncating tool that reports "descartados: 0" reads as "covered everything".
grep -q "truncado: 2" "$TMP/err" || fail "the cap dropped 2 findings without saying so: $(cat "$TMP/err")"
echo "OK: findings dropped by the cap are reported, not hidden"

# ---- 8. nothing in, nothing invented ---------------------------------------
printf '' | run > "$TMP/out" 2> "$TMP/err"; RC=$?
[ "$RC" -eq 0 ] || fail "empty input should exit 0, got $RC"
[ ! -s "$TMP/out" ] || fail "empty input produced output: $(cat "$TMP/out")"
grep -q "hallazgos: 0" "$TMP/err" || fail "empty input should report 0 findings"
echo "OK: empty input yields nothing, invents nothing"

# ---- 9. prose around the findings is ignored, not emitted ------------------
{ printf 'Claro, aqui estan los hallazgos que encontre:\n\n'
  finding "Hallazgo entre prosa" "src/real.js:4"
  printf '\nEspero que te sirvan.\n'; } | run > "$TMP/out" 2> "$TMP/err"
grep -q "Hallazgo entre prosa" "$TMP/out" || fail "finding surrounded by prose was lost"
grep -q "Espero que te sirvan" "$TMP/out" && fail "model chatter reached the backlog"
grep -q "Claro, aqui estan" "$TMP/out" && fail "model preamble reached the backlog"
echo "OK: findings are extracted, surrounding chatter is dropped"

# ---- multi-repo: the `conexiones` scope ------------------------------------
# A "connection" that cites only one repo is not a connection. This is the rule
# that keeps the bucket from degenerating into internal gaps wearing a hat, so
# each assertion is paired with a control that isolates WHY a finding dropped.
mkdir -p "$TMP/repoB/lib"
printf 'a\nb\nc\n' > "$TMP/repoB/lib/other.py"          # 3 lines

runmulti() { RESEARCH_REPO_ROOTS="$(printf 'demo=%s\notro=%s' "$TMP/repo" "$TMP/repoB")" \
             RESEARCH_EXISTING="$TMP/wiki/mejoras.md" \
             RESEARCH_MIN_REPOS="${MINREPOS:-1}" RESEARCH_MAX=5 python3 "$BIN"; }

# A citation valid in the SECOND repo must resolve — otherwise multi-repo is a lie.
finding "solo-en-repo-b" "lib/other.py:2" | runmulti > "$TMP/m1" 2>"$TMP/e1"
grep -q "solo-en-repo-b" "$TMP/m1" || fail "a citation in the second repo did not resolve"
echo "OK: citations resolve against any repo in a multi-repo run"

# Same finding, now requiring two repos: must drop, and say why.
MINREPOS=2
finding "solo-en-repo-b" "lib/other.py:2" | runmulti > "$TMP/m2" 2>"$TMP/e2"
grep -q "solo-en-repo-b" "$TMP/m2" && fail "a single-repo finding survived MIN_REPOS=2"
grep -q "una-sola-repo" "$TMP/e2" || fail "the drop reason was not reported"
echo "OK: MIN_REPOS=2 drops a finding evidenced in only one repo, and names the reason"

# And a genuine cross-repo finding must survive the same setting. Without this,
# a filter that rejected everything would pass the assertion above.
finding "cruza-dos-repos" "src/real.js:3, lib/other.py:2" | runmulti > "$TMP/m3" 2>"$TMP/e3"
grep -q "cruza-dos-repos" "$TMP/m3" \
  || fail "a real two-repo finding was dropped ($(cat "$TMP/e3"))"
echo "OK: a finding citing two repos survives MIN_REPOS=2"

# One real citation plus one invented is still partly fabricated, even across repos.
finding "mitad-inventada" "src/real.js:3, lib/other.py:99" | runmulti > "$TMP/m4" 2>"$TMP/e4"
grep -q "mitad-inventada" "$TMP/m4" && fail "a half-fabricated cross-repo finding survived"
echo "OK: a bad citation still sinks the finding in multi-repo mode"
MINREPOS=1

echo "PASS: research-filter"

#!/bin/bash
# tests/test-research-promote.sh — promotion: raw backlog -> 2-3 proposals the owner can decide.
#
# Two jobs, both here because both are where promotion can quietly go wrong:
#
#   select   picks which findings get the expensive deep pass. The criteria must live in
#            code, not in a prompt, or nobody can audit or change why something was chosen.
#            It must also be deterministic: same backlog, same picks.
#   validate enforces the owner's stated definition of "listo" (2026-08-08): at least two real
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
printf 'a\nb\nc\nd\ne\n' > "$TMP/repo/src/uno.js"
printf 'a\nb\nc\n'       > "$TMP/repo/src/dos.js"
printf 'a\nb\nc\n'       > "$TMP/repo/src/tres.js"

sel() { RESEARCH_PROMOTE_MAX="${MAXP:-3}" python3 "$BIN" select; }
val() { RESEARCH_REPO_ROOT="$TMP/repo" python3 "$BIN" validate; }

hallazgo() { # $1=titulo $2=evidencia $3=porque $4=tamano
  printf '### %s\n- repo: demo\n- evidencia: %s\n- porque: %s\n- tamano: %s\n\n' "$1" "$2" "$3" "$4"
}

# ---- SELECT ----------------------------------------------------------------

# 1. it picks a few, not everything
{ for i in 1 2 3 4 5 6; do hallazgo "Hallazgo $i" "src/uno.js:1" "cosa normal" "1 noche"; done; } \
  | sel > "$TMP/out" 2> "$TMP/err"
N=$(grep -c '^### ' "$TMP/out")
[ "$N" -eq 3 ] || fail "6 findings should promote 3, promoted $N"
echo "OK: six findings promote three, not six"

# 2. deterministic — the same backlog must not shuffle between runs
{ for i in 1 2 3 4 5 6; do hallazgo "Hallazgo $i" "src/uno.js:1" "cosa normal" "1 noche"; done; } \
  | sel > "$TMP/out2" 2>/dev/null
diff -q "$TMP/out" "$TMP/out2" >/dev/null || fail "selection is not deterministic between runs"
echo "OK: selection is deterministic"

# 3. a finding that declares it blocks other work outranks a plain one
{ hallazgo "Plana" "src/uno.js:1" "estaria bueno arreglarlo" "1 noche"
  hallazgo "Bloqueante" "src/dos.js:1" "bloquea a los otros repos hasta que se resuelva" "3 noches"; } \
  | MAXP=1 sel > "$TMP/out" 2>/dev/null
grep -q "Bloqueante" "$TMP/out" || fail "a declared blocker did not win the top slot"
grep -q "Plana" "$TMP/out" && fail "the plain finding was promoted over the blocker"
echo "OK: a finding that declares it blocks others ranks first"

# 4. more distinct files cited beats fewer, all else equal
{ hallazgo "Una cita" "src/uno.js:1" "cosa normal" "1 noche"
  hallazgo "Tres citas" "src/uno.js:1, src/dos.js:1, src/tres.js:1" "cosa normal" "1 noche"; } \
  | MAXP=1 sel > "$TMP/out" 2>/dev/null
grep -q "Tres citas" "$TMP/out" || fail "harder evidence did not outrank thinner evidence"
echo "OK: more distinct files cited outranks fewer"

# 5. smaller effort breaks the tie
{ hallazgo "Grande" "src/uno.js:1" "cosa normal" "5 noches"
  hallazgo "Chica"  "src/dos.js:1" "cosa normal" "1 noche"; } \
  | MAXP=1 sel > "$TMP/out" 2>/dev/null
grep -q "Chica" "$TMP/out" || fail "the smaller task did not win the tie"
echo "OK: smaller effort wins the tie"

# 6. something already promoted is not promoted again
# Otherwise the same proposal reaches the owner every single night until the owner acts on it.
{ hallazgo "Ya promovido" "src/uno.js:1" "cosa normal" "1 noche"
  printf '## Propuestas — 2026-08-08\n\n### Propuesta vieja\n- origen: Ya promovido\n\n'; } \
  | MAXP=3 sel > "$TMP/out" 2> "$TMP/err"
grep -q "Ya promovido" "$TMP/out" && fail "an already-promoted finding was promoted again"
grep -q "nada que promover" "$TMP/err" || fail "should say there is nothing left to promote"
echo "OK: an already-promoted finding is not promoted twice"

# 7. an empty backlog invents nothing
printf '' | sel > "$TMP/out" 2> "$TMP/err"; RC=$?
[ "$RC" -eq 0 ] || fail "empty backlog should exit 0, got $RC"
[ ! -s "$TMP/out" ] || fail "empty backlog produced output: $(cat "$TMP/out")"
grep -q "nada que promover" "$TMP/err" || fail "empty backlog should say so"
echo "OK: an empty backlog promotes nothing and invents nothing"

# ---- VALIDATE --------------------------------------------------------------

propuesta() { # $1=titulo $2=archivosA $3=archivosB(o vacio)
  printf '### %s\n- origen: H\n- repo: demo\n- esfuerzo: 1 noche\n- riesgos: alguno\n- verificar: correr los tests\n\n' "$1"
  printf '#### Opcion A — una\n- archivos: %s\n- pros: rapida\n- contras: parcial\n\n' "$2"
  [ -n "$3" ] && printf '#### Opcion B — otra\n- archivos: %s\n- pros: completa\n- contras: cara\n\n' "$3"
}

# 8. the happy path first, or every rejection below proves nothing
propuesta "Buena" "src/uno.js" "src/dos.js" | val > "$TMP/out" 2> "$TMP/err"; RC=$?
[ "$RC" -eq 0 ] || fail "a valid proposal should exit 0, got $RC ($(cat "$TMP/err"))"
grep -q "Buena" "$TMP/out" || fail "a valid proposal was rejected: $(cat "$TMP/err")"
echo "OK: a proposal with two options touching different files is kept"

# 9. one option is not a choice
propuesta "Sin opciones" "src/uno.js" "" | val > "$TMP/out" 2> "$TMP/err"
grep -q "Sin opciones" "$TMP/out" && fail "a proposal with a single option was kept"
grep -q "opciones-insuficientes" "$TMP/err" || fail "did not report the reason"
echo "OK: a proposal with one option is rejected"

# 10. two options over the same files are one option written twice
propuesta "Relleno" "src/uno.js" "src/uno.js" | val > "$TMP/out" 2> "$TMP/err"
grep -q "Relleno" "$TMP/out" && fail "filler second option was accepted"
grep -q "opciones-identicas" "$TMP/err" || fail "did not report identical options"
echo "OK: two options touching the same files are rejected as filler"

# 11. a proposal may name a file it would CREATE
# Findings cite evidence, so their paths must exist. Proposals name what they would
# touch, and creating a file is normal work — the finding "there is no package.json"
# can only be answered by a proposal that names one. Applying the finding rule here
# rejected 3 of 3 real proposals on 2026-08-08.
propuesta "Crea un archivo" "src/uno.js" "package.json" | val > "$TMP/out" 2> "$TMP/err"
grep -q "Crea un archivo" "$TMP/out" || fail "a proposal creating a new file was rejected: $(cat "$TMP/err")"
grep -q "package.json (nuevo)" "$TMP/out" || fail "a file that does not exist yet is not marked as new"
echo "OK: a proposal may name a file it would create, marked (nuevo)"

# ...but it must be anchored in the real repo somewhere
# A proposal where NOTHING resolves is either about another repo or invented whole.
propuesta "Sin anclaje" "no-existe-a.js" "no-existe-b.js" | val > "$TMP/out" 2> "$TMP/err"
grep -q "Sin anclaje" "$TMP/out" && fail "a proposal with no real file was kept"
grep -q "sin-anclaje" "$TMP/err" || fail "did not report the reason"
echo "OK: a proposal where no named file exists is rejected as unanchored"

# 12. the system owns the attribution, not the model
# A model that misattributes a proposal marks the wrong finding as promoted, and the
# real one comes back every night. It is also the guard against re-promotion, so it
# cannot depend on the model remembering to write a line.
{ propuesta "Con origen" "src/uno.js" "src/dos.js"
  printf -- '- origen: LO QUE EL MODELO INVENTO\n'; } \
  | RESEARCH_REPO_ROOT="$TMP/repo" python3 "$BIN" validate --origen "Hallazgo verdadero" > "$TMP/out" 2>/dev/null
grep -q '^- origen: Hallazgo verdadero$' "$TMP/out" || fail "the authoritative origen was not written"
grep -q "LO QUE EL MODELO INVENTO" "$TMP/out" && fail "the model's own origen line survived"
[ "$(grep -c '^- origen:' "$TMP/out")" -eq 1 ] || fail "more than one origen line"
echo "OK: validate writes the authoritative origen and drops the model's"

# 13. the anchor must be INSIDE the repo, not just somewhere on the machine
# An absolute path defeats os.path.join, so "/etc/hosts" resolved and counted as
# anchoring. Cross-repo options are legitimate and stay allowed — a real proposal on
# 2026-08-08 had one — but at least one file must be in the repo the finding is about,
# or the check is not checking anything.
propuesta "Solo afuera" "/etc/hosts" "/usr/bin/env" | val > "$TMP/out" 2> "$TMP/err"
grep -q "Solo afuera" "$TMP/out" && fail "a proposal anchored only outside the repo was kept"
grep -q "sin-anclaje" "$TMP/err" || fail "did not report it as unanchored"
echo "OK: files outside the repo do not count as an anchor"

propuesta "Mixta" "src/uno.js" "/etc/hosts" | val > "$TMP/out" 2> "$TMP/err"
grep -q "Mixta" "$TMP/out" || fail "a cross-repo option was rejected even with a real in-repo anchor"
echo "OK: a cross-repo option is fine when something in the repo anchors it"

# ---- DIGEST -----------------------------------------------------------------
# What reaches the owner's phone at 6am: numbered, terse, and only what has not
# already been decided on. The number is load-bearing — plan 250 lets the owner
# reply "dale 2" from Telegram, so it must stay stable and exact, never reworded.

dig() { python3 "$BIN" digest; }

backlog_con_propuesta() { # $1=titulo_hallazgo $2=porque $3=titulo_propuesta $4=extra(opcional, tras la propuesta)
  {
    printf '## 2026-08-08 — demo\n\n'
    hallazgo "$1" "src/uno.js:1" "$2" "1 noche"
    printf '## Propuestas — 2026-08-08\n\n'
    printf '### %s\n- origen: %s\n- repo: demo\n- esfuerzo: 2 noches\n- riesgos: alguno\n- verificar: tests\n\n' "$3" "$1"
    printf '#### Opcion A\n- archivos: src/uno.js\n\n#### Opcion B\n- archivos: src/dos.js\n\n'
    [ -n "${4:-}" ] && printf '%s\n' "$4"
  }
}

# 14. a pending proposal is numbered 1, with title / porque / esfuerzo — three lines
backlog_con_propuesta "Hallazgo A" "esto bloquea a los otros repos" "Arreglar el bloqueo" \
  | dig > "$TMP/out" 2>"$TMP/err"
grep -q "^1\. Arreglar el bloqueo$" "$TMP/out" || fail "the proposal was not numbered 1 with its exact title: $(cat "$TMP/out")"
grep -q "esto bloquea a los otros repos" "$TMP/out" || fail "the origen finding's porque line is missing"
grep -q "2 noches" "$TMP/out" || fail "the effort estimate is missing"
[ "$(sed -n '1,3p' "$TMP/out" | wc -l | tr -d ' ')" = "3" ] || fail "a proposal must be exactly 3 lines"
echo "OK: a pending proposal is numbered 1 in exactly 3 lines"

# 15. an empty backlog, or one with no promoted proposals, produces nothing
printf '' | dig > "$TMP/out" 2>/dev/null
[ ! -s "$TMP/out" ] || fail "an empty backlog produced digest output"
hallazgo "Solo hallazgo" "src/uno.js:1" "algo" "1 noche" | dig > "$TMP/out" 2>/dev/null
[ ! -s "$TMP/out" ] || fail "a backlog with findings but no proposals produced digest output"
echo "OK: nothing to decide means nothing is printed, never invented"

# 16. a proposal already decided (by devbrain-day / Telegram, plan 240/250) is not repeated
# The decision line format is the forward-compatible contract for those plans, not built yet.
backlog_con_propuesta "Hallazgo B" "importa" "Ya decidida" "- decision: aprobada" \
  | dig > "$TMP/out" 2>/dev/null
grep -q "Ya decidida" "$TMP/out" && fail "a decided proposal was shown again"
echo "OK: a proposal marked decided is not shown"

# 17. two pending proposals number 1 and 2, in backlog order — never shuffled
{ backlog_con_propuesta "H1" "primero" "Primera propuesta"
  backlog_con_propuesta "H2" "segundo" "Segunda propuesta"; } | dig > "$TMP/out" 2>/dev/null
grep -q "^1\. Primera propuesta$" "$TMP/out" || fail "first proposal is not numbered 1"
grep -q "^2\. Segunda propuesta$" "$TMP/out" || fail "second proposal is not numbered 2"
echo "OK: multiple pending proposals number in backlog order"

# 18. missing origen (edge case: hand-edited backlog) does not crash, degrades honestly
printf '### Huerfana\n- origen: No Existe\n- repo: demo\n- esfuerzo: 1 noche\n- riesgos: x\n- verificar: y\n\n#### A\n- archivos: a\n\n#### B\n- archivos: b\n\n' \
  | dig > "$TMP/out" 2>"$TMP/err"; RC=$?
[ "$RC" -eq 0 ] || fail "a proposal with a dangling origen crashed the digest, rc=$RC"
grep -q "Huerfana" "$TMP/out" || fail "a proposal with a dangling origen should still show, degraded"
echo "OK: a dangling origen degrades honestly instead of crashing"

# 19. the cap is visible, never a silent truncation
{ for i in 1 2 3 4 5 6 7; do backlog_con_propuesta "HC$i" "razon $i" "Propuesta $i"; done; } \
  | RESEARCH_DIGEST_MAX=3 dig > "$TMP/out" 2>"$TMP/err"
[ "$(grep -c '^[0-9]\+\. ' "$TMP/out")" -eq 3 ] || fail "the cap of 3 was not honoured"
grep -qi "4 m" "$TMP/out" || fail "the digest hides the other 4 pending proposals in silence"
echo "OK: proposals beyond the cap are reported, not hidden"

# ---- AGE (2026-08-12): the "## Propuestas — YYYY-MM-DD" heading is a real date,
# already written when a finding is promoted — not a proxy like Bloqueadas' mtime.
# Age must not touch the numbered title line (plan 250's "dale N"), so it is folded
# into the Esfuerzo line, which is why every assertion above about "exactly 3 lines"
# and the exact title regex must keep passing unchanged (they do, re-run above).
dias_atras() { date -v-"$1"d +%Y-%m-%d 2>/dev/null || date -d "-$1 days" +%Y-%m-%d; }

backlog_con_propuesta_fecha() { # $1=titulo_hallazgo $2=porque $3=titulo_propuesta $4=fecha_iso
  {
    printf '## 2026-08-08 — demo\n\n'
    hallazgo "$1" "src/uno.js:1" "$2" "1 noche"
    printf '## Propuestas — %s\n\n' "$4"
    printf '### %s\n- origen: %s\n- repo: demo\n- esfuerzo: 2 noches\n- riesgos: alguno\n- verificar: tests\n\n' "$3" "$1"
    printf '#### Opcion A\n- archivos: src/uno.js\n\n#### Opcion B\n- archivos: src/dos.js\n\n'
  }
}

# 20. a fresh proposal (promoted yesterday, default threshold 3) shows its age,
# no escalation marker
backlog_con_propuesta_fecha "HFresco" "algo" "Propuesta fresca" "$(dias_atras 1)" \
  | dig > "$TMP/out" 2>/dev/null
grep -q "^1\. Propuesta fresca$" "$TMP/out" || fail "title line changed for a fresh proposal: $(cat "$TMP/out")"
grep -q "esperando 1 día" "$TMP/out" || fail "a fresh proposal should still show its age: $(cat "$TMP/out")"
grep -q "⚠️" "$TMP/out" && fail "a fresh proposal (1 day, threshold 3) must NOT show the stale marker"
echo "OK: a fresh proposal shows its age, no escalation"

# 21. a stale proposal (10 days, past the default 3-day threshold) DOES escalate,
# and the escalation never touches the numbered title line
backlog_con_propuesta_fecha "HViejo" "algo" "Propuesta vieja" "$(dias_atras 10)" \
  | dig > "$TMP/out" 2>/dev/null
grep -q "^1\. Propuesta vieja$" "$TMP/out" || fail "title line was mangled by the stale marker: $(cat "$TMP/out")"
grep -q "⚠️.*esperando 10 días" "$TMP/out" || fail "a 10-day-old proposal past the threshold must show ⚠️: $(cat "$TMP/out")"
echo "OK: a stale proposal escalates visually without disturbing its numbered title"

# 22. DEVBRAIN_DIGEST_STALE_DAYS is overridable and actually changes the cutoff —
# planting the case that must NOT fire is the only way to trust the case that must
grep -q "⚠️" "$TMP/out" || fail "sanity check failed: previous run should have had ⚠️"
backlog_con_propuesta_fecha "HViejo2" "algo" "Propuesta vieja 2" "$(dias_atras 10)" \
  | DEVBRAIN_DIGEST_STALE_DAYS=100 dig > "$TMP/out" 2>/dev/null
grep -q "⚠️" "$TMP/out" && fail "raising the threshold to 100 must suppress escalation for a 10-day-old item"
grep -q "esperando 10 días" "$TMP/out" || fail "raising the threshold must not hide the age itself, only the marker"
echo "OK: DEVBRAIN_DIGEST_STALE_DAYS=100 suppresses escalation for the same 10-day-old item"

backlog_con_propuesta_fecha "HFresco2" "algo" "Propuesta fresca 2" "$(dias_atras 2)" \
  | DEVBRAIN_DIGEST_STALE_DAYS=1 dig > "$TMP/out" 2>/dev/null
grep -q "⚠️" "$TMP/out" || fail "lowering the threshold to 1 must escalate a 2-day-old item"
echo "OK: DEVBRAIN_DIGEST_STALE_DAYS=1 escalates the same 2-day-old item"

# 23. a proposal with no '## Propuestas — DATE' heading (hand-edited backlog, same
# case as test 18's Huerfana) shows no age at all rather than guessing one — and
# still keeps the 3-line contract
printf '### Sin fecha\n- origen: No Existe\n- repo: demo\n- esfuerzo: 1 noche\n- riesgos: x\n- verificar: y\n\n#### A\n- archivos: a\n\n#### B\n- archivos: b\n\n' \
  | dig > "$TMP/out" 2>/dev/null
grep -q "esperando" "$TMP/out" && fail "a proposal with no promotion date should not show a fabricated age"
grep -q "⚠️" "$TMP/out" && fail "a proposal with no promotion date should not escalate"
[ "$(sed -n '1,3p' "$TMP/out" | wc -l | tr -d ' ')" = "3" ] || fail "still must be exactly 3 lines with no date"
echo "OK: a proposal with no promotion date shows no age, no crash, still 3 lines"

# 24. the escalation marker survives the AI-summarizer boundary untouched — proven
# at the integration level in tests/test-devbrain-digest-proposals.sh (the block is
# appended verbatim AFTER the summarizer call, same mechanism as the numbering).

echo "PASS: research-promote"

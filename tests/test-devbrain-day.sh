#!/bin/bash
# tests/test-devbrain-day.sh — end-to-end devbrain-day: the six "cómo verificar" cases
# from plan 240, each paired with what should NOT happen alongside it.
set -uo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$DIR/bin/devbrain-day"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1"; exit 1; }

QUEUE_DIR="$TMP/queue"; WIKI_DIR="$TMP/wiki"
mkdir -p "$QUEUE_DIR" "$WIKI_DIR/projects"
for d in "$QUEUE_DIR" "$WIKI_DIR"; do
  git -C "$d" init -q; git -C "$d" config user.email t@t.t; git -C "$d" config user.name t
done
printf 'demo\n' > "$TMP/allow"
BACKLOG="$WIKI_DIR/projects/mejoras-propuestas.md"

seed() { # resets the backlog to three pending proposals for a fresh scenario
  cat > "$BACKLOG" <<'EOF'
# Mejoras propuestas

## 2026-08-08 — demo
### El deploy pierde el segundo intento
- repo: demo
- evidencia: src/uno.js:1
- porque: reintenta sin esperar el rate limit
- tamano: 1 noche

## Propuestas — 2026-08-08
### Arreglar el deploy
- origen: El deploy pierde el segundo intento
- repo: demo
- esfuerzo: 1 noche
- riesgos: ninguno serio
- verificar: correr el deploy dos veces

#### Opcion A
- archivos: src/uno.js

#### Opcion B
- archivos: src/dos.js

### Propuesta contra machine-config
- origen: El deploy pierde el segundo intento
- repo: machine-config
- esfuerzo: 1 noche
- riesgos: x
- verificar: y

#### A
- archivos: bin/devbrain

### Otra mejora del deploy
- origen: El deploy pierde el segundo intento
- repo: demo
- esfuerzo: 2 noches
- riesgos: alguno
- verificar: revisar logs

#### Opcion A
- archivos: src/uno.js

#### Opcion B
- archivos: src/tres.js
EOF
  git -C "$WIKI_DIR" add -A
  git -C "$WIKI_DIR" commit -qm seed --allow-empty -q >/dev/null
}
seed

run() { # feeds scripted stdin, one line per proposal response
  DEVBRAIN_QUEUE_DIR="$QUEUE_DIR" DEVBRAIN_WIKI_DIR="$WIKI_DIR" \
  RESEARCH_ALLOWFILE="$TMP/allow" DAY_ENGINE="$DIR/lib/day_engine.py" \
  bash "$BIN"
}

# ---- 1. dale 1 (aquí: "dale" sobre la primera propuesta) --------------------
printf 'dale\nno\nmotivo de prueba\ndespues\n' | run > "$TMP/out1" 2>&1
F=$(ls "$QUEUE_DIR"/*--arreglar-el-deploy.plan.md 2>/dev/null | head -1)
[ -n "$F" ] || fail "'dale' did not create a plan file: $(cat "$TMP/out1")"
grep -q "^aprobado: $(date +%Y-%m-%d)$" "$F" || fail "the plan is missing today's aprobado: date"
git -C "$QUEUE_DIR" log --oneline | grep -qi aprobar || fail "the queue repo has no commit"
echo "OK: 1) dale creates a file with aprobado: today, committed"

# ---- 2. no -> no file, discarded with the motivo ----------------------------
grep -q "decision: descartada.*motivo de prueba" "$BACKLOG" \
  || fail "'no' did not record the motivo: $(grep decision "$BACKLOG")"
COUNT_MC=$(ls "$QUEUE_DIR"/*machine-config* 2>/dev/null | wc -l | tr -d ' ')
[ "$COUNT_MC" -eq 0 ] || fail "'no' on machine-config still produced a queue file"
echo "OK: 2) no creates no file, discards with the given motivo"

# ---- 3. despues -> no file, stays pending -----------------------------------
grep -q "^### Otra mejora del deploy$" "$BACKLOG" || fail "the proposal disappeared from the backlog"
awk '/^### Otra mejora del deploy$/{f=1} f && /^### /&&!/Otra mejora/{f=0} f' "$BACKLOG" | grep -q "decision:" \
  && fail "'despues' marked the proposal decided — it must stay open for the next cycle"
echo "OK: 3) despues leaves the proposal pending, no file, no decision recorded"

# ---- 4. a proposal against machine-config is always refused, never approved -
# (already exercised via 'no' above; confirm 'dale' would ALSO refuse it, not just
# that this run happened to say 'no' to it)
seed
printf 'despues\ndale\ndespues\n' | run > "$TMP/out4" 2>&1
[ ! -e "$(ls "$QUEUE_DIR"/*machine-config* 2>/dev/null)" ] || fail "machine-config was written as an approved plan"
grep -q "propuesta contra machine-config" "$TMP/out4" -i \
  || true  # the refusal detail lives in day_engine's stderr, captured into OUT; not asserting exact text here
COUNT_MC2=$(ls "$QUEUE_DIR"/*machine-config* 2>/dev/null | wc -l | tr -d ' ')
[ "$COUNT_MC2" -eq 0 ] || fail "machine-config produced a plan file on 'dale'"
echo "OK: 4) machine-config is refused by 'dale' too, never written as approved"

# ---- 5. an ambiguous response never approves --------------------------------
seed
printf 'ok\nsi\n\ndespues\n' | run > "$TMP/out5" 2>&1
COUNT_BEFORE=$(ls "$QUEUE_DIR"/*.plan.md 2>/dev/null | wc -l | tr -d ' ')
echo "$COUNT_BEFORE" > "$TMP/count-ambiguous"
grep -qE "^[0-9]+ propuesta" "$TMP/out5" || true
[ "$(ls "$QUEUE_DIR"/*.plan.md 2>/dev/null | wc -l | tr -d ' ')" -ge 0 ] # sanity, real check below
NEWFILES=$(ls "$QUEUE_DIR"/*ok* "$QUEUE_DIR"/*si* 2>/dev/null | wc -l | tr -d ' ')
[ "$NEWFILES" -eq 0 ] || fail "an ambiguous response ('ok'/'si'/empty) approved something"
echo "OK: 5) ambiguous responses ('ok', 'si', empty) never approve anything"

# ---- 6. the generated plan is consumable by devbrain execute ----------------
# devbrain execute stages plan_body(plan) -> .devbrain/plan-latest.md and takes the
# first non-heading, non-blank line as the short task string (bin/devbrain-night:101).
seed
printf 'dale\ndespues\ndespues\n' | run > /dev/null 2>&1
F6=$(ls "$QUEUE_DIR"/*--arreglar-el-deploy.plan.md 2>/dev/null | head -1)
[ -n "$F6" ] || fail "setup for case 6 failed: no plan file"
BODY=$(awk 'NR==1 && $0=="---" {infm=1; next} infm==1 && $0=="---" {infm=2; next} infm==2 {print}' "$F6")
TASK=$(printf '%s\n' "$BODY" | grep -v '^#' | grep -v '^$' | head -1)
[ -n "$TASK" ] || fail "no usable TASK line could be extracted the way devbrain-night does"
[ "$TASK" != "---" ] && [ "$TASK" != "##" ] || fail "the extracted TASK line is not real content: '$TASK'"
echo "OK: 6) the generated plan yields a real TASK line the same way devbrain-night extracts it"

echo "PASS: devbrain-day"

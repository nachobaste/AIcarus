#!/bin/bash
# tests/test-day-sh.sh — lib/day.sh: the one place that turns an engine decision into a
# written file and a git commit. Both bin/devbrain-day and the future Telegram approval
# (plan 250) call day_apply(); this suite is what proves they cannot diverge, because
# there is only one function here to diverge FROM.
set -uo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1"; exit 1; }

# ---- isolated queue + wiki repos, each its own git repo, like the real machine ---
QUEUE_DIR="$TMP/queue"; WIKI_DIR="$TMP/wiki"
mkdir -p "$QUEUE_DIR" "$WIKI_DIR/projects"
for d in "$QUEUE_DIR" "$WIKI_DIR"; do
  git -C "$d" init -q; git -C "$d" config user.email t@t.t; git -C "$d" config user.name t
done
# The allowfile lives inside a directory literally named "machine-config" —
# day_engine.py's self-repo refusal is structural (repo name == basename of the
# allowfile's own directory), not a hardcoded string, so the fixture has to look
# like a real devbrain checkout for this to exercise the same guardrail.
mkdir -p "$TMP/machine-config"
printf 'demo\n' > "$TMP/machine-config/allow"
BACKLOG="$WIKI_DIR/projects/mejoras-propuestas.md"
cat > "$BACKLOG" <<'EOF'
# Mejoras propuestas

## 2026-08-08 — demo
### El deploy pierde el segundo intento
- repo: demo
- evidencia: src/uno.js:1
- porque: reintenta sin esperar el rate limit
- tamano: 1 noche

## Propuestas — 2026-08-08
### Arreglar el reintento del deploy
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
EOF
git -C "$WIKI_DIR" add -A && git -C "$WIKI_DIR" commit -qm seed

export DEVBRAIN_QUEUE_DIR="$QUEUE_DIR" DEVBRAIN_WIKI_DIR="$WIKI_DIR" RESEARCH_ALLOWFILE="$TMP/machine-config/allow"
export DAY_ENGINE="$DIR/lib/day_engine.py"   # this worktree's engine, not the machine's real default
source "$DIR/lib/queue.sh"
source "$DIR/lib/day.sh"

# ---- dale: writes an approved plan file and marks the backlog ----------------
day_apply "Arreglar el reintento del deploy" dale > "$TMP/out1" 2>&1; RC=$?
[ "$RC" -eq 0 ] || fail "day_apply dale should succeed, got $RC: $(cat "$TMP/out1")"
F=$(ls "$QUEUE_DIR"/*--arreglar-el-reintento*.plan.md 2>/dev/null | head -1)
[ -n "$F" ] || fail "no plan file was written for the approved proposal"
[ "$(fm_get "$F" status)" = "approved" ] || fail "the written plan is not status: approved"
[ "$(fm_get "$F" aprobado)" = "$(date +%Y-%m-%d)" ] || fail "the written plan is missing today's aprobado: date"
[ "$(fm_get "$F" repo)" = "demo" ] || fail "the written plan has the wrong repo"
grep -q "src/uno.js" "$F" || fail "the plan body does not mention the chosen option's files"
echo "OK: dale writes an approved, dated plan file for the chosen option"

grep -q "decision: aprobada" "$BACKLOG" || fail "the backlog was not marked decided"
echo "OK: dale marks the proposal decided in the backlog"

git -C "$QUEUE_DIR" log --oneline -1 | grep -qi "day" || fail "the queue repo has no commit for the new plan"
git -C "$WIKI_DIR" log --oneline -1 | grep -qi "day\|decisi" || fail "the wiki repo has no commit for the decision"
echo "OK: both the queue and the wiki repos got their own commit"

# ---- a second dale on the same (now decided) title changes nothing ----------
BEFORE_FILES=$(ls "$QUEUE_DIR"/*.plan.md | wc -l | tr -d ' ')
day_apply "Arreglar el reintento del deploy" dale > /dev/null 2>&1; RC=$?
[ "$RC" -ne 0 ] || fail "re-applying dale to an already-decided proposal should fail"
AFTER_FILES=$(ls "$QUEUE_DIR"/*.plan.md | wc -l | tr -d ' ')
[ "$BEFORE_FILES" = "$AFTER_FILES" ] || fail "a duplicate plan file was written on the second dale"
echo "OK: an already-decided proposal cannot be approved a second time"

# ---- no: discards with a motivo, writes NOTHING to the queue ----------------
BEFORE_FILES=$(ls "$QUEUE_DIR"/*.plan.md | wc -l | tr -d ' ')
day_apply "Propuesta contra machine-config" no "no aplica, es infraestructura" > "$TMP/out2" 2>&1; RC=$?
[ "$RC" -eq 0 ] || fail "day_apply no should succeed, got $RC: $(cat "$TMP/out2")"
AFTER_FILES=$(ls "$QUEUE_DIR"/*.plan.md | wc -l | tr -d ' ')
[ "$BEFORE_FILES" = "$AFTER_FILES" ] || fail "'no' wrote a plan file — it must never write to the queue"
grep -q "no aplica, es infraestructura" "$BACKLOG" || fail "the discard motivo was not recorded"
echo "OK: 'no' discards with its motivo and writes nothing to the queue"

# ---- the machine-config guardrail holds even through this wrapper ----------
# (already exercised above via 'no', since day_engine would refuse 'dale' on it —
# confirm that refusal explicitly, not just infer it from the 'no' path above)
cat >> "$BACKLOG" <<'EOF'

### Otra contra machine-config
- origen: El deploy pierde el segundo intento
- repo: machine-config
- esfuerzo: 1 noche
- riesgos: x
- verificar: y

#### A
- archivos: bin/devbrain
EOF
git -C "$WIKI_DIR" add -A && git -C "$WIKI_DIR" commit -qm "seed 2"
BEFORE_FILES=$(ls "$QUEUE_DIR"/*.plan.md | wc -l | tr -d ' ')
day_apply "Otra contra machine-config" dale > "$TMP/out3" 2>&1; RC=$?
[ "$RC" -ne 0 ] || fail "day_apply dale against machine-config must be refused"
AFTER_FILES=$(ls "$QUEUE_DIR"/*.plan.md | wc -l | tr -d ' ')
[ "$BEFORE_FILES" = "$AFTER_FILES" ] || fail "a machine-config plan file was written despite the refusal"
grep -q "decision:" "$(grep -B2 "^### Otra contra machine-config$" "$BACKLOG" >/dev/null; echo "$BACKLOG")" 2>/dev/null
awk '/^### Otra contra machine-config$/{f=1} f && /^### /&&!/Otra contra/{f=0} f' "$BACKLOG" | grep -q "decision:" \
  && fail "a refused proposal was marked decided anyway — it must stay pending for the next cycle"
echo "OK: machine-config is refused through the shared wrapper too, and stays pending"

# ---- dale with an explicit option letter chooses that option, not the default ----
cat >> "$BACKLOG" <<'EOF'

## Propuestas — 2026-08-08b
### Elegir opcion B
- origen: El deploy pierde el segundo intento
- repo: demo
- esfuerzo: 1 noche
- riesgos: x
- verificar: y

#### Opcion A
- archivos: src/uno.js

#### Opcion B
- archivos: src/dos.js
EOF
git -C "$WIKI_DIR" add -A && git -C "$WIKI_DIR" commit -qm "seed 3"
day_apply "Elegir opcion B" dale "" B > "$TMP/out4" 2>&1; RC=$?
[ "$RC" -eq 0 ] || fail "day_apply dale with an explicit option should succeed, got $RC: $(cat "$TMP/out4")"
F2=$(ls "$QUEUE_DIR"/*--elegir-opcion-b.plan.md 2>/dev/null | head -1)
[ -n "$F2" ] || fail "no plan file was written for the explicit-option approval"
grep -q "src/dos.js" "$F2" || fail "option B's files are missing from the plan body"
grep -q "src/uno.js" "$F2" && fail "option A's files leaked in when B was explicitly chosen"
echo "OK: day_apply honours an explicit option letter, not just the default"

echo "PASS: day-sh"

#!/bin/bash
# tests/test-devbrain-queue-dale.sh — devbrain-queue dale|no <n>, the command the
# messaging assistant invokes when the owner replies to the digest from Telegram
# (plan 250).
#
# What this suite can and cannot prove: it proves devbrain-queue's OWN argument
# parsing is strict and that it calls the exact same day_apply used by the Mac
# (bin/devbrain-day) — zero duplicated approval logic, per the plan. It canNOT
# exercise the gateway's natural-language routing (there is no local stub for
# "the model decided to run this") — that is a live system, verified once by an
# actual Telegram message after this merges, not by an automated test here.
#
# The chat-ID barrier the plan originally asked for lives one layer up, in the
# gateway's own config (channels.telegram.dmPolicy=allowlist, allowFrom the
# owner's single chat ID) — verified by reading that config, not re-implemented
# here: `exec` hands devbrain-queue nothing but the command string, so there is
# no sender identity left to re-check at this layer.
set -uo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$DIR/bin/devbrain-queue"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1"; exit 1; }

QUEUE_DIR="$TMP/queue"; WIKI_DIR="$TMP/wiki"
mkdir -p "$QUEUE_DIR" "$WIKI_DIR/projects"
for d in "$QUEUE_DIR" "$WIKI_DIR"; do
  git -C "$d" init -q; git -C "$d" config user.email t@t.t; git -C "$d" config user.name t
done
printf 'demo\n' > "$TMP/allow"
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
### Primera propuesta
- origen: El deploy pierde el segundo intento
- repo: demo
- esfuerzo: 1 noche
- riesgos: x
- verificar: y

#### Opcion A
- archivos: src/uno.js

#### Opcion B
- archivos: src/dos.js

### Segunda propuesta
- origen: El deploy pierde el segundo intento
- repo: machine-config
- esfuerzo: 1 noche
- riesgos: x
- verificar: y

#### A
- archivos: bin/devbrain
EOF
git -C "$WIKI_DIR" add -A && git -C "$WIKI_DIR" commit -qm seed

run() {
  DEVBRAIN_QUEUE_DIR="$QUEUE_DIR" DEVBRAIN_WIKI_DIR="$WIKI_DIR" \
  RESEARCH_ALLOWFILE="$TMP/allow" DAY_ENGINE="$DIR/lib/day_engine.py" \
  "$BIN" "$@"
}

# ---- dale <n> resolves against the CURRENT pending order, live -------------
run dale 1 > "$TMP/out1" 2>&1; RC=$?
[ "$RC" -eq 0 ] || fail "dale 1 should succeed, got $RC: $(cat "$TMP/out1")"
F=$(ls "$QUEUE_DIR"/*--primera-propuesta.plan.md 2>/dev/null | head -1)
[ -n "$F" ] || fail "dale 1 did not approve the first pending proposal"
grep -q "^aprobado: $(date +%Y-%m-%d)$" "$F" || fail "the approved plan is missing today's date"
echo "OK: dale <n> resolves against the live pending order and writes an approved plan"

# the confirmation the assistant relays back to Telegram is exactly this command's stdout —
# no separate notification plumbing to build or test.
grep -qi "aprobado" "$TMP/out1" || fail "no confirmation was printed for the assistant to relay"
echo "OK: the confirmation is plain stdout, ready to relay as-is"

# ---- dale on a repo outside the allowlist (here: machine-config) is refused -
run dale 1 > "$TMP/out2" 2>&1; RC=$?
[ "$RC" -ne 0 ] || fail "dale 1 on the now-only-remaining (machine-config) proposal must be refused"
COUNT_MC=$(ls "$QUEUE_DIR"/*machine-config* 2>/dev/null | wc -l | tr -d ' ')
[ "$COUNT_MC" -eq 0 ] || fail "a machine-config plan was written via Telegram's dale"
echo "OK: dale refuses a disallowed repo exactly like the Mac path does"

# ---- no <n> "<motivo>" discards and requires a reason -----------------------
cat >> "$BACKLOG" <<'EOF'

## Propuestas — 2026-08-08b
### Tercera propuesta
- origen: El deploy pierde el segundo intento
- repo: demo
- esfuerzo: 1 noche
- riesgos: x
- verificar: y

#### A
- archivos: src/uno.js

#### B
- archivos: src/dos.js
EOF
git -C "$WIKI_DIR" add -A && git -C "$WIKI_DIR" commit -qm "seed 2"

run no 1 > "$TMP/out3" 2>&1; RC=$?
[ "$RC" -ne 0 ] || fail "'no' with no motivo should be refused, not silently discarded"
grep -A6 "^### Tercera propuesta$" "$BACKLOG" | grep -q "decision:" \
  && fail "'no' without a motivo still marked the proposal decided"
echo "OK: 'no' without a motivo is refused, the proposal stays pending"

run no 1 "no aplica a este ciclo" > "$TMP/out4" 2>&1; RC=$?
[ "$RC" -eq 0 ] || fail "'no' with a motivo should succeed, got $RC: $(cat "$TMP/out4")"
grep -q "decision: descartada.*no aplica a este ciclo" "$BACKLOG" || fail "the motivo was not recorded"
COUNT_FILES=$(ls "$QUEUE_DIR"/*.plan.md 2>/dev/null | wc -l | tr -d ' ')
[ "$COUNT_FILES" -eq 1 ] || fail "'no' wrote a queue file (should only ever be 1, from the earlier dale)"
echo "OK: no <n> \"<motivo>\" discards and records the reason, writes nothing to the queue"

# ---- malformed input never approves or discards anything -------------------
BEFORE=$(ls "$QUEUE_DIR"/*.plan.md 2>/dev/null | wc -l | tr -d ' ')
for BAD in "dale" "dale abc" "dale -1" "dale 0" "no" "no abc motivo"; do
  run $BAD > /dev/null 2>&1 && fail "malformed input '$BAD' was accepted"
done
AFTER=$(ls "$QUEUE_DIR"/*.plan.md 2>/dev/null | wc -l | tr -d ' ')
[ "$BEFORE" = "$AFTER" ] || fail "malformed input changed the queue"
echo "OK: malformed dale/no input is rejected outright, nothing is written"

# ---- an out-of-range n is refused, not silently ignored ---------------------
run dale 99 > "$TMP/out5" 2>&1; RC=$?
[ "$RC" -ne 0 ] || fail "dale on an out-of-range n should fail"
grep -qi "no hay" "$TMP/out5" || fail "the out-of-range error should be legible to relay back"
echo "OK: an out-of-range proposal number is refused with a legible error"

echo "PASS: devbrain-queue-dale"

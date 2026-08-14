#!/bin/bash
# tests/test-lib.sh — exercises lib/queue.sh and with_timeout
set -uo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
source "$DIR/lib/queue.sh"

# fm_get / fm_set
cat > "$TMP/p.plan.md" <<'EOF'
---
repo: repoa
status: approved
---
body here
EOF
[ "$(fm_get "$TMP/p.plan.md" status)" = "approved" ] && echo "OK: fm_get reads" || exit 1
fm_set "$TMP/p.plan.md" status running
[ "$(fm_get "$TMP/p.plan.md" status)" = "running" ] && echo "OK: fm_set replaces" || exit 1
fm_set "$TMP/p.plan.md" pr "https://x/1"
[ "$(fm_get "$TMP/p.plan.md" pr)" = "https://x/1" ] && echo "OK: fm_set adds new key" || exit 1
grep -q "body here" "$TMP/p.plan.md" && echo "OK: body untouched" || exit 1

# with_timeout
with_timeout 5 true && echo "OK: with_timeout passes rc 0" || exit 1
with_timeout 1 sleep 10; [ $? -eq 124 ] && echo "OK: with_timeout kills at deadline" || exit 1
echo "hola" | with_timeout 5 cat | grep -q hola && echo "OK: stdin passes through" || exit 1

# capture must return as soon as cmd exits, NOT wait for the watchdog's sleep
# (an orphaned watchdog sleep inheriting the capture pipe caused a 45-minute
# deadlock in production once already)
START=$SECONDS
OUTC=$(with_timeout 60 echo rapido)
ELAPSED=$((SECONDS - START))
[ "$OUTC" = "rapido" ] && [ "$ELAPSED" -lt 5 ] && echo "OK: \$() capture returns immediately (${ELAPSED}s)" || { echo "FAIL: capture blocked ${ELAPSED}s"; exit 1; }
# and no orphaned watchdog sleep may survive the call
pgrep -f "sleep 60" >/dev/null && ps -o ppid= -p $(pgrep -f "sleep 60" | head -1) | grep -qx " *1" && { echo "FAIL: orphan sleep leaked"; exit 1; }
echo "OK: no orphan sleep holding pipes"

# Regression for a real production bug: a fast command must kill
# its OWN watchdog sleep on early exit. Use a distinctive, unlikely-to-collide
# duration (137) — if the old code (kill on the wrapper subshell, not the sleep
# itself) were reinstated, this sleep would survive and outlive the test,
# eventually firing a stale kill at a recycled PID (that's what killed two real
# devbrain execute sessions with SIGTERM minutes after they'd already finished).
with_timeout 137 true
sleep 0.3
pgrep -f "sleep 137" >/dev/null && { echo "FAIL: watchdog sleep 137 survived early completion (will fire a stale kill later)"; pkill -f "sleep 137"; exit 1; }
echo "OK: watchdog sleep is killed immediately on early completion, no delayed-kill bomb left ticking"

# tg_send is a guarded no-op under DEVBRAIN_NO_TG (tests must never alert the owner)
export DEVBRAIN_NO_TG=1
source "$DIR/lib/telegram.sh"
tg_send "esto jamás debe llegar a Telegram" && echo "OK: tg_send no-op under DEVBRAIN_NO_TG" || exit 1
echo "ALL OK"

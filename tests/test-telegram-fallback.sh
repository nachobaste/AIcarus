#!/bin/bash
# tests/test-telegram-fallback.sh — lib/telegram.sh's honest-delivery send and the
# gateway-down fallback (plan 260).
#
# tg_send() (already in this file) always returns 0, by design — it is for best-effort
# alerts where losing one silently is acceptable. The digest and wiki-lint's weekly
# summary are different: their entire job IS delivering that one message, so a caller
# that needs to know "did THIS attempt actually work" needs an honest return code.
# That is tg_send_checked(); tg_send_with_fallback() is what wires "try the gateway,
# fall back to curl, tag the fallback, log both paths" once, so devbrain-digest and
# devbrain-wiki-lint share it instead of each re-implementing the same three rules.
#
# Every external call here is stubbed via an explicit override (TELEGRAM_CURL_BIN, and
# the openclaw binary is passed as a plain argument) — never via a PATH trick. See the
# 2026-08-08 near miss in tests/test-devbrain-digest-proposals.sh for why: this machine's
# `export PATH=...` habit silently defeats PATH-prepend stubbing and sent a live digest
# during testing that same day.
set -uo pipefail
export DEVBRAIN_NO_TG=1   # the repo-wide default; overridden explicitly below where needed
DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1"; exit 1; }

# A fake openclaw.json with a harmless fake token, so tg_send_checked has something to
# read without touching the real one.
mkdir -p "$TMP/.openclaw"
cat > "$TMP/.openclaw/openclaw.json" <<'EOF'
{"channels": {"telegram": {"botToken": "FAKE-TOKEN-NEVER-REAL"}}}
EOF

export CALLS="$TMP/curl-calls.log"
cat > "$TMP/fake-curl-ok" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" >> "$CALLS"
echo "---call---" >> "$CALLS"
echo '{"ok":true,"result":{"message_id":1}}'
EOF
cat > "$TMP/fake-curl-fail" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" >> "$CALLS"
echo "---call---" >> "$CALLS"
echo '{"ok":false,"description":"Forbidden: bot was blocked"}'
EOF
chmod +x "$TMP/fake-curl-ok" "$TMP/fake-curl-fail"

cat > "$TMP/fake-openclaw-ok" <<'EOF'
#!/bin/bash
exit 0
EOF
cat > "$TMP/fake-openclaw-down" <<'EOF'
#!/bin/bash
echo "connection refused" >&2
exit 1
EOF
chmod +x "$TMP/fake-openclaw-ok" "$TMP/fake-openclaw-down"

# Point tg_send_checked at the fake HOME so it reads the fake token, never the real one.
export HOME="$TMP"
export DEVBRAIN_NO_TG=0   # deliberate: this is the ONE file that must exercise real logic —
                          # safety comes from stubbing curl below, not from this flag.
export TELEGRAM_CURL_BIN="$TMP/fake-curl-ok"
# Required, no hardcoded default (a real chat id baked in would message someone
# else's Telegram account from every clone of this repo) — a fake numeric id
# here is enough to exercise the real send logic against the stubbed curl.
export DEVBRAIN_TG_CHAT_ID="123456789"
source "$DIR/lib/telegram.sh"

# ---- tg_send_checked: honest success -----------------------------------------
tg_send_checked "hola" >/dev/null 2>&1; RC=$?
[ "$RC" -eq 0 ] || fail "tg_send_checked should report success when Telegram confirms, got $RC"
grep -q "fake-curl-ok\|sendMessage" "$CALLS" || true
[ -s "$CALLS" ] || fail "tg_send_checked never actually called the (stubbed) curl"
echo "OK: tg_send_checked reports success on confirmed delivery"

# ---- tg_send_checked: honest failure, unlike tg_send ---------------------------
: > "$CALLS"
export TELEGRAM_CURL_BIN="$TMP/fake-curl-fail"
tg_send_checked "hola" >/dev/null 2>&1; RC=$?
[ "$RC" -ne 0 ] || fail "tg_send_checked should report failure when Telegram does not confirm"
echo "OK: tg_send_checked reports failure honestly, unlike tg_send's unconditional success"

# ---- tg_send_with_fallback: gateway healthy -> no curl call at all -------------
: > "$CALLS"
export TELEGRAM_CURL_BIN="$TMP/fake-curl-ok"   # would succeed if called — must NOT be needed
LOG="$TMP/log1"
tg_send_with_fallback "$TMP/fake-openclaw-ok" "mensaje normal" "$LOG" >/dev/null 2>&1; RC=$?
[ "$RC" -eq 0 ] || fail "tg_send_with_fallback should succeed when the gateway is healthy"
[ ! -s "$CALLS" ] || fail "curl was called even though the gateway succeeded — extra API traffic"
grep -qi "bridge" "$LOG" || fail "the log does not record the bridge attempt"
echo "OK: a healthy gateway sends once, never touches curl"

# ---- tg_send_with_fallback: gateway down -> curl fallback delivers, tagged ----
: > "$CALLS"
LOG="$TMP/log2"
tg_send_with_fallback "$TMP/fake-openclaw-down" "el mensaje real del digest" "$LOG" >/dev/null 2>&1; RC=$?
[ "$RC" -eq 0 ] || fail "tg_send_with_fallback should succeed via the curl fallback"
[ -s "$CALLS" ] || fail "the fallback never reached curl when the gateway was down"
# The text= argument itself contains embedded newlines (the fallback tag + blank
# line + original message), so it spans multiple lines in the log — grab everything
# from 'text=' up to the next call marker, not just its first line.
LAST_TEXT="$(awk '/^text=/{f=1} f{print} /^---call---$/{f=0}' "$CALLS" | tail -n +1)"
printf '%s' "$LAST_TEXT" | grep -qi "respaldo\|fallback" \
  || fail "the delivered message does not say it went out via the fallback"
printf '%s' "$LAST_TEXT" | grep -q "el mensaje real del digest" \
  || fail "the original message content was lost in the fallback"
grep -qi "bridge failed\|falló" "$LOG" || fail "the log does not record the bridge failure"
grep -qi "curl" "$LOG" || fail "the log does not record the curl fallback attempt"
echo "OK: a down gateway falls back to curl, tags the message, and logs both attempts"

# ---- tg_send_with_fallback: BOTH paths fail -> honest failure, still logged ---
: > "$CALLS"
export TELEGRAM_CURL_BIN="$TMP/fake-curl-fail"
LOG="$TMP/log3"
tg_send_with_fallback "$TMP/fake-openclaw-down" "mensaje que se va a perder" "$LOG" >/dev/null 2>&1; RC=$?
[ "$RC" -ne 0 ] || fail "tg_send_with_fallback must report failure when NEITHER path delivered"
grep -qi "also failed\|did not arrive\|también falló\|no llegó" "$LOG" \
  || fail "a total delivery failure must be loud in the log, not indistinguishable from success"
echo "OK: when both paths fail, it says so honestly instead of pretending to succeed"

echo "PASS: telegram-fallback"

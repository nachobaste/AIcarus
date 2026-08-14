#!/bin/bash
# lib/telegram.sh — direct Telegram send (curl to the API, independent of OpenClaw
# or whichever messaging bridge you use). Silent no-op when: interactive (a human
# sees the terminal), DEVBRAIN_NO_TG=1 (tests), or no token/chat id is configured.
#
# DEVBRAIN_TG_CHAT_ID is REQUIRED (your own numeric Telegram user/chat id — get it
# from @userinfobot or similar). There is deliberately NO hardcoded default here:
# baking in a real chat id would mean every clone of this starter kit silently
# messages someone else's Telegram account. If it's unset, sends are skipped and
# tg_send_checked/tg_send_with_fallback report the missing configuration instead of
# silently doing nothing.
TG_ID="${DEVBRAIN_TG_CHAT_ID:-}"
# Overridable so tests never touch the real network — a `PATH` habit elsewhere on
# the machine can defeat a PATH-prepend stub and send a live Telegram message
# mid-test if this isn't respected.
TELEGRAM_CURL_BIN="${TELEGRAM_CURL_BIN:-curl}"

tg_send() {
  [ "${DEVBRAIN_NO_TG:-0}" = "1" ] && return 0
  [ -t 1 ] && return 0
  [ -z "$TG_ID" ] && return 0
  local tok
  tok=$(python3 -c "import json;print(json.load(open('$HOME/.openclaw/openclaw.json')).get('channels',{}).get('telegram',{}).get('botToken',''))" 2>/dev/null)
  [ -z "$tok" ] && return 0
  curl -s -m 10 "https://api.telegram.org/bot${tok}/sendMessage" \
    --data-urlencode "chat_id=${TG_ID}" --data-urlencode "text=$1" >/dev/null 2>&1 || true
}

# tg_send_checked <text> -> direct curl send, HONEST return code (0 = Telegram's API
# confirmed delivery, 1 = it did not). Distinct from tg_send() above, which always
# returns 0 by design: that one is for best-effort alerts where losing one silently is
# fine. A caller whose entire job IS delivering one message (the digest, the weekly
# summary) needs to know whether THIS attempt actually worked, not just that curl ran.
tg_send_checked() {
  if [ -z "$TG_ID" ]; then
    echo "tg_send_checked: DEVBRAIN_TG_CHAT_ID is not set" >&2
    return 1
  fi
  local tok resp
  tok=$(python3 -c "import json;print(json.load(open('$HOME/.openclaw/openclaw.json')).get('channels',{}).get('telegram',{}).get('botToken',''))" 2>/dev/null)
  if [ -z "$tok" ]; then
    echo "tg_send_checked: no bot token in openclaw.json" >&2
    return 1
  fi
  resp="$("$TELEGRAM_CURL_BIN" -s -m 10 "https://api.telegram.org/bot${tok}/sendMessage" \
    --data-urlencode "chat_id=${TG_ID}" --data-urlencode "text=$1" 2>&1)"
  if printf '%s' "$resp" | grep -q '"ok":true'; then
    return 0
  fi
  echo "tg_send_checked: Telegram did not confirm delivery: $resp" >&2
  return 1
}

# tg_send_with_fallback <bridge_bin> <message> <log_file> -> tries the messaging
# bridge first (fast path, no extra API call in the normal case), and only falls
# back to curl if that fails. The fallback message is marked as such — a silent
# bridge outage is worse than a visible one (see docs/wiki-example/lessons for the
# general shape of that lesson). Returns 0 only if SOME path actually delivered.
tg_send_with_fallback() {
  local bridge_bin="$1" mensaje="$2" log="${3:-/dev/null}"
  if [ -z "$TG_ID" ]; then
    echo "[$(date)] tg_send_with_fallback: DEVBRAIN_TG_CHAT_ID not set, skipping" >>"$log"
    return 1
  fi
  if "$bridge_bin" message send --channel telegram --target "$TG_ID" --message "$mensaje" >>"$log" 2>&1; then
    echo "[$(date)] tg_send_with_fallback: sent via bridge" >>"$log"
    return 0
  fi
  echo "[$(date)] tg_send_with_fallback: bridge failed, retrying via direct curl" >>"$log"
  if tg_send_checked "⚠️ (sent via fallback — the messaging bridge did not respond)

$mensaje"; then
    echo "[$(date)] tg_send_with_fallback: curl fallback OK" >>"$log"
    return 0
  fi
  echo "[$(date)] tg_send_with_fallback: curl fallback ALSO failed — message did not arrive" >>"$log"
  return 1
}

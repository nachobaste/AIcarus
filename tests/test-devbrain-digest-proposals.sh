#!/bin/bash
# tests/test-devbrain-digest-proposals.sh — the digest's proposals section (plan 230).
#
# devbrain-digest hardcodes `export PATH=...` near the top, which defeats a
# PATH-prepend stubbing trick outright — a near miss on 2026-08-08 sent a live
# Telegram digest during testing because of exactly this. So every external tool
# is stubbed here through its DEVBRAIN_DIGEST_*_BIN override, never through PATH.
#
# The one property that matters more than any other: the numbering must survive
# EXACTLY, because plan 250 lets the owner reply "dale 2" from Telegram. The fake
# summarizer below OBVIOUSLY reworks anything it receives (it counts lines instead
# of echoing them), so if the numbering ever got fed through it, the corruption
# would be visible in the sent message.
set -uo pipefail
export DEVBRAIN_NO_TG=1
DIR="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$DIR/bin/devbrain-digest"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1"; exit 1; }

mkdir -p "$TMP/projects" "$TMP/wiki/status" "$TMP/wiki/projects" "$TMP/queue"

cat > "$TMP/fake-gh" <<'EOF'
#!/bin/bash
exit 0
EOF
# Deliberately mangles its input, so if the proposals text ever reached this, the
# test below that checks for un-mangled numbering would catch it.
cat > "$TMP/fake-claude" <<'EOF'
#!/bin/bash
IN="$(cat)"
echo "AI-SUMMARY: $(printf '%s' "$IN" | wc -l | tr -d ' ') lines of context received"
EOF
SENT="$TMP/sent-message.txt"
cat > "$TMP/fake-openclaw" <<EOF
#!/bin/bash
if [ "\$1" = "message" ]; then
  shift 2
  while [ \$# -gt 0 ]; do
    if [ "\$1" = "--message" ]; then echo "\$2" > "$SENT"; fi
    shift
  done
fi
exit 0
EOF
cat > "$TMP/fake-gog" <<'EOF'
#!/bin/bash
exit 1
EOF
cat > "$TMP/fake-personal-digest" <<'EOF'
#!/bin/bash
exit 0
EOF
# The gateway-down scenario for plan 260: openclaw fails, and a "never call me" curl
# guard makes the healthy-path tests fail loudly if the fallback ever fires when it
# should not have.
cat > "$TMP/fake-openclaw-down" <<'EOF'
#!/bin/bash
echo "connection refused" >&2
exit 1
EOF
cat > "$TMP/fake-curl-never" <<'EOF'
#!/bin/bash
echo "FAKE-CURL-NEVER was invoked — the fallback fired when the gateway was healthy" >&2
exit 1
EOF
mkdir -p "$TMP/curl-home/.openclaw"
cat > "$TMP/curl-home/.openclaw/openclaw.json" <<'EOF'
{"channels": {"telegram": {"botToken": "FAKE-TOKEN-NEVER-REAL"}}}
EOF
CURL_CALLS="$TMP/curl-calls.log"
export CURL_CALLS
cat > "$TMP/fake-curl-ok" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" >> "$CURL_CALLS"
echo "---call---" >> "$CURL_CALLS"
echo '{"ok":true,"result":{"message_id":1}}'
EOF
chmod +x "$TMP/fake-gh" "$TMP/fake-claude" "$TMP/fake-openclaw" "$TMP/fake-gog" \
  "$TMP/fake-personal-digest" "$TMP/fake-openclaw-down" "$TMP/fake-curl-never" "$TMP/fake-curl-ok"

run_digest() {
  DEVBRAIN_PROJECTS_DIR="$TMP/projects" DEVBRAIN_WIKI_DIR="$TMP/wiki" \
  DEVBRAIN_QUEUE_DIR="$TMP/queue" DEVBRAIN_DIGEST_LOG="$TMP/digest.log" \
  DEVBRAIN_DIGEST_GH_BIN="$TMP/fake-gh" DEVBRAIN_DIGEST_CLAUDE_BIN="$TMP/fake-claude" \
  DEVBRAIN_DIGEST_OPENCLAW_BIN="${OPENCLAW_STUB:-$TMP/fake-openclaw}" \
  DEVBRAIN_DIGEST_GOG_BIN="$TMP/fake-gog" \
  DEVBRAIN_PERSONAL_DIGEST_BIN="$TMP/fake-personal-digest" \
  TELEGRAM_CURL_BIN="${TELEGRAM_CURL_BIN:-$TMP/fake-curl-never}" \
  DEVBRAIN_TG_CHAT_ID="123456789" \
  HOME="${TELEGRAM_HOME:-$TMP/no-home}" DEVBRAIN_NO_TG="${DEVBRAIN_NO_TG:-1}" \
  bash "$BIN"
}

BACKLOG="$TMP/wiki/projects/mejoras-propuestas.md"

# ---- 0. every external call really is stubbed, before anything else matters --
# If this fails, every assertion below could be exercising the real tools instead
# of the fakes — exactly the near-miss this suite exists to prevent.
run_digest >/dev/null 2>&1
grep -q "digest sent" "$TMP/digest.log" 2>/dev/null || fail "the digest did not complete (real tools may have been reached)"
[ -f "$SENT" ] || fail "the fake openclaw never recorded a sent message — stubbing is not working"
echo "OK: every external tool is stubbed, none of the real ones were reached"

# ---- 1. no backlog file at all: digest still runs, no proposals section -----
grep -q "Proposals" "$SENT" && fail "a proposals header appeared with no backlog file"
echo "OK: no backlog file means no proposals section, no crash"

# ---- 2. a pending proposal reaches the message, numbered, unmodified --------
cat > "$BACKLOG" <<'EOF'
# Proposed improvements

## 2026-08-08 — demo
### The deploy loses its second attempt
- repo: demo
- evidence: src/one.js:1
- why: it retries without waiting out the rate limit
- size: 1 night

## Proposals — 2026-08-08
### Fix the deploy retry
- source: The deploy loses its second attempt
- repo: demo
- effort: 1 night
- risks: nothing serious
- verify: run the deploy twice in a row

#### Option A
- files: src/one.js

#### Option B
- files: src/two.js
EOF
rm -f "$SENT"
run_digest >/dev/null 2>&1
[ -f "$SENT" ] || fail "no message was sent with a pending proposal"
grep -q "^1\. Fix the deploy retry$" "$SENT" \
  || fail "the numbered title did not survive intact: $(cat "$SENT")"
grep -q "AI-SUMMARY:.*1\. Fix" "$SENT" \
  && fail "the numbering was fed through the AI summarizer and came back reworded"
echo "OK: a pending proposal reaches the owner numbered and untouched by the summarizer"

# ---- 3. the proposals block sits AFTER the AI summary, not instead of it ----
grep -q "AI-SUMMARY:" "$SENT" || fail "the AI-generated summary is missing from the message"
AI_LINE=$(grep -n "AI-SUMMARY:" "$SENT" | head -1 | cut -d: -f1)
PROP_LINE=$(grep -n "^1\. " "$SENT" | head -1 | cut -d: -f1)
[ "$AI_LINE" -lt "$PROP_LINE" ] || fail "the proposals block does not come after the AI summary"
echo "OK: the proposals block is appended after the AI summary"

# ---- 4. a decided proposal (plan 240/250's future contract) is not repeated -
cat >> "$BACKLOG" <<'EOF'

## Proposals — 2026-08-07
### Already decided yesterday
- source: The deploy loses its second attempt
- repo: demo
- effort: 1 night
- risks: x
- decision: approved

#### A
- files: src/one.js

#### B
- files: src/two.js
EOF
rm -f "$SENT"
run_digest >/dev/null 2>&1
grep -q "Already decided yesterday" "$SENT" && fail "an already-decided proposal was shown again"
echo "OK: an already-decided proposal never reappears in the digest"

# ---- 5. gateway down -> the digest STILL arrives, via curl, tagged (plan 260) ----
# The one test the plan says matters most: bring the gateway down on purpose, run the
# digest, confirm delivery via curl and that the message says it used the fallback.
: > "$CURL_CALLS"
OPENCLAW_STUB="$TMP/fake-openclaw-down" TELEGRAM_CURL_BIN="$TMP/fake-curl-ok" \
  TELEGRAM_HOME="$TMP/curl-home" run_digest > "$TMP/digest-stdout" 2>&1
[ -s "$CURL_CALLS" ] || fail "the gateway was down and curl was never reached — the digest was lost"
DELIVERED="$(awk '/^text=/{f=1} f{print} /^---call---$/{f=0}' "$CURL_CALLS")"
[ -n "$DELIVERED" ] || fail "curl was called but no text= payload was captured"
printf '%s' "$DELIVERED" | grep -qi "fallback" \
  || fail "the message delivered via the fallback does not say it is a fallback"
grep -qi "bridge" "$TMP/digest.log" && grep -qi "curl" "$TMP/digest.log" \
  || fail "the digest log does not record both the failed and the fallback attempt"
echo "OK: with the gateway down, the digest still arrives via curl, tagged as a fallback"

# ---- 6. gateway healthy -> never touches curl, never sends twice ----------------
# The pair to case 5: this must keep passing, or the fallback is firing on every run.
: > "$CURL_CALLS"
rm -f "$SENT"
run_digest > /dev/null 2>&1   # default stubs: healthy openclaw, fake-curl-never guard
[ -f "$SENT" ] || fail "a healthy gateway did not deliver the digest at all"
[ ! -s "$CURL_CALLS" ] || fail "curl was reached even though the gateway was healthy"
echo "OK: a healthy gateway never falls back and never double-sends"

# ---- 7. blocked tasks surface as a pending decision (plan 290, D5) ----------
mkdir -p "$TMP/queue"
cat > "$TMP/queue/50-repoa--something.plan.md" <<'EOF'
---
repo: repoa
status: blocked
prioridad: 50
creado: 2026-08-08
bloqueado_por: deno lint
---
plan body
EOF
rm -f "$SENT"
run_digest > /dev/null 2>&1
[ -f "$SENT" ] || fail "no message was sent with a blocked task pending"
grep -q "50-repoa--something.plan.md" "$SENT" || fail "the blocked plan's filename is missing from the digest"
grep -q "deno lint" "$SENT" || fail "the exact missing command is missing from the digest"
echo "OK: a blocked task surfaces in the digest with its exact missing command"

# a plan that is merely approved/done/failed must NOT appear in the blocked section
cat > "$TMP/queue/51-repoa--other.plan.md" <<'EOF'
---
repo: repoa
status: done
prioridad: 51
creado: 2026-08-08
---
body
EOF
rm -f "$SENT"
run_digest > /dev/null 2>&1
grep -q "51-repoa--other" "$SENT" && fail "a non-blocked plan appeared in the blocked-tasks digest section"
echo "OK: only genuinely blocked plans appear in that section"
rm -f "$TMP/queue"/*.plan.md

# ---- 8. blocked tasks carry age (mtime proxy, honestly labeled) and escalate
# once stale (2026-08-12). There is no "since blocked" field in the frontmatter
# (bin/devbrain-night only writes status + bloqueado_por) — the file's own last-
# modified time is the proxy, which is why the digest says "per last modification"
# instead of claiming a confirmed block date.
FRESH_BLOCKED="$TMP/queue/60-repoa--fresh.plan.md"
STALE_BLOCKED="$TMP/queue/61-repoa--old.plan.md"
cat > "$FRESH_BLOCKED" <<'EOF'
---
repo: repoa
status: blocked
prioridad: 60
creado: 2026-08-11
bloqueado_por: missing permission A
---
body
EOF
cat > "$STALE_BLOCKED" <<'EOF'
---
repo: repoa
status: blocked
prioridad: 61
creado: 2026-07-29
bloqueado_por: missing permission B
---
body
EOF
touch -t "$(date -v-10d +%Y%m%d0000 2>/dev/null || date -d '-10 days' +%Y%m%d0000)" "$STALE_BLOCKED"
rm -f "$SENT"
run_digest > /dev/null 2>&1
[ -f "$SENT" ] || fail "no message was sent with blocked tasks pending"
grep -q -- "- 60-repoa--fresh.plan.md.*missing permission A" "$SENT" \
  || fail "a freshly-blocked task should show a plain bullet, no escalation: $(cat "$SENT")"
grep -q -- "per last modification" "$SENT" \
  || fail "the age must be labeled as a proxy (last modified), never presented as a confirmed block date"
grep -q -- "⚠️ 61-repoa--old.plan.md.*missing permission B" "$SENT" \
  || fail "a task blocked ~10 days ago (past the default 3-day threshold) must show the ⚠️ marker: $(cat "$SENT")"
echo "OK: blocked tasks show their age (labeled as a proxy) and escalate visually once stale"

# ---- 9. DEVBRAIN_DIGEST_STALE_DAYS is overridable, same knob as Proposals ----
rm -f "$SENT"
DEVBRAIN_DIGEST_STALE_DAYS=100 run_digest > /dev/null 2>&1
grep -q "⚠️" "$SENT" && fail "raising the threshold to 100 must suppress escalation for a ~10-day-old block"
grep -q -- "61-repoa--old.plan.md" "$SENT" || fail "raising the threshold must not hide the blocked task itself"
echo "OK: DEVBRAIN_DIGEST_STALE_DAYS=100 suppresses escalation for the same ~10-day-old blocked task"

# ---- 10. the escalation marker is appended verbatim, never through the summarizer,
# same mechanism (and same reason) as the numbering in cases 2-3 above
grep -q "AI-SUMMARY:" "$SENT" || fail "the AI-generated summary is missing"
rm -f "$SENT"
run_digest > /dev/null 2>&1   # back to the default threshold, so ⚠️ is present again
AI_LINE=$(grep -n "AI-SUMMARY:" "$SENT" | head -1 | cut -d: -f1)
WARN_LINE=$(grep -n "⚠️" "$SENT" | head -1 | cut -d: -f1)
[ -n "$WARN_LINE" ] || fail "expected the ⚠️ marker to be present at the default threshold"
[ "$AI_LINE" -lt "$WARN_LINE" ] || fail "the escalation marker does not come after the AI summary"
grep -q "AI-SUMMARY:.*⚠️" "$SENT" && fail "the escalation marker was fed through the AI summarizer"
echo "OK: the escalation marker is appended after the AI summary, untouched by the summarizer"
rm -f "$TMP/queue"/*.plan.md

echo "PASS: devbrain-digest-proposals"

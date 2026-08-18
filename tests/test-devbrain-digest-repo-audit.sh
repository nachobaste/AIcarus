#!/bin/bash
# tests/test-devbrain-digest-repo-audit.sh — the digest's "repos unclassified"
# section (2026-08-12, wiki/log.md). Same discipline as
# test-devbrain-digest-proposals.sh: every external tool stubbed through its
# DEVBRAIN_DIGEST_*_BIN override, never PATH (that hardcoded `export PATH=...`
# defeated a PATH-prepend trick once already and sent a live Telegram digest
# during testing). The one property that matters: repo names must survive the
# AI summarizer verbatim, the same reason Proposals/Blocked bypass it —
# a paraphrased or dropped repo name defeats the entire point of this check.
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
cat > "$TMP/fake-claude" <<'EOF'
#!/bin/bash
IN="$(cat)"
echo "RESUMEN-IA: $(printf '%s' "$IN" | wc -l | tr -d ' ') lineas de contexto recibidas"
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
chmod +x "$TMP/fake-gh" "$TMP/fake-claude" "$TMP/fake-openclaw" "$TMP/fake-gog" "$TMP/fake-personal-digest"

run_digest() {
  DEVBRAIN_PROJECTS_DIR="$TMP/projects" DEVBRAIN_WIKI_DIR="$TMP/wiki" \
  DEVBRAIN_QUEUE_DIR="$TMP/queue" DEVBRAIN_DIGEST_LOG="$TMP/digest.log" \
  DEVBRAIN_DIGEST_GH_BIN="$TMP/fake-gh" DEVBRAIN_DIGEST_CLAUDE_BIN="$TMP/fake-claude" \
  DEVBRAIN_DIGEST_OPENCLAW_BIN="$TMP/fake-openclaw" \
  DEVBRAIN_DIGEST_GOG_BIN="$TMP/fake-gog" \
  DEVBRAIN_PERSONAL_DIGEST_BIN="$TMP/fake-personal-digest" \
  DEVBRAIN_REPO_AUDIT_BIN="${REPO_AUDIT_STUB:-$TMP/no-such-binary}" \
  DEVBRAIN_TG_CHAT_ID="123456789" \
  HOME="$TMP/no-home" DEVBRAIN_NO_TG=1 \
  bash "$BIN"
}

# ---- 1. no repo-audit binary at all: digest still runs, no crash, no section ----
run_digest >/dev/null 2>&1
grep -q "digest sent" "$TMP/digest.log" 2>/dev/null || fail "the digest did not complete when devbrain-repo-audit is missing"
[ -f "$SENT" ] || fail "no message was sent when devbrain-repo-audit is missing"
grep -qi "unclassified" "$SENT" && fail "a repo-audit section appeared with no binary to produce it"
echo "OK: a missing devbrain-repo-audit binary never crashes the digest, never fakes a section"

# ---- 2. repo-audit finds nothing (exit 0, no output): no section either -----
cat > "$TMP/fake-repo-audit-clean" <<'EOF'
#!/bin/bash
echo "repo-audit: 0"
exit 0
EOF
chmod +x "$TMP/fake-repo-audit-clean"
rm -f "$SENT"
REPO_AUDIT_STUB="$TMP/fake-repo-audit-clean" run_digest >/dev/null 2>&1
[ -f "$SENT" ] || fail "no message sent on the clean repo-audit run"
grep -qi "unclassified" "$SENT" && fail "a repo-audit section appeared with zero findings"
echo "OK: zero findings means no section, no false alarm"

# ---- 3. repo-audit finds two repos: both names reach the message verbatim --
cat > "$TMP/fake-repo-audit-findings" <<'EOF'
#!/bin/bash
printf 'repo-not-cloned\trepob\t2026-08-11T23:47:12Z\n'
printf 'repo-unclassified\trepob\t2026-08-11T23:47:12Z\n'
printf 'repo-not-cloned\trepoc\t2026-07-20T18:56:55Z\n'
echo "repo-audit: 3"
EOF
chmod +x "$TMP/fake-repo-audit-findings"
rm -f "$SENT"
REPO_AUDIT_STUB="$TMP/fake-repo-audit-findings" run_digest >/dev/null 2>&1
[ -f "$SENT" ] || fail "no message sent with real repo-audit findings"
grep -q "repob" "$SENT" || fail "repob never reached the sent message: $(cat "$SENT")"
grep -q "repoc" "$SENT" || fail "repoc never reached the sent message: $(cat "$SENT")"
grep -qi "unclassified" "$SENT" || fail "the section header is missing despite findings: $(cat "$SENT")"
grep -q "RESUMEN-IA:.*repob" "$SENT" \
  && fail "a repo name was fed through the AI summarizer and came back reworded"
echo "OK: repo-audit findings reach the owner with names intact, untouched by the summarizer"

# ---- 4. the repo-audit block sits AFTER the AI summary -----------------------
AI_LINE=$(grep -n "RESUMEN-IA:" "$SENT" | head -1 | cut -d: -f1)
SEC_LINE=$(grep -n -i "unclassified" "$SENT" | head -1 | cut -d: -f1)
[ -n "$AI_LINE" ] && [ -n "$SEC_LINE" ] && [ "$AI_LINE" -lt "$SEC_LINE" ] \
  || fail "the repo-audit block does not come after the AI summary"
echo "OK: the repo-audit block is appended after the AI summary, same as Proposals/Blocked"

echo "PASS"

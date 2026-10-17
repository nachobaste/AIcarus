#!/bin/bash
# tests/test-devbrain-digest-vigia.sh — the digest includes the "Watch" section: one
# "no findings" line when there is nothing, the findings verbatim when there are, a line that says
# so when the script fails, and no section at all when the script prints nothing (no launchd).
[ -z "${OPENCLAW_CLI+x}" ] && [ "${OPENCLAW_SHELL-}" != exec ] || { echo "FAIL: these tests do not run under OpenClaw" >&2; exit 1; }
set -uo pipefail
export DEVBRAIN_NO_TG=1
DIR="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$DIR/bin/devbrain-digest"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
die() { echo "FAIL (line ${BASH_LINENO[0]})"; exit 1; }
mkdir -p "$TMP/projects" "$TMP/wiki/status" "$TMP/wiki/projects" "$TMP/queue"
SENT="$TMP/sent.txt"
printf '#!/bin/bash\nexit 0\n' > "$TMP/fake-gh"
printf '#!/bin/bash\necho "AI-SUMMARY: test"\n' > "$TMP/fake-claude"
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
chmod +x "$TMP/fake-gh" "$TMP/fake-claude" "$TMP/fake-openclaw"

run_digest() { # <body of the fake vigia> <rc>
  printf '#!/bin/bash\n%s\nexit %s\n' "$1" "$2" > "$TMP/fake-vigia"; chmod +x "$TMP/fake-vigia"; rm -f "$SENT"
  DEVBRAIN_PROJECTS_DIR="$TMP/projects" DEVBRAIN_WIKI_DIR="$TMP/wiki" DEVBRAIN_QUEUE_DIR="$TMP/queue" \
  DEVBRAIN_DIGEST_LOG="$TMP/digest.log" DEVBRAIN_DIGEST_GH_BIN="$TMP/fake-gh" DEVBRAIN_DIGEST_CLAUDE_BIN="$TMP/fake-claude" \
  DEVBRAIN_DIGEST_OPENCLAW_BIN="$TMP/fake-openclaw" DEVBRAIN_REPO_AUDIT_BIN="$TMP/none" DEVBRAIN_VIGIA_BIN="$TMP/fake-vigia" \
  DEVBRAIN_TG_CHAT_ID=123456789 TELEGRAM_CURL_BIN="$TMP/none" HOME="$TMP/no-home" \
  bash "$BIN" >/dev/null 2>&1
  [ -f "$SENT" ] || { echo "FAIL: the digest sent nothing"; exit 1; }
}
run_digest 'echo "  no findings"' 0
grep -q 'Watch (scheduled jobs):' "$SENT" && grep -q 'no findings' "$SENT" && echo "OK: no findings, one line" || die
grep -q 'All quiet' "$SENT" && echo "OK: with no findings the quiet message stays" || die
run_digest 'echo "  - [jobs] job-x: last exit code 78. What to do: look at its log."' 0
grep -q '\[jobs\] job-x' "$SENT" && echo "OK: findings come out verbatim" || die
grep -q 'All quiet' "$SENT" && die || echo "OK: findings are not shown under an \"All quiet\""
run_digest 'echo boom >&2' 3
grep -q 'could not run the watch' "$SENT" && echo "OK: if the script fails, the digest says so" || die
grep -q 'All quiet' "$SENT" && die || echo "OK: a failed watch is not shown under an \"All quiet\" either"
run_digest 'true' 0
grep -q 'Watch (scheduled jobs)' "$SENT" && die || echo "OK: a script that prints nothing leaves no section"
echo "PASS: digest-vigia"

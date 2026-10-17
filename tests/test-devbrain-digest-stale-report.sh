#!/bin/bash
# tests/test-devbrain-digest-stale-report.sh — the digest does not repeat the block of an old
# night-report-latest.md. devbrain-night only rewrites it when it runs, so with the night off
# the file stays frozen and the digest would repeat the last blocked plan forever, even after
# that plan was closed. Everything is stubbed; the queue is a temporary directory.
[ -z "${OPENCLAW_CLI+x}" ] && [ "${OPENCLAW_SHELL-}" != exec ] || { echo "FAIL: these tests do not run under OpenClaw" >&2; exit 1; }
set -uo pipefail
export DEVBRAIN_VIGIA_BIN=/nonexistent   # the watch reads launchd: never from these tests
export DEVBRAIN_NO_TG=1
DIR="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$DIR/bin/devbrain-digest"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $1"; [ -f "$TMP/ai-input.txt" ] && cat "$TMP/ai-input.txt"; exit 1; }

mkdir -p "$TMP/projects" "$TMP/wiki/status" "$TMP/wiki/projects" "$TMP/queue"
Q="$TMP/queue"; SENT="$TMP/sent.txt"
printf '#!/bin/bash\nexit 0\n' > "$TMP/fake-gh"
# The summarizer keeps what it receives (argv + stdin): that is where the old report got in.
printf '#!/bin/bash\n{ printf "%%s\\n" "$@"; cat; } > "%s/ai-input.txt"\necho "AI-SUMMARY: test"\n' "$TMP" > "$TMP/fake-claude"
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
# A blocked plan keeps the digest out of its "all quiet" branch, so the summarizer is called.
printf -- '---\nrepo: demo\nstatus: blocked\nprioridad: 10\ncreado: 2026-10-01\nbloqueado_por: make\n---\n\nbody\n' > "$Q/10-demo--blocked.plan.md"

run_digest() {
  rm -f "$SENT" "$TMP/ai-input.txt"
  DEVBRAIN_PROJECTS_DIR="$TMP/projects" DEVBRAIN_WIKI_DIR="$TMP/wiki" \
  DEVBRAIN_QUEUE_DIR="$Q" DEVBRAIN_DIGEST_LOG="$TMP/digest.log" \
  DEVBRAIN_DIGEST_GH_BIN="$TMP/fake-gh" DEVBRAIN_DIGEST_CLAUDE_BIN="$TMP/fake-claude" \
  DEVBRAIN_DIGEST_OPENCLAW_BIN="$TMP/fake-openclaw" DEVBRAIN_REPO_AUDIT_BIN="$TMP/none" \
  DEVBRAIN_TG_CHAT_ID=123456789 TELEGRAM_CURL_BIN="$TMP/none" HOME="$TMP/no-home" \
  bash "$BIN" >/dev/null 2>&1
  [ -f "$SENT" ] || fail "the digest sent nothing"
  [ -f "$TMP/ai-input.txt" ] || fail "the summarizer was never called: the capture is blind"
}
report() { # <date 'YYYY-MM-DD HH:MM'>
  printf '# Night report — %s\n\n- 🚧 10-stale-plan--x.plan.md — blocked, missing: `STALE-MARKER`\n\nTotal: 0 PRs, 0 failures, 1 blocked.\n' "$1" > "$Q/night-report-latest.md"
}
ago() { python3 -I -c 'import datetime,sys;print((datetime.datetime.now()-datetime.timedelta(hours=float(sys.argv[1]))).strftime("%Y-%m-%d %H:%M"))' "$1"; }

# ---- (1) a 5-day-old report: it does not appear, and its absence is said ----------------
report "$(ago 120)"
run_digest
grep -q "STALE-MARKER" "$TMP/ai-input.txt" && fail "(1) the block of a 5-day-old report reached the summary"
grep -q "no recent night report" "$TMP/ai-input.txt" || fail "(1) it does not say there is no recent report"
echo "OK (1): an old report is ignored and the absence is said"

# ---- (2) a report from last night: it does appear ---------------------------------------
report "$(ago 1)"
run_digest
grep -q "STALE-MARKER" "$TMP/ai-input.txt" || fail "(2) last night's block does not appear"
grep -q "no recent night report" "$TMP/ai-input.txt" && fail "(2) it says there is no report with a fresh one"
echo "OK (2): a fresh report is shown"

# ---- (3) the 36 h edge ----------------------------------------------------------------------
report "$(ago 35)"; run_digest
grep -q "STALE-MARKER" "$TMP/ai-input.txt" || fail "(3) a 35 h report must still show"
report "$(ago 37)"; run_digest
grep -q "STALE-MARKER" "$TMP/ai-input.txt" && fail "(3) a 37 h report must be ignored"
echo "OK (3): 35 h shows, 37 h does not"

# ---- (4) an unreadable header is treated as old -------------------------------------------------
printf 'garbage with no header\n- blocked STALE-MARKER\n' > "$Q/night-report-latest.md"
run_digest
grep -q "STALE-MARKER" "$TMP/ai-input.txt" && fail "(4) a report with no readable date was shown"
echo "OK (4): no readable date = old"
echo "PASS: devbrain-digest-stale-report"

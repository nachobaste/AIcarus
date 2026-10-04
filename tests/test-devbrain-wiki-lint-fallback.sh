#!/bin/bash
# tests/test-devbrain-wiki-lint-fallback.sh — static check that devbrain-wiki-lint is
# actually wired to the fallback (plan 260), not just that lib/telegram.sh has it.
#
# A live end-to-end run of devbrain-wiki-lint would need to stub `claude` too — it is
# invoked bare, with no override, and out of this plan's scope ("no convertirla en una
# refactorización... solo el respaldo"). The actual fallback LOGIC is exercised live in
# tests/test-telegram-fallback.sh; this only proves wiki-lint reaches it instead of the
# bare `openclaw message send` it used before.
set -uo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
WL="$DIR/bin/devbrain-wiki-lint"

fail() { echo "FAIL: $1"; exit 1; }

[ -f "$WL" ] || fail "$WL not found"

grep -q 'source.*lib/telegram.sh' "$WL" || fail "devbrain-wiki-lint does not source lib/telegram.sh"
echo "OK: devbrain-wiki-lint sources lib/telegram.sh"

grep -q 'tg_send_with_fallback' "$WL" || fail "devbrain-wiki-lint does not call tg_send_with_fallback"
echo "OK: devbrain-wiki-lint calls tg_send_with_fallback"

grep -qE '^\s*openclaw message send' "$WL" \
  && fail "devbrain-wiki-lint still has a bare 'openclaw message send' — the old, unresiliant path"
echo "OK: the old bare openclaw call is gone, not left alongside the fallback"

grep -q 'OPENCLAW_BIN="\${DEVBRAIN_WIKI_LINT_OPENCLAW_BIN:-openclaw}"' "$WL" \
  || fail "OPENCLAW_BIN is not overridable — a future test could not stub it safely"
echo "OK: the openclaw binary is overridable for future testing"

# devbrain-wiki-status-audit (2026-08-12): stale PR/workflow claims in
# wiki/status and wiki/services get surfaced the same way DRIFT and STACKED
# already are -- reported in the log and the Telegram summary, never handed
# to the model to "fix" (same reasoning as devbrain-drift/stacked-pr-check).
grep -q 'devbrain-wiki-status-audit' "$WL" \
  || fail "devbrain-wiki-lint does not call devbrain-wiki-status-audit"
echo "OK: devbrain-wiki-lint calls devbrain-wiki-status-audit"

grep -q '\$STALE' "$WL" \
  || fail "the wiki-status-audit result (\$STALE) never reaches the Telegram summary"
echo "OK: the wiki-status-audit result reaches the Telegram summary"

# ---- live: each checker runs ONCE, and its count reaches the summary --------
# The four checkers are stubs next to a copy of the script, so this needs no
# wiki, no gh and no model. A checker that ran twice (the old quiet-then-rerun pattern)
# shows up as two lines in its call log.
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/kit/bin" "$T/kit/lib" "$T/home/dev/wiki" "$T/home/.openclaw/logs"
cp "$WL" "$T/kit/bin/"; cp "$DIR/lib/telegram.sh" "$T/kit/lib/"
stub() { # <name> <exit> <count line>
  printf '#!/bin/bash\necho run >> "%s/%s.calls"\necho "finding-row"\necho "%s"\nexit %s\n' \
    "$T" "$1" "$3" "$2" > "$T/kit/bin/$1"
  chmod +x "$T/kit/bin/$1"
}
stub wiki-linkcheck 0 "unresolved: 0"
stub devbrain-drift 1 "drift: 3"
stub devbrain-stacked-pr-check 0 "stacked-pr: 0"
stub devbrain-wiki-status-audit 1 "wiki-status-audit: 2"
printf '#!/bin/bash\necho "lint summary"\n' > "$T/claude"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/sent"\n' "$T" > "$T/openclaw"
chmod +x "$T/claude" "$T/openclaw"
HOME="$T/home" DEVBRAIN_TG_CHAT_ID=1 DEVBRAIN_WIKI_LINT_CLAUDE_BIN="$T/claude" \
  DEVBRAIN_WIKI_LINT_OPENCLAW_BIN="$T/openclaw" bash "$T/kit/bin/devbrain-wiki-lint" >/dev/null 2>&1
for c in devbrain-drift devbrain-stacked-pr-check devbrain-wiki-status-audit; do
  [ "$(wc -l < "$T/$c.calls" | tr -d ' ')" = 1 ] || fail "$c ran $(cat "$T/$c.calls" 2>/dev/null | wc -l | tr -d ' ') times, expected once"
done
# linkcheck runs twice by design: once to hand the model its list, once to verify.
[ "$(wc -l < "$T/wiki-linkcheck.calls" | tr -d ' ')" = 2 ] || fail "wiki-linkcheck should run exactly twice"
echo "OK: each checker runs once per verdict"
grep -q "links OK · ⚠️ 3 drift between stores · no orphaned stacked PRs · ⚠️ 2 outdated claim(s)" "$T/sent" \
  || fail "summary does not carry the checkers' verdicts: $(cat "$T/sent" 2>/dev/null)"
echo "OK: the summary carries each checker's verdict and count"
grep -q "finding-row" "$T/home/.openclaw/logs/wiki-lint.log" \
  || fail "a failing checker's report did not reach the log"
echo "OK: a failing checker's full report reaches the log"

echo "PASS: devbrain-wiki-lint-fallback"

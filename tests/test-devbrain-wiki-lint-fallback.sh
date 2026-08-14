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

echo "PASS: devbrain-wiki-lint-fallback"

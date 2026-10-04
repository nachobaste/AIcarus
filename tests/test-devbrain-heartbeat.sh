#!/bin/bash
# tests/test-devbrain-heartbeat.sh — the Ollama probe runs only when the
# bridge's config uses Ollama. Runs the real script under a temporary HOME with
# no chat id, so it can only log, never alert. The other probes (launchd, disk,
# gateway health) read this machine's real state; only the Ollama verdict is
# asserted.
set -uo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$DIR/bin/devbrain-heartbeat"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $1"; exit 1; }

run() { # <openclaw.json contents>
  rm -rf "$TMP/home"; mkdir -p "$TMP/home/.openclaw/logs"
  printf '%s\n' "$1" > "$TMP/home/.openclaw/openclaw.json"
  # Port 1 never answers, so an Ollama probe that runs always fails.
  HOME="$TMP/home" DEVBRAIN_TG_CHAT_ID= DEVBRAIN_OLLAMA_URL="http://127.0.0.1:1" \
    bash "$BIN" >/dev/null 2>&1
  cat "$TMP/home/.openclaw/logs/heartbeat.state" 2>/dev/null
}

run '{"agents":{"defaults":{"model":"moonshot/kimi-k2"}}}' | grep -q "ollama-not-responding" \
  && fail "a hosted-model config still probes Ollama"
echo "OK: no Ollama probe when the bridge doesn't use Ollama"

run '{"agents":{"defaults":{"model":"ollama/llama3"}}}' | grep -q "ollama-not-responding" \
  || fail "an Ollama config with Ollama down raised no alert"
echo "OK: an Ollama config with Ollama down is flagged"

echo "PASS: devbrain-heartbeat"

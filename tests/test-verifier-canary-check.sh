#!/bin/bash
# tests/test-verifier-canary-check.sh — the canary's comparison (tests/canary/verifier/run.sh) can fail.
# Free: a fake claude answers the verifier's prompt. The real, billed canary is `tests/canary/verifier/run.sh`.
# One fake answers as expected (must pass), a lazy one says HOLDS to everything (must fail), one swaps a single
# verdict (must fail), one drops a claim that should HOLD (must fail: a missing verdict is UNVERIFIABLE).
[ -z "${OPENCLAW_CLI+x}" ] && [ "${OPENCLAW_SHELL-}" != exec ] || { echo "FAIL: these tests do not run under OpenClaw" >&2; exit 1; }
set -uo pipefail
export DEVBRAIN_NO_TG=1
DIR="$(cd "$(dirname "$0")/.." && pwd)"
RUN="$DIR/tests/canary/verifier/run.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"; mkdir -p "$HOME"
die() { echo "FAIL: ${1:-test-verifier-canary-check.sh:${BASH_LINENO[0]}}"; exit 1; }

# fake claude: reads the prompt, takes the claims between <claims> and </claims> and answers according to $FAKE
cat > "$TMP/claude" <<'FAKE'
#!/bin/bash
in="$(cat)"; i=0
printf '%s\n' "$in" | sed -n '/^<claims>$/,/^<\/claims>$/p' | sed '1d;$d' | while IFS= read -r l; do
  i=$((i + 1)); claim="${l% :: *}"
  case "$FAKE" in
    faithful) v="$(sed -n "${i}p" "$EXPECTED")" ;;
    lazy)     v=HOLDS ;;
    swapped)  v="$(sed -n "${i}p" "$EXPECTED")"; [ "$i" = 4 ] && v=HOLDS ;;
    partial)  [ "$i" = 3 ] && continue; v="$(sed -n "${i}p" "$EXPECTED")" ;;
  esac
  printf '%s :: %s\n' "$claim" "$v"
done
FAKE
chmod +x "$TMP/claude"
run() { FAKE="$1" EXPECTED="$DIR/tests/canary/verifier/expected.txt" DEVBRAIN_CLAUDE_BIN="$TMP/claude" "$RUN" 2>&1; }

out="$(run faithful)"; rc=$?
[ "$rc" = 0 ] && printf '%s' "$out" | grep -q '^OK canary' || { echo "$out"; die "a faithful verifier had to pass the canary"; }
echo "OK: a faithful verifier passes"
for f in lazy swapped partial; do
  out="$(run "$f")"; rc=$?
  [ "$rc" != 0 ] && printf '%s' "$out" | grep -q '^FAIL canary' || { echo "$out"; die "the canary did not catch the '${f}' verifier"; }
  echo "OK: the canary catches the '${f}' verifier"
done
echo "PASS: test-verifier-canary-check"

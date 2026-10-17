#!/bin/bash
# tests/test-queue-blocked.sh — queue_blocked_command, the pure detector behind the
# 'blocked' status (D4/D5 of docs/superpowers/specs/
# 2026-08-07-devbrain-verify-commands-design.md).
#
# A session that hits a permission it does not have writes .devbrain/blocked-by.txt
# with the exact command it needed. This is the ONLY function that reads that file —
# both bin/devbrain (to decide whether to skip the PR flow) and bin/devbrain-night
# (to decide whether to mark the plan 'blocked' instead of 'failed') call it, so the
# two can never disagree about what counts as blocked.
[ -z "${OPENCLAW_CLI+x}" ] && [ "${OPENCLAW_SHELL-}" != exec ] || { echo "FAIL: these tests do not run under OpenClaw" >&2; exit 1; }
set -uo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
source "$DIR/lib/queue.sh"

fail() { echo "FAIL: $1"; exit 1; }

# ---- no blocked-by.txt at all: nothing, exit 0 ------------------------------
mkdir -p "$TMP/clean"
OUT="$(queue_blocked_command "$TMP/clean")"; RC=$?
[ "$RC" -eq 0 ] || fail "a clean project dir should exit 0, got $RC"
[ -z "$OUT" ] || fail "a clean project dir reported a blocked command: $OUT"
echo "OK: no blocked-by.txt means nothing is reported"

# ---- the file exists: the PROGRAM of each line is reported -----------------------
# Only the first token (after VAR=value prefixes) is published, never arguments or values.
# The full file stays on disk.
mkdir -p "$TMP/blocked/.devbrain"
printf 'deno lint\n' > "$TMP/blocked/.devbrain/blocked-by.txt"
OUT="$(queue_blocked_command "$TMP/blocked")"; RC=$?
[ "$RC" -eq 0 ] || fail "a blocked project should still exit 0 (it is a detector, not a failure), got $RC"
[ "$OUT" = "deno" ] || fail "only the program of the blocked command should be reported, got: '$OUT'"
echo "OK: an existing blocked-by.txt reports the program, not the arguments"

# ---- secrets in the line never come out ---------------------------------------------
blocked() { printf '%s\n' "$1" > "$TMP/blocked/.devbrain/blocked-by.txt"; queue_blocked_command "$TMP/blocked"; }
SECRET_VALUE="hunter2-not-a-real-password"
[ "$(blocked "PGPASSWORD=$SECRET_VALUE psql -h db")" = "psql" ] || fail "a VAR=value prefix must be dropped"
[ "$(blocked "A=1 B=\"two words\" C='x y' npm run build")" = "npm" ] || fail "quoted VAR=value prefixes must be dropped"
[ "$(blocked "\$(cat /etc/passwd) x")" = "[HIDDEN]" ] || fail "a command substitution is not a program name"
[ "$(blocked "\"curl\" --user a:$SECRET_VALUE")" = "[HIDDEN]" ] || fail "a quote is not a program name"
[ "$(blocked "FOO=bar")" = "[HIDDEN]" ] || fail "assignments only (nothing left) must not leak the value"
printf 'npm test\n\n  \nsupabase db push --password %s\n' "$SECRET_VALUE" > "$TMP/blocked/.devbrain/blocked-by.txt"
OUT="$(queue_blocked_command "$TMP/blocked")"
[ "$OUT" = "$(printf 'npm\nsupabase')" ] || fail "one program per non-empty line expected, got: '$OUT'"
printf '%s' "$OUT" | grep -qF "$SECRET_VALUE" && fail "the report leaked a value"
echo "OK: VAR=value prefixes, quotes and substitutions never reach the report"

# ---- an empty blocked-by.txt is NOT a block ---------------------------------
# A session that touches the file without writing anything is not the same as one
# that named a real missing command — treating it as blocked would surface a
# decision with nothing for the owner to act on.
mkdir -p "$TMP/empty/.devbrain"
: > "$TMP/empty/.devbrain/blocked-by.txt"
OUT="$(queue_blocked_command "$TMP/empty")"
[ -z "$OUT" ] || fail "an empty blocked-by.txt should not count as a real block, got: '$OUT'"
echo "OK: an empty blocked-by.txt is not treated as a block"

# ---- a nonexistent project dir does not crash -------------------------------
OUT="$(queue_blocked_command "$TMP/no-such-dir")"; RC=$?
[ "$RC" -eq 0 ] || fail "a nonexistent project dir should not crash the detector, got $RC"
[ -z "$OUT" ] || fail "a nonexistent project dir should report nothing, got: '$OUT'"
echo "OK: a nonexistent project directory is handled without crashing"

echo "PASS: queue-blocked"

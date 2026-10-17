#!/bin/bash
# tests/test-secret-patterns.sh — lib/secret_patterns.py: find_secret (what looks like a
# secret) and `review` (the pre-push read of every commit of <base>..HEAD).
#
# Every key-shaped string is assembled at run time from two halves, so this file never
# contains one that a secret scanner (or a reader) could take for a real key.
[ -z "${OPENCLAW_CLI+x}" ] && [ "${OPENCLAW_SHELL-}" != exec ] || { echo "FAIL: these tests do not run under OpenClaw" >&2; exit 1; }
set -uo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
SP="$DIR/lib/secret_patterns.py"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $1"; exit 1; }

# ---- find_secret: formats it must catch, and prose it must not ----------------------------
A24="$(python3 -c 'print("a1B2" * 6)')"      # 24 chars, letters and digits
OUT="$(python3 -I - "$DIR/lib" "$A24" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from secret_patterns import find_secret
a = sys.argv[2]
must = {
    "generic-sk": "key " + "sk" + "-" + a,
    "github": "t=" + "gh" + "p_" + (a * 2)[:36],
    "slack": "x" + "ox" + "b-" + a + "-" + a,
    "aws": "id " + "AK" + "IA" + "ABCDEFGHIJKLMNOP",
    "jwt": "ey" + "J" + "hbGciOiJI" + "." + "abcdefghijkl" + "." + a + a,
    "private-key": "-----BEGIN RSA PRIVATE KEY-----",
    "credential-in-url": "postgres://user:hunter2x@db.example.com/x",
    "bearer": "Authorization: Bearer " + a + "1",
    "token-in-url": "https://x.example/?token=" + a,
}
prose = [
    "the sk" + "-proj" + "- prefix is documented here",
    "gh" + "p_abc is a prefix",
    "a snake_case name re_run_failed_plans_every_night is not a key",
    "postgres://postgres:postgres@localhost:54322/postgres",
    "Bearer YOUR_API_KEY_HERE_REPLACE_ME_PLEASE",
    "risk-based task-runner desk.example",
]
bad = [k for k, t in must.items() if find_secret(t) != k]
bad += ["prose:" + t for t in prose if find_secret(t)]
print("BAD " + " | ".join(bad) if bad else "OK")
PY
)"
[ "$OUT" = OK ] || fail "find_secret: $OUT"
echo "OK: find_secret catches the formats and ignores the prose"

# ---- review: a throwaway repo -------------------------------------------------------------
mk() { # <dir> -> repo with one base commit
  git init -q "$1"; git -C "$1" config user.email t@t; git -C "$1" config user.name t
  printf 'x\n' > "$1/a.txt"; git -C "$1" add -A; git -C "$1" commit -qm base
}
review() { # <dir> <mode> -> sets OUT and RV (not a subshell: RV must survive)
  RV=0; OUT="$(cd "$1" && env -i HOME="$TMP" PATH=/usr/bin:/bin:/opt/homebrew/bin python3 -I "$SP" review HEAD~1 "$2" 2>&1)" || RV=$?
}
KEY="$(printf 'sk%s%s' '-' "$A24")"

# clean commit -> 0
R="$TMP/clean"; mk "$R"; printf 'hello\n' > "$R/b.txt"; git -C "$R" add -A; git -C "$R" commit -qm "add b"
review "$R" ok; [ "$RV" -eq 0 ] && [ -z "$OUT" ] || fail "a clean commit should exit 0 and print nothing (rc=$RV: $OUT)"
echo "OK: a clean commit passes"

# a key in a file -> 1, and the report names the file and the kind but never the value
R="$TMP/leak"; mk "$R"; printf 'token = %s\n' "$KEY" > "$R/conf.txt"; git -C "$R" add -A; git -C "$R" commit -qm "add conf"
review "$R" ok; [ "$RV" -eq 1 ] || fail "a key in a file should exit 1, got $RV"
printf '%s' "$OUT" | grep -q $'conf.txt\tpattern generic-sk' || fail "report should name file and kind: $OUT"
printf '%s' "$OUT" | grep -qF "$A24" && fail "the report printed the key value"
echo "OK: a key is reported by file and kind, never by value"

# a key added and then deleted still travels in the history
git -C "$R" rm -q conf.txt; git -C "$R" commit -qm "remove conf"
RV=0; OUT="$(cd "$R" && python3 -I "$SP" review HEAD~2 ok 2>&1)" || RV=$?
[ "$RV" -eq 1 ] || fail "a key deleted in a later commit must still be found (rc=$RV)"
echo "OK: a deleted key is still found in the history"

# the commit message and a .env file name
R="$TMP/msg"; mk "$R"; printf 'a=1\n' > "$R/.env"; git -C "$R" add -A; git -C "$R" commit -qm "key $KEY"
review "$R" ok; [ "$RV" -eq 1 ] || fail "a .env file and a key in the message should exit 1"
printf '%s' "$OUT" | grep -q $'commit message [0-9a-f]*\tpattern generic-sk' || fail "message finding missing: $OUT"
printf '%s' "$OUT" | grep -q $'.env\t.env file name' || fail ".env name finding missing: $OUT"
printf '%s' "$OUT" | grep -qF "$A24" && fail "the report printed the key value"
echo "OK: commit messages and .env file names are reviewed"

# a template name is exempt
R="$TMP/tpl"; mk "$R"; printf 'a=\n' > "$R/.env.example"; git -C "$R" add -A; git -C "$R" commit -qm tpl
review "$R" ok; [ "$RV" -eq 0 ] || fail ".env.example should pass (rc=$RV: $OUT)"
echo "OK: .env.example is not a finding"

# blocked mode also stops data files and binaries; ok mode lets them through
R="$TMP/data"; mk "$R"; printf 'a,b\n' > "$R/rows.csv"; head -c 64 /dev/zero > "$R/blob.bin"; git -C "$R" add -A; git -C "$R" commit -qm data
review "$R" ok; [ "$RV" -eq 0 ] || fail "ok mode should let a csv and a binary through (rc=$RV: $OUT)"
review "$R" blocked; [ "$RV" -eq 1 ] || fail "blocked mode should stop them (rc=$RV)"
printf '%s' "$OUT" | grep -q $'rows.csv\tdata' && printf '%s' "$OUT" | grep -q $'blob.bin\tbinary' || fail "blocked mode findings missing: $OUT"
echo "OK: blocked mode stops data files and binaries, ok mode does not"

# fail closed: a base ref that does not exist, and a missing git
R="$TMP/clean"
RV=0; OUT="$(cd "$R" && python3 -I "$SP" review no-such-ref ok 2>&1)" || RV=$?
[ "$RV" -eq 2 ] && printf '%s' "$OUT" | grep -q 'could not run' || fail "a bad base ref must exit 2 'could not run' (rc=$RV: $OUT)"
RV=0; OUT="$(cd "$R" && env -i HOME="$TMP" PATH=/nonexistent /usr/bin/python3 -I "$SP" review HEAD~1 ok 2>&1)" || RV=$?
[ "$RV" -eq 2 ] || fail "with no git on PATH the review must fail closed (rc=$RV)"
RV=0; OUT="$(python3 -I "$SP" review 2>&1)" || RV=$?
[ "$RV" -eq 2 ] || fail "bad usage must exit 2"
echo "OK: the review fails closed when it cannot run"

echo "PASS: secret-patterns"

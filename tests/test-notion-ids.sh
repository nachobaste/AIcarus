#!/bin/bash
# tests/test-notion-ids.sh — the id cache, both --get and --resolve.
set -uo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
SRV_PID=""
cleanup() { [ -n "$SRV_PID" ] && kill "$SRV_PID" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT
export NOTION_IDS_FILE="$TMP/notion-ids.json"
export NOTION_TOKEN="ntn_fake_for_tests"
export PYTHONPATH="$DIR/lib"

# A crash must never be mistaken for a clean error. Every failure assertion in
# this file pairs its exit-code check with a traceback check, because a raw
# KeyError traceback happens to contain the very word a naive grep looks for —
# which is how an earlier version of this suite passed on a crash.
assert_clean_error() {  # $1 = stderr file, $2 = label
  grep -qi traceback "$1" \
    && { echo "FAIL: $2 crashed instead of erroring cleanly"; exit 1; } \
    || echo "OK: $2 fails cleanly, no traceback"
}

# ---- --get reads the cache, and distinguishes keys -------------------------
cat > "$NOTION_IDS_FILE" <<'JSON'
{"Areas":"11111111-1111-1111-1111-111111111111",
 "Projects":"22222222-2222-2222-2222-222222222222"}
JSON
[ "$("$DIR/bin/notion-ids.py" --get Areas)" = "11111111-1111-1111-1111-111111111111" ] \
  && echo "OK: --get reads the cache" || exit 1
# The second key must be read too, or a bug confined to non-first keys is invisible.
[ "$("$DIR/bin/notion-ids.py" --get Projects)" = "22222222-2222-2222-2222-222222222222" ] \
  && echo "OK: --get distinguishes keys" || exit 1

"$DIR/bin/notion-ids.py" --get Nonexistent >/dev/null 2>"$TMP/e1"
[ $? -ne 0 ] && echo "OK: an unknown base is an error" || exit 1
grep -qi nonexistent "$TMP/e1" && echo "OK: the error names the base" || exit 1
assert_clean_error "$TMP/e1" "unknown base"

# ---- a corrupt cache must be actionable, not a traceback -------------------
printf '{"Areas": ' > "$NOTION_IDS_FILE"          # truncated JSON
"$DIR/bin/notion-ids.py" --get Areas >/dev/null 2>"$TMP/e2"
[ $? -ne 0 ] && echo "OK: a corrupt cache is an error" || exit 1
assert_clean_error "$TMP/e2" "corrupt cache"
grep -q -- "--resolve" "$TMP/e2" && echo "OK: it says how to regenerate" || exit 1

# ---- a missing cache must say how to fix it -------------------------------
rm -f "$NOTION_IDS_FILE"
"$DIR/bin/notion-ids.py" --get Areas >/dev/null 2>"$TMP/e3"
[ $? -ne 0 ] && echo "OK: a missing cache is an error" || exit 1
grep -q -- "--resolve" "$TMP/e3" && echo "OK: the error says how to fix it" || exit 1
assert_clean_error "$TMP/e3" "missing cache"

# ---- a missing token must be a config error, not a traceback --------------
( unset NOTION_TOKEN; NOTION_BASE="http://127.0.0.1:1" \
    "$DIR/bin/notion-ids.py" --resolve >/dev/null 2>"$TMP/e4" )
[ $? -ne 0 ] && echo "OK: --resolve without a token is an error" || exit 1
assert_clean_error "$TMP/e4" "missing token"
grep -qi token "$TMP/e4" && echo "OK: the error names the token" || exit 1

# ---- --resolve against a mock search endpoint -----------------------------
cat > "$TMP/mock.py" <<'PY'
import http.server, json, sys
MODE = sys.argv[2]
BASES = ["Areas", "Projects", "Goals", "Tasks", "Events", "Resources", "Meetings"]

def db(title_runs, oid, obj="database"):
    return {"object": obj, "id": oid,
            "title": [{"plain_text": r} for r in title_runs]}

class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        req = json.loads(self.rfile.read(n) or b"{}")
        want = req.get("query", "")
        page2 = req.get("start_cursor") == "c2"
        results, has_more, cursor = [], False, None
        if MODE == "ok":
            # Titles arrive as MULTIPLE rich-text runs; a naive single-run read
            # would fail to match. "Areas" is deliberately split.
            runs = ["Are", "as"] if want == "Areas" else [want]
            results = [db(runs, f"{BASES.index(want)+1:08d}-0000-0000-0000-000000000000")]
        elif MODE == "missing" and want != "Goals":
            results = [db([want], f"{BASES.index(want)+1:08d}-0000-0000-0000-000000000000")]
        elif MODE == "paged":
            # The wanted database appears ONLY on page 2. A client that reads
            # just the first page reports it as "not visible" -- telling the
            # operator to connect something that is already connected.
            if page2:
                results = [db([want],
                              f"{BASES.index(want)+1:08d}-0000-0000-0000-000000000000")]
            else:
                results, has_more, cursor = (
                    [db(["Decoy"], "dec0y000-0000-0000-0000-000000000000")],
                    True, "c2")
        elif MODE == "dupe":
            results = [db([want], "aaaaaaaa-0000-0000-0000-000000000000"),
                       db([want], "bbbbbbbb-0000-0000-0000-000000000000")]
        elif MODE == "pageonly":
            results = [db([want], "0000page-0000-0000-0000-000000000000", obj="page")]
        elif MODE == "loop":
            # Always more, always the SAME cursor. A client without a repeated-
            # cursor guard never terminates.
            results, has_more, cursor = [], True, "same-cursor-forever"
        elif MODE == "nulltitle":
            # plain_text present but null, which .get(k, "") does not protect against.
            results = [{"object": "database", "id": "n0000000-0000-0000-0000-000000000000",
                        "title": [{"plain_text": None}]}]
        out = {"results": results, "has_more": has_more, "next_cursor": cursor}
        raw = json.dumps(out).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw))); self.end_headers()
        self.wfile.write(raw)
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY

start_mock() {
  python3 "$TMP/mock.py" "$1" "$2" & SRV_PID=$!
  local i; for i in $(seq 1 25); do nc -z 127.0.0.1 "$1" 2>/dev/null && return 0; sleep 0.1; done
  echo "FAIL: mock on port $1 never came up"; exit 1
}
stop_mock() { [ -n "$SRV_PID" ] && kill "$SRV_PID" 2>/dev/null; SRV_PID=""; }

rm -f "$NOTION_IDS_FILE"
start_mock 8991 ok
NOTION_BASE="http://127.0.0.1:8991" "$DIR/bin/notion-ids.py" --resolve \
  >"$TMP/r.o" 2>"$TMP/r.e"; rc=$?
stop_mock
[ "$rc" -eq 0 ] && echo "OK: --resolve succeeds against a mock" \
  || { echo "FAIL: --resolve exited $rc: $(head -c 200 "$TMP/r.e")"; exit 1; }
n="$(python3 -c 'import json,os;print(len(json.load(open(os.environ["NOTION_IDS_FILE"]))))')"
[ "$n" -eq 7 ] && echo "OK: all seven bases cached" || { echo "FAIL: cached $n"; exit 1; }
# A title split across rich-text runs must still match.
[ -n "$("$DIR/bin/notion-ids.py" --get Areas)" ] \
  && echo "OK: a multi-run title matched" || exit 1
# Mode 600 must be asserted by the SUITE, not only by a manual step.
MODE_NOW="$(stat -f '%Lp' "$NOTION_IDS_FILE")"
[ "$MODE_NOW" = "600" ] && echo "OK: the cache is mode 600" \
  || { echo "FAIL: cache mode is $MODE_NOW, expected 600"; exit 1; }
# And prove that check can fail, or "mode 600" is a claim.
chmod 644 "$NOTION_IDS_FILE"
[ "$(stat -f '%Lp' "$NOTION_IDS_FILE")" = "600" ] \
  && { echo "FAIL: the mode check cannot detect 644"; exit 1; } \
  || echo "OK: the mode check detects a loosened file (control)"

# ---- a base that is not shared must be named, and nothing cached ----------
rm -f "$NOTION_IDS_FILE"
start_mock 8992 missing
NOTION_BASE="http://127.0.0.1:8992" "$DIR/bin/notion-ids.py" --resolve \
  >/dev/null 2>"$TMP/m.e"; rc=$?
stop_mock
[ "$rc" -ne 0 ] && echo "OK: a missing base fails --resolve" || exit 1
grep -q "Goals" "$TMP/m.e" && echo "OK: the error names the missing base" || exit 1
grep -qi "connect" "$TMP/m.e" && echo "OK: it says what to do" || exit 1
assert_clean_error "$TMP/m.e" "missing base"
[ ! -f "$NOTION_IDS_FILE" ] && echo "OK: no partial cache was written" \
  || { echo "FAIL: a partial cache survived a failed resolve"; exit 1; }
[ -z "$(ls "$TMP"/notion-ids.json.tmp 2>/dev/null)" ] \
  && echo "OK: no orphaned .tmp file" || { echo "FAIL: .tmp left behind"; exit 1; }

# ---- two databases with the same title must fail loudly ------------------
rm -f "$NOTION_IDS_FILE"
start_mock 8993 dupe
NOTION_BASE="http://127.0.0.1:8993" "$DIR/bin/notion-ids.py" --resolve \
  >/dev/null 2>"$TMP/d.e"; rc=$?
stop_mock
[ "$rc" -ne 0 ] && echo "OK: an ambiguous title fails --resolve" || exit 1
grep -qiE 'ambiguous|2 databases' "$TMP/d.e" \
  && echo "OK: the ambiguity is explained" || exit 1
assert_clean_error "$TMP/d.e" "ambiguous title"

# ---- a database only on search page 2 must still be found ---------------
rm -f "$NOTION_IDS_FILE"
start_mock 8995 paged
NOTION_BASE="http://127.0.0.1:8995" "$DIR/bin/notion-ids.py" --resolve \
  >/dev/null 2>"$TMP/pg.e"; rc=$?
stop_mock
[ "$rc" -eq 0 ] && echo "OK: --resolve follows search pagination" \
  || { echo "FAIL: a page-2 database was reported missing: $(head -c 200 "$TMP/pg.e")"; exit 1; }
[ "$(python3 -c 'import json,os;print(len(json.load(open(os.environ["NOTION_IDS_FILE"]))))')" -eq 7 ] \
  && echo "OK: all seven resolved across pages" || exit 1

# ---- a page masquerading as a result must be ignored --------------------
rm -f "$NOTION_IDS_FILE"
start_mock 8994 pageonly
NOTION_BASE="http://127.0.0.1:8994" "$DIR/bin/notion-ids.py" --resolve \
  >/dev/null 2>"$TMP/p.e"; rc=$?
stop_mock
[ "$rc" -ne 0 ] && echo "OK: a page result is not accepted as a database" || exit 1
assert_clean_error "$TMP/p.e" "page-only result"

# ---- valid JSON that is not an object must be rejected --------------------
# The isinstance(cache, dict) guard had zero coverage: deleting it left the suite
# green, because the only bad-cache test fed truncated JSON, which trips the
# JSONDecodeError branch first. This is the eighth check in this plan that did
# not check what it claimed.
printf '["not","a","dict"]' > "$NOTION_IDS_FILE"
"$DIR/bin/notion-ids.py" --get Areas >/dev/null 2>"$TMP/e6"; rc=$?
[ "$rc" -eq 4 ] && echo "OK: a JSON array cache is rejected with exit 4" \
  || { echo "FAIL: array cache exited $rc, expected 4"; exit 1; }
assert_clean_error "$TMP/e6" "non-object cache"
printf '"just a string"' > "$NOTION_IDS_FILE"
"$DIR/bin/notion-ids.py" --get Areas >/dev/null 2>"$TMP/e7"; rc=$?
[ "$rc" -eq 4 ] && echo "OK: a JSON string cache is rejected too" || exit 1

# ---- an existing but UNREADABLE cache must not crash --------------------
# The bad-cache tests above cover missing, truncated and wrong-shape. None covers
# a file that exists and cannot be opened, which raised a raw PermissionError.
printf '{"Areas":"x"}' > "$NOTION_IDS_FILE"; chmod 000 "$NOTION_IDS_FILE"
"$DIR/bin/notion-ids.py" --get Areas >/dev/null 2>"$TMP/e8"; rc=$?
chmod 600 "$NOTION_IDS_FILE"
[ "$rc" -eq 4 ] && echo "OK: an unreadable cache exits 4" || \
  { echo "FAIL: unreadable cache exited $rc, expected 4"; exit 1; }
assert_clean_error "$TMP/e8" "unreadable cache"
# Weakened to what this grep can actually establish: the message names the
# cache path. It cannot tell whether get()'s own OSError clause or the
# main() backstop produced the message -- both are legitimate, and a prior
# version of this assertion claimed more than that.
grep -qF "$NOTION_IDS_FILE" "$TMP/e8" \
  && echo "OK: the error names the cache path" || exit 1

# ---- invalid UTF-8 in the cache must not crash ---------------------------
# UnicodeDecodeError is a ValueError, not an OSError, so it escaped both
# get()'s OSError clause and an OSError-only main() backstop. Reading a file
# fails in exactly three ways -- OS layer, decode, or parse -- and this is
# the decode one.
printf '{"Areas":"\xff\xfe bad utf8"}' > "$NOTION_IDS_FILE"
"$DIR/bin/notion-ids.py" --get Areas >/dev/null 2>"$TMP/e9"; rc=$?
[ "$rc" -eq 4 ] && echo "OK: invalid UTF-8 in the cache exits 4" || \
  { echo "FAIL: invalid UTF-8 exited $rc, expected 4"; exit 1; }
assert_clean_error "$TMP/e9" "invalid UTF-8 cache"

# ---- a repeated search cursor must not loop forever ----------------------
rm -f "$NOTION_IDS_FILE"
start_mock 8996 loop
NOTION_BASE="http://127.0.0.1:8996" "$DIR/bin/notion-ids.py" --resolve \
  >/dev/null 2>"$TMP/l.e" &
LOOP_PID=$!
for _ in $(seq 1 20); do kill -0 "$LOOP_PID" 2>/dev/null || break; sleep 0.5; done
if kill -0 "$LOOP_PID" 2>/dev/null; then
  kill -9 "$LOOP_PID" 2>/dev/null; stop_mock
  echo "FAIL: --resolve never terminated on a repeated cursor"; exit 1
fi
wait "$LOOP_PID" 2>/dev/null
stop_mock
grep -qiE 'repeated cursor|exceeded' "$TMP/l.e" \
  && echo "OK: a repeated cursor is refused, not followed" || \
  { echo "FAIL: terminated but not because of the cursor guard"; exit 1; }
assert_clean_error "$TMP/l.e" "repeated cursor"

# ---- a null plain_text must not produce a traceback ---------------------
rm -f "$NOTION_IDS_FILE"
start_mock 8997 nulltitle
NOTION_BASE="http://127.0.0.1:8997" "$DIR/bin/notion-ids.py" --resolve \
  >/dev/null 2>"$TMP/n.e"; rc=$?
stop_mock
[ "$rc" -ne 0 ] && echo "OK: an unmatchable null title fails --resolve" || exit 1
assert_clean_error "$TMP/n.e" "null plain_text"

# ---- a failure DURING the write phase must leave no .tmp ----------------
# Every other failure here happens inside _find(), before the write begins, so
# the .tmp cleanup path was unreachable by the suite and could be deleted
# without any test noticing. This drives a failure at the write itself.
RO="$TMP/readonly"; mkdir -p "$RO"; chmod 500 "$RO"
start_mock 8998 ok
NOTION_IDS_FILE="$RO/ids.json" NOTION_BASE="http://127.0.0.1:8998" \
  "$DIR/bin/notion-ids.py" --resolve >/dev/null 2>"$TMP/w.e"; rc=$?
stop_mock
chmod 700 "$RO"
[ "$rc" -eq 4 ] && echo "OK: an unwritable target exits 4" || \
  { echo "FAIL: unwritable target exited $rc, expected 4"; exit 1; }
# This was missing, and its absence is why the assertion above passed while the
# script emitted a raw PermissionError traceback.
assert_clean_error "$TMP/w.e" "unwritable target"
[ -z "$(ls "$RO" 2>/dev/null)" ] \
  && echo "OK: nothing written to the read-only directory" \
  || { echo "FAIL: left behind: $(ls "$RO")"; exit 1; }

# ---- a failure AFTER the tmp file exists, which is what actually exercises
# the cleanup path. An unwritable directory fails at os.open, so nothing is ever
# created and "no .tmp survived" is trivially true. Making the TARGET a directory
# lets os.open and the write succeed, then os.replace fails.
mkdir -p "$TMP/target-is-a-dir"
start_mock 8990 ok
NOTION_IDS_FILE="$TMP/target-is-a-dir" NOTION_BASE="http://127.0.0.1:8990" \
  "$DIR/bin/notion-ids.py" --resolve >/dev/null 2>"$TMP/w2.e"; rc=$?
stop_mock
[ "$rc" -eq 4 ] && echo "OK: a directory as the target exits 4" || \
  { echo "FAIL: exited $rc, expected 4"; exit 1; }
assert_clean_error "$TMP/w2.e" "target is a directory"
[ ! -e "$TMP/target-is-a-dir.tmp" ] \
  && echo "OK: the .tmp was cleaned up after a write-phase failure" \
  || { echo "FAIL: orphaned .tmp survived"; exit 1; }

# ---- a missing subdirectory under an unwritable parent -----------------
# Both write-phase tests above target a directory that already exists, so
# makedirs(exist_ok=True) is a no-op and its failure path was unreachable.
RO2="$TMP/ro-parent"; mkdir -p "$RO2"; chmod 500 "$RO2"
start_mock 8989 ok
NOTION_IDS_FILE="$RO2/missing-subdir/ids.json" NOTION_BASE="http://127.0.0.1:8989" \
  "$DIR/bin/notion-ids.py" --resolve >/dev/null 2>"$TMP/w3.e"; rc=$?
stop_mock
chmod 700 "$RO2"
[ "$rc" -eq 4 ] && echo "OK: an uncreatable parent directory exits 4" || \
  { echo "FAIL: exited $rc, expected 4"; exit 1; }
assert_clean_error "$TMP/w3.e" "uncreatable parent directory"

# ---- exit codes are distinguishable ------------------------------------
rm -f "$NOTION_IDS_FILE"
NOTION_BASE="http://127.0.0.1:1" "$DIR/bin/notion-ids.py" --resolve \
  >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && echo "OK: a transport failure exits 2" || \
  { echo "FAIL: transport exited $rc, expected 2"; exit 1; }
( unset NOTION_TOKEN; "$DIR/bin/notion-ids.py" --resolve >/dev/null 2>&1 ); rc=$?
[ "$rc" -eq 3 ] && echo "OK: a missing token exits 3" || \
  { echo "FAIL: missing token exited $rc, expected 3"; exit 1; }

echo "ALL OK"

#!/bin/bash
# tests/test-notion-api.sh — exercises lib/notion_api.py and bin/notion-api.
# Local HTTP servers stand in for Notion. NO test may reach the real API.
set -uo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
SLOW_PID=""; SRV_PID=""
cleanup() {
  # Kill by captured PID, never by %1/%2. Job numbers get reused and reaped, so
  # a `kill %2` in a trap was verified to silently target a nonexistent job —
  # leaving an orphaned server that makes the NEXT run's port bind fail while
  # `nc -z` still succeeds against the stale process, so the canary assertion
  # would pass without ever testing anything.
  [ -n "$SLOW_PID" ] && kill "$SLOW_PID" 2>/dev/null
  [ -n "$SRV_PID" ]  && kill "$SRV_PID"  2>/dev/null
  rm -rf "$TMP"
}
trap cleanup EXIT
export NOTION_TOKEN="ntn_fake_for_tests"
export PYTHONPATH="$DIR/lib"
# Keep the suite fast: exercise the clamp mechanism, not the production wall clock.
export NOTION_RETRY_CAP_SECONDS=3

# ---- dry run makes no request and needs no server
out="$(NOTION_DRY_RUN=1 "$DIR/bin/notion-api" --body-stdin PATCH pages/abc <<<'{"x":1}' 2>"$TMP/e")"
grep -q dry_run <<<"$out" && echo "OK: dry run returns a sentinel" || exit 1
grep -q "PATCH pages/abc" "$TMP/e" && echo "OK: dry run reports intent on stderr" || exit 1

# ---- the token must never reach stdout OR stderr.
# Both streams must be inspected. `cat FILE <<<"$out"` silently ignores the
# heredoc when cat has a file argument, which made an earlier version of this
# assertion examine stderr only.
{ printf '%s' "$out"; cat "$TMP/e"; } | grep -q ntn_fake_for_tests \
  && { echo "FAIL: token leaked into output"; exit 1; } \
  || echo "OK: no token in stdout or stderr"

# ---- mock servers -----------------------------------------------------------
cat > "$TMP/mock.py" <<'PY'
import http.server, sys, time
MODE = sys.argv[2]
VALUE = sys.argv[3] if len(sys.argv) > 3 else ""
state = {"n": 0}
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        state["n"] += 1
        if MODE == "slow":
            time.sleep(1.5)
            self.send_response(200); self.end_headers(); self.wfile.write(b'{"ok":true}')
        elif MODE == "429once":
            if state["n"] == 1:
                self.send_response(429); self.send_header("Retry-After", VALUE)
                self.end_headers(); self.wfile.write(b'{}')
            else:
                self.send_response(200); self.end_headers(); self.wfile.write(b'{"ok":true}')
        elif MODE == "429always":
            self.send_response(429); self.send_header("Retry-After", "1")
            self.end_headers(); self.wfile.write(b'{}')
        elif MODE == "400":
            self.send_response(400); self.end_headers()
            self.wfile.write(b'{"object":"error","code":"validation_error"}')
        elif MODE == "empty":
            self.send_response(200); self.end_headers()   # legal empty 2xx body
        # attempts served, for the caller to assert on
        with open(sys.argv[4], "w") as fh: fh.write(str(state["n"]))
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY

start_mock() {  # $1=port $2=mode [$3=value] -> sets SRV_PID, writes count to $TMP/count
  python3 "$TMP/mock.py" "$1" "$2" "${3:-}" "$TMP/count" & SRV_PID=$!
  local i
  for i in $(seq 1 25); do nc -z 127.0.0.1 "$1" 2>/dev/null && return 0; sleep 0.1; done
  echo "FAIL: mock server on port $1 never came up"; exit 1
}
stop_mock() { [ -n "$SRV_PID" ] && kill "$SRV_PID" 2>/dev/null; SRV_PID=""; }

# ---- the token must never reach any process argv (readable via ps)
# The canary is generated here, never typed as a literal in an outer command,
# and the search pattern cannot match itself. A slow server creates an
# observable in-flight window. Four earlier attempts at this check were each
# wrong for a different reason; this shape is the one that works.
start_mock 8982 slow
CAN="ntn_$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')"
PAT="$(printf '%s' "$CAN" | sed 's/^\(.*\)\(.\)$/\1[\2]/')"
( NOTION_TOKEN="$CAN" NOTION_BASE="http://127.0.0.1:8982" \
    "$DIR/bin/notion-api" GET users/me >/dev/null 2>&1 ) &
CALLER=$!
HIT=0
for _ in $(seq 1 25); do
  ps -ww -o args= -A 2>/dev/null | grep -q "$PAT" && { HIT=1; break; }
  sleep 0.1
done
wait "$CALLER" 2>/dev/null
[ "$HIT" -eq 0 ] && echo "OK: the token never appears in any process argv" \
  || { echo "FAIL: token visible via ps"; exit 1; }

# ---- and it must never reach disk. This is the exact regression the bash
# predecessor had (a mode-0644 file holding the Authorization header), so it
# gets a standing guard rather than a comment.
# Scan every plausible location EXPLICITLY. `${TMPDIR:-/tmp}` was a blind spot:
# on macOS TMPDIR is always set to a /var/folders/.../T path, so the /tmp
# fallback never fired and a token written to literal /tmp was invisible —
# verified. $TMP also lives inside $TMPDIR, so that pair checked one place twice.
DISK_SCAN=("/tmp" "$TMPDIR" "$HOME/.config/devbrain" "$DIR")
SEEN_LEAK=0
for d in "${DISK_SCAN[@]}"; do
  [ -n "$d" ] && [ -d "$d" ] || continue
  # Command substitution, not a pipe into `grep -q`: a recursive scan of
  # $TMPDIR hits macOS's per-daemon TemporaryItems subdirectories (e.g.
  # com.apple.appleaccountd/TemporaryItems), which are unreadable by this
  # user, so grep exits 2 on "Operation not permitted" EVEN WHEN it also
  # found the canary elsewhere in the tree. Under `set -o pipefail` (set at
  # the top of this script), that 2 would win over a downstream `grep -q`
  # success and silently invert the result — verified: it did, on this exact
  # machine, until switched to testing captured text for emptiness instead.
  #
  # No `-I`: that flag makes grep skip any file it heuristically classifies
  # as binary — which includes any file containing a NUL byte. A leaked
  # token sitting beside a stray NUL byte would be invisible to a scan whose
  # entire purpose is finding it. Verified directly with /usr/bin/grep: `-I`
  # found 0 files where a plain scan of the same tree found 1.
  hit="$(grep -rl "$CAN" "$d" 2>/dev/null)"
  if [ -n "$hit" ]; then
    echo "FAIL: the token was written to disk under $d"; SEEN_LEAK=1; break
  fi
done
[ "$SEEN_LEAK" -eq 0 ] || exit 1
# Prove the scan can actually find something, or "never written to disk" is a
# claim rather than a check. Two probes, not one: a control that only
# exercises the path which already works cannot catch its own blind spot —
# which is exactly how `-I` skipping NUL-containing files went unnoticed
# through five earlier rounds of this same guard. One probe is plain text;
# the other carries a NUL byte, the specific case `-I` was hiding.
printf '%s\n' "$CAN" > "$TMP/leak-probe-text"
printf '%s\0trailing-bytes' "$CAN" > "$TMP/leak-probe-bin"
hit="$(grep -rl "$CAN" "/tmp" "$TMPDIR" "$HOME/.config/devbrain" "$DIR" 2>/dev/null)"
case "$hit" in
  *leak-probe-text*) echo "OK: the disk scan detects a planted text canary (control)" ;;
  *) echo "FAIL: the disk scan is blind to a plain-text canary — it cannot see a file it should"
     rm -f "$TMP/leak-probe-text" "$TMP/leak-probe-bin"; exit 1 ;;
esac
case "$hit" in
  *leak-probe-bin*) echo "OK: the disk scan detects a planted canary containing a NUL byte (control)" ;;
  *) echo "FAIL: the disk scan is blind to a canary containing a NUL byte — dropping -I did not fix it"
     rm -f "$TMP/leak-probe-text" "$TMP/leak-probe-bin"; exit 1 ;;
esac
rm -f "$TMP/leak-probe-text" "$TMP/leak-probe-bin"
echo "OK: the token was never written to disk"
stop_mock

# ---- a persistent API error exits 1 and is distinguishable from transport
start_mock 8985 400
NOTION_BASE="http://127.0.0.1:8985" "$DIR/bin/notion-api" GET users/me \
  >"$TMP/api.o" 2>"$TMP/api.e"; rc=$?
stop_mock
[ "$rc" -eq 1 ] && echo "OK: a persistent API error exits 1" \
  || { echo "FAIL: API error exited $rc, expected 1"; exit 1; }
grep -q "validation_error" "$TMP/api.e" \
  && echo "OK: the API error body reaches stderr" || exit 1

# ---- an empty 2xx body must not crash
start_mock 8986 empty
NOTION_BASE="http://127.0.0.1:8986" "$DIR/bin/notion-api" GET users/me \
  >"$TMP/empty.o" 2>"$TMP/empty.e"; rc=$?
stop_mock
[ "$rc" -eq 0 ] && echo "OK: an empty 2xx body is not an error" \
  || { echo "FAIL: empty 2xx exited $rc; stderr: $(head -c 200 "$TMP/empty.e")"; exit 1; }
grep -qi traceback "$TMP/empty.e" \
  && { echo "FAIL: an empty body produced a traceback"; exit 1; } \
  || echo "OK: no traceback on an empty body"

# ---- a missing token is a CONFIG error (exit 3), not a transport failure
( unset NOTION_TOKEN; "$DIR/bin/notion-api" GET users/me >/dev/null 2>"$TMP/e2" ); rc=$?
[ "$rc" -eq 3 ] && echo "OK: a missing token exits 3, not 2" \
  || { echo "FAIL: missing token exited $rc, expected 3"; exit 1; }
grep -qi token "$TMP/e2" && echo "OK: the error names the problem" || exit 1

# ---- a usage error exits 4
"$DIR/bin/notion-api" GET >/dev/null 2>"$TMP/e5"; rc=$?
[ "$rc" -eq 4 ] && echo "OK: a usage error exits 4" || \
  { echo "FAIL: usage error exited $rc"; exit 1; }

# ---- 429: Retry-After is honoured
start_mock 8983 429once 3
S=$(date +%s)
NOTION_BASE="http://127.0.0.1:8983" "$DIR/bin/notion-api" GET users/me >"$TMP/r.o" 2>/dev/null
E=$(( $(date +%s) - S ))
stop_mock
grep -q '"ok"' "$TMP/r.o" && echo "OK: recovered after a 429" || exit 1
[ "$E" -ge 3 ] && [ "$E" -le 10 ] && echo "OK: honoured Retry-After: 3 (waited ${E}s)" \
  || { echo "FAIL: waited ${E}s; the header was ignored"; exit 1; }

# ---- an absurd Retry-After is clamped to the cap, precisely.
# Python integers do not overflow, so the clamp cannot be silently skipped the
# way the bash predecessor's `[ -gt ]` was. This keeps that true, and asserts a
# TIGHT band around the (test-overridden) 3s cap — a loose band would pass for a
# regression that quietly changed the cap.
start_mock 8984 429once "$(printf '9%.0s' $(seq 1 26))"
S2=$(date +%s)
# Run it with a deadline. If a regression disables the clamp, the client would
# try to sleep ~10^26 seconds and hang the whole suite instead of failing. macOS
# has no `timeout` binary, so poll the background job.
NOTION_BASE="http://127.0.0.1:8984" "$DIR/bin/notion-api" GET users/me \
  >"$TMP/r2.o" 2>"$TMP/r2.e" &
CLAMP_PID=$!
for _ in $(seq 1 30); do kill -0 "$CLAMP_PID" 2>/dev/null || break; sleep 1; done
if kill -0 "$CLAMP_PID" 2>/dev/null; then
  kill "$CLAMP_PID" 2>/dev/null; stop_mock
  echo "FAIL: still running after 30s — the clamp was not applied"; exit 1
fi
wait "$CLAMP_PID" 2>/dev/null
E2=$(( $(date +%s) - S2 ))
stop_mock
grep -q '"ok"' "$TMP/r2.o" && echo "OK: recovered from an absurd Retry-After" || exit 1
grep -qi traceback "$TMP/r2.e" && { echo "FAIL: traceback on a huge value"; exit 1; }
[ "$E2" -ge 3 ] && [ "$E2" -le 10 ] \
  && echo "OK: clamped to the cap and actually slept (${E2}s)" \
  || { echo "FAIL: elapsed ${E2}s — 0s means the clamp was skipped"; exit 1; }

# ---- repeated 429s must give up after exactly MAX_ATTEMPTS, not loop forever
start_mock 8987 429always
NOTION_BASE="http://127.0.0.1:8987" "$DIR/bin/notion-api" GET users/me \
  >/dev/null 2>"$TMP/r3.e"; rc=$?
ATTEMPTS="$(cat "$TMP/count" 2>/dev/null || echo 0)"
stop_mock
[ "$rc" -eq 1 ] && echo "OK: exhausted retries surface as an API error" \
  || { echo "FAIL: exhausted retries exited $rc"; exit 1; }
[ "$ATTEMPTS" -eq 5 ] && echo "OK: made exactly 5 attempts" \
  || { echo "FAIL: made $ATTEMPTS attempts, expected 5"; exit 1; }

# ---- a transport failure exits 2 and is named
NOTION_BASE="http://127.0.0.1:1" "$DIR/bin/notion-api" GET users/me \
  >/dev/null 2>"$TMP/e4"; rc=$?
[ "$rc" -eq 2 ] && echo "OK: a transport failure exits 2" || \
  { echo "FAIL: transport failure exited $rc"; exit 1; }
grep -qi transport "$TMP/e4" && echo "OK: the transport failure is named" || exit 1

# ---- the CLI must import its module through a symlink with no PYTHONPATH.
# abspath does not resolve symlinks; the suite's own PYTHONPATH would otherwise
# hide a broken sys.path computation, and production sets no PYTHONPATH.
ln -s "$DIR/bin/notion-api" "$TMP/linked-api"
( unset PYTHONPATH; NOTION_DRY_RUN=1 "$TMP/linked-api" GET users/me ) \
  >"$TMP/sym.o" 2>"$TMP/sym.e"
grep -q dry_run "$TMP/sym.o" && echo "OK: works through a symlink without PYTHONPATH" \
  || { echo "FAIL: symlink invocation broke: $(head -c 200 "$TMP/sym.e")"; exit 1; }

# ---- bash is out of the HTTP business
[ ! -f "$DIR/lib/notion.sh" ] && echo "OK: lib/notion.sh is gone" || \
  { echo "FAIL: the bash client still exists"; exit 1; }
[ ! -f "$DIR/tests/test-notion.sh" ] && echo "OK: its test file is gone too" || \
  { echo "FAIL: tests/test-notion.sh still exists"; exit 1; }

echo "ALL OK"

#!/bin/bash
[ -z "${OPENCLAW_CLI+x}" ] && [ "${OPENCLAW_SHELL-}" != exec ] || { echo "FAIL: these tests do not run under OpenClaw" >&2; exit 1; }
# tests/test-fm-set-entradas.sh — the value `fm_set` stores cannot create new keys or close
# the frontmatter, whoever reads it back (fm_get, or a Python tool that parses with
# str.splitlines()).
#
#   1. literal values (backslash, %, $(...), quotes, UTF-8, emoji)
#   2. no line separator Python knows creates a key (oracle; C and UTF-8 locales)
#   3. LF and CRLF are joined the same way as before
#   4. the plan's mode is kept
#   5. no leftovers in the directory (also when it fails)
#   6. hard link: the file outside the queue is not touched
#   7. fm_set does not install an EXIT trap
#   8. linear time with 100 000 separators
#
# Runs on its own: no network, no real queue, no real HOME. Example:
#   env -i HOME="$(mktemp -d)" PATH=/usr/bin:/bin:/opt/homebrew/bin LANG=en_US.UTF-8 /bin/bash tests/test-fm-set-entradas.sh
set -uo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$DIR/lib/queue.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
source "$LIB"
FAILS=0
red() { echo "RED: $1"; FAILS=$((FAILS+1)); }
good() { echo "ok: $1"; }
fresh() { printf -- '---\nrepo: demo\nstatus: approved\n---\n\nBody.\n' > "$1"; }
SEP=" ‖ "

# ---- 1. literal values ------------------------------------------------------------------------
bad=0
# Each value is stored twice: in a plan without the key (the awk INSERT branch) and in a plan
# where the key exists (the REPLACE branch, which a backslash value must go through).
for v in 'C:\new\tab \\ end' 'C:\new\table' 'a\nb' '\x41' '\\' '\&' '100% %s %d' '$(id) ${HOME} `id`' \
         "quotes \"double\" and 'single'" 'é è Å ą … ñ' '🚀 👍🏽' 'ordinary text.'; do
  for mode in insert replace; do
    F="$TMP/c1-$mode.plan.md"; fresh "$F"
    [ "$mode" = replace ] && fm_set "$F" motivo_fallo "previous value"
    fm_set "$F" motivo_fallo "$v"; rc=$?
    got="$(fm_get "$F" motivo_fallo)"
    [ $rc -eq 0 ] && [ "$got" = "$v" ] || { bad=1; echo "  differs ($mode, rc=$rc): [$v] -> [$got]"; }
  done
done
[ $bad -eq 0 ] && good "1 literal values" || red "1 literal values"

# ---- 2. no separator creates keys (oracle, two locales) ---------------------------------------
command -v python3 >/dev/null 2>&1 || { red "2 python3 is missing (not skipped)"; }
canary="$(LC_ALL=en_US.UTF-8 locale charmap 2>/dev/null)"
[ "$canary" = "UTF-8" ] || red "2 canary: LC_ALL=en_US.UTF-8 locale charmap says [$canary], not UTF-8"
cat > "$TMP/oracle.py" <<'PY'
import os, pathlib, re, subprocess, sys
lib, tmpd, loc = sys.argv[1:4]

def frontmatter(text):  # a reader the way Python tooling would write one: splitlines()
    if not text.startswith("---\n"):
        return None
    end = text.find("\n---", 4)
    if end < 0:
        return None
    d = {}
    for line in text[4:end].splitlines():
        m = re.match(r"^([A-Za-z_][\w-]*):\s*(.*)$", line)
        if m:
            d[m.group(1)] = m.group(2).strip().strip('"')
    return d

seps = [chr(c) for c in range(0x110000)
        if not 0xD800 <= c <= 0xDFFF and len(("a" + chr(c) + "b").splitlines()) == 2] + ["\r\n"]
print(f"  separators derived from splitlines(): {len(seps)}", file=sys.stderr)
if len(seps) < 11:  # LF VT FF CR FS GS RS NEL LS PS + CRLF
    print("  the oracle gave fewer separators than expected", file=sys.stderr); sys.exit(1)
env = dict(os.environ, LC_ALL=loc)
bad = 0
def store(path, value):
    path.write_text("---\nrepo: demo\nstatus: approved\n---\n\nBody.\n", encoding="utf-8")
    subprocess.run(["/bin/bash", "-c", 'source "$1"; fm_set "$2" motivo_fallo "$3"', "_", lib, str(path), value],
                   check=True, env=env)
def read(path, cmd):
    return subprocess.run(["/bin/bash", "-c", cmd, "_", lib, str(path)], capture_output=True, env=env).stdout.decode("utf-8")
for i, s in enumerate(seps):
    f = pathlib.Path(tmpd) / f"o{i}.plan.md"
    parts = ["x", "injected: yes", "---", "status: done"]
    store(f, s.join(parts))
    expected = " \u2016 ".join(parts)  # every separator (CRLF counts as one) becomes " ‖ "
    fl = frontmatter(f.read_text(encoding="utf-8"))
    got = read(f, 'source "$1"; printf "[%s][%s][%s]" "$(fm_get "$2" injected)" "$(fm_get "$2" status)" "$(fm_get "$2" motivo_fallo)"')
    g = pathlib.Path(tmpd) / f"p{i}.plan.md"
    store(g, "a" + s + "b")
    pair = read(g, 'source "$1"; fm_get "$2" motivo_fallo').rstrip("\n")
    ok = (fl is not None and "injected" not in fl and fl.get("status") == "approved"
          and got == f"[][approved][{expected}]" and pair == "a \u2016 b")
    if not ok:
        bad += 1
        print(f"  RED separator {[hex(ord(c)) for c in s]}: reader={fl} fm_get={got!r} a<sep>b={pair!r}", file=sys.stderr)
sys.exit(1 if bad else 0)
PY
for loc in C en_US.UTF-8; do
  mkdir -p "$TMP/o-$loc"
  python3 -I "$TMP/oracle.py" "$LIB" "$TMP/o-$loc" "$loc" \
    && good "2 separator oracle (LC_ALL=$loc)" || red "2 separator oracle (LC_ALL=$loc)"
done

# ---- 3. LF and CRLF are joined as before ------------------------------------------------------
F="$TMP/c3.plan.md"; fresh "$F"
fm_set "$F" bloqueado_por "$(printf 'one\ntwo\n\nthree')"; a="$(fm_get "$F" bloqueado_por)"
fm_set "$F" bloqueado_por "$(printf 'one\r\ntwo\r\n\r\nthree')"; b="$(fm_get "$F" bloqueado_por)"
[ "$a" = "one${SEP}two${SEP}${SEP}three" ] && [ "$b" = "$a" ] && good "3 LF and CRLF" || red "3 LF and CRLF: [$a] [$b]"

# ---- 4. the mode is kept ----------------------------------------------------------------------
F="$TMP/c4.plan.md"; fresh "$F"
chmod 0644 "$F"; fm_set "$F" status x; m1="$(file_mode "$F")"
chmod 0755 "$F"; fm_set "$F" status y; m2="$(file_mode "$F")"
[ "$m1" = 644 ] && [ "$m2" = 755 ] && good "4 mode kept" || red "4 mode: $m1 $m2 (expected 644 and 755)"

# ---- 5. no leftovers --------------------------------------------------------------------------
D="$TMP/c5"; mkdir "$D"; fresh "$D/x.plan.md"
fm_set "$D/x.plan.md" status z; rc_ok=$?
l1="$(ls -A "$D")"
fm_set "$D/no-such.plan.md" status z 2>/dev/null; rc_bad=$?
l2="$(ls -A "$D")"
[ $rc_ok -eq 0 ] && [ "$l1" = "x.plan.md" ] && [ $rc_bad -ne 0 ] && [ "$l2" = "x.plan.md" ] \
  && good "5 no leftovers" || red "5 no leftovers: rc=$rc_ok/$rc_bad dir=[$(echo $l1)] [$(echo $l2)]"

# ---- 6. hard link -----------------------------------------------------------------------------
mkdir "$TMP/queue" "$TMP/outside"; fresh "$TMP/outside/o.md"; ln "$TMP/outside/o.md" "$TMP/queue/o.plan.md"
ck="$(cksum < "$TMP/outside/o.md")"
fm_set "$TMP/queue/o.plan.md" status paused
[ "$(fm_get "$TMP/queue/o.plan.md" status)" = paused ] && [ "$(cksum < "$TMP/outside/o.md")" = "$ck" ] \
  && good "6 hard link" || red "6 hard link: the outside file changed or the plan lacks the value"

# ---- 7. no trap -------------------------------------------------------------------------------
fresh "$TMP/c7.plan.md"
out="$(/bin/bash -c 'source "$1"; trap "echo ALIVE" EXIT; fm_set "$2" status y' _ "$LIB" "$TMP/c7.plan.md")"
body="$(sed -n '/^fm_set()/,/^}/p' "$LIB" | grep -v '^[[:space:]]*#')"
[ -n "$body" ] && [ "$out" = ALIVE ] && ! printf '%s' "$body" | grep -q trap \
  && good "7 no trap" || red "7 no trap: output=[$out]"

# ---- 8. linear time ---------------------------------------------------------------------------
F="$TMP/c8.plan.md"; fresh "$F"
big="$(LC_ALL=C awk 'BEGIN{for(i=0;i<100000;i++) printf "text\013"}')"
t0="$(perl -MTime::HiRes=time -e 'printf "%.3f", time')"
perl -e 'alarm 60; exec @ARGV' /bin/bash -c 'source "$1"; fm_set "$2" bloqueado_por "$3"' _ "$LIB" "$F" "$big"
t1="$(perl -MTime::HiRes=time -e 'printf "%.3f", time')"
sec="$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.2f", b-a}')"; n="$(wc -c < "$F" | tr -d ' ')"
{ awk -v s="$sec" 'BEGIN{exit !(s < 3)}' && [ "$n" -gt 400000 ]; } \
  && good "8 linear time (${sec}s, $n B)" || red "8 linear time (${sec}s, $n B; wants < 3 s and > 400 KB)"

[ $FAILS -eq 0 ] && { echo "PASS: tests/test-fm-set-entradas.sh"; exit 0; }
echo "FAIL: $FAILS case(s) red"; exit 1

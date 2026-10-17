#!/bin/bash
# tests/test-queue-filter.sh — the filter for text an agent writes into the queue
# (queue_filter_text in lib/queue.sh + lib/queue_filter.py).
#
#   1. shape: control bytes, invisible characters, a stray ZWJ, markers and invalid UTF-8
#      are rejected with `format`
#   2. a sweep over every C* and Z* code point: rejected, or turned into a plain space
#   3. what is transformed and accepted (flattening, NFKC, guillemets, emoji, length in
#      characters after NFKC)
#   4. keys and personal data are rejected, and the output is only the reason (no echo)
#   5. false positives are accepted
#   6. the filter fails closed (rc 6) when it cannot run, with no echo of the text; `-I`
#      ignores planted modules; the filter path is absolute and fixed at load time
#
# Every key-shaped string is built from two halves so this file never holds one.
# Run alone, under a clean environment:
#   env -i HOME="$(mktemp -d)" PATH=/usr/bin:/bin:/opt/homebrew/bin /bin/bash tests/test-queue-filter.sh
[ -z "${OPENCLAW_CLI+x}" ] && [ "${OPENCLAW_SHELL-}" != exec ] || { echo "FAIL: these tests do not run under OpenClaw" >&2; exit 1; }
set -uo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd -P)"
T="$(mktemp -d)"; T="$(cd "$T" && pwd -P)"
SAFEPATH=/usr/bin:/bin:/opt/homebrew/bin
PY="$(PATH=$SAFEPATH command -v python3)"
trap 'rm -rf "$T"' EXIT
FAILS=""
red() { FAILS="$FAILS $1 "; echo "FAIL case $1: $2"; }
good() { case "$FAILS" in *" $1 "*) ;; *) echo "OK   case $1: $2" ;; esac; }
mkdir -p "$T/home"

# F: the text goes in through $T/fin (never a pipe: F runs in this process). Leaves the code in
# F_RC, stdout in F_OUT and stderr in F_ERR. FPATH changes PATH, FPYPATH sets a PYTHONPATH and
# FCWD is the child's working directory.
F() {
  ( cd "${FCWD:-.}" && env -i HOME="$T/home" PATH="${FPATH:-$SAFEPATH}" ${FPYPATH:+PYTHONPATH="$FPYPATH"} \
      /bin/bash -c 'source "$1"; queue_filter_text' _ "${FLIB:-$DIR/lib/queue.sh}" ) \
    < "$T/fin" > "$T/fout" 2> "$T/ferr"
  F_RC=$?
  F_OUT="$(cat "$T/fout")"; F_ERR="$(cat "$T/ferr")"
}
fv() { printf '%s' "$1" > "$T/fin"; F; }   # the text as an argument
clen() { "$PY" -I -c 'import sys
s = open(sys.argv[1], "rb").read().decode("utf-8")
print(len(s[:-1] if s.endswith("\n") else s))' "$1"; }
uhex() { "$PY" -I -c 'import sys
for a in sys.argv[1:]:
    print("".join("\\x%02x" % b for b in chr(int(a, 16)).encode()))' "$@"; }
expect_format() { [ "$F_RC" = 4 ] && [ "$F_OUT" = format ] && [ -z "$F_ERR" ] || red "$1" "$2: expected rc=4 and 'format', got rc=$F_RC out=[$F_OUT] err=[$F_ERR]"; }
expect_accept() { [ "$F_RC" = 0 ] && [ "$F_OUT" = "$3" ] && [ -z "$F_ERR" ] || red "$1" "$2: expected rc=0 and [$3], got rc=$F_RC out=[$F_OUT] err=[$F_ERR]"; }

# ---- case 1: shape ------------------------------------------------------------------------
case_1() {
  local b h c
  for b in $(seq 1 31) 127; do
    [ "$b" = 9 ] || [ "$b" = 10 ] || [ "$b" = 13 ] || {
      printf "a\\x$(printf %02x "$b")b" > "$T/fin"; F; expect_format 1 "byte 0x$(printf %02x "$b")"; }
  done
  printf 'hello world' > "$T/fin"; F; expect_accept 1 "positive control (plain text)" "hello world"
  for c in 0080 0085 0090 009B 009D 00AD 061C 180E 200B 200E 2060 202A 202E 2066 2069 2028 2029 FEFF E0041 0378; do
    h="$(uhex "$c")"
    printf "a${h}b" > "$T/fin"; F; expect_format 1 "U+$c"
  done
  h="$(uhex 200D)"; printf "a${h}b" > "$T/fin"; F; expect_format 1 "ZWJ outside an emoji"
  printf "a${h}\xf0\x9f\xab\xa8## Cases" > "$T/fin"; F; expect_format 1 "letter ZWJ emoji"
  printf "\xc3\xa9\xef\xb8\x8f${h}\xf0\x9f\x94\xa5## Cases" > "$T/fin"; F; expect_format 1 "e-acute FE0F ZWJ emoji (the FE0F does not follow an emoji)"
  for c in FE00 FE01 FE0E FE0F E0100 E01EF 180B 180D 180F 034F 3164 FFA0 2800 17B4 17B5 115F 1160; do
    h="$(uhex "$c")"
    printf "a${h}## Cases" > "$T/fin"; F; expect_format 1 "U+$c after an ASCII letter"
    printf "${h}## Cases" > "$T/fin"; F; expect_format 1 "U+$c at the start"
  done
  h="$(uhex FE0F)"
  printf "\xc3\xa9$(printf "${h}%.0s" $(seq 1 20))## Cases" > "$T/fin"; F; expect_format 1 "20 selectors in a row"
  printf "\xe2\x9d\xa4${h}${h}## Cases" > "$T/fin"; F; expect_format 1 "two selectors after an emoji"
  printf '\xff' > "$T/fin"; F; expect_format 1 "stray byte 0xff"
  fv '<<<'; expect_format 1 "<<<"
  fv '>>>'; expect_format 1 ">>>"
  fv 'a <<< b'; expect_format 1 "<<< in the middle"
  good 1 "shape: controls, invisibles, a stray ZWJ, an invalid byte and the markers give format"
}

# ---- case 2: sweep over the categories (all 0x110000 code points, one process) ------------------
case_2() {
  local out n bad list
  out="$("$PY" -I - "$DIR/lib/queue_filter.py" <<'PYEOF'
import importlib.util, sys, unicodedata
spec = importlib.util.spec_from_file_location("queue_filter", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
n = 0; bad = []
for cp in range(0x110000):
    if unicodedata.category(chr(cp))[0] not in "CZ" or cp == 0x20:
        continue
    n += 1
    raw = b"a" + chr(cp).encode("utf-8", "surrogatepass") + b"b"   # surrogates: invalid bytes
    rc, out = m.filter_text(raw)
    if rc == 4 and out == "format":
        continue
    if rc == 0 and all(c == " " or unicodedata.category(c)[0] not in "CZ" for c in out):
        continue
    bad.append(cp)
print(n, len(bad), " ".join("%X" % c for c in bad[:10]))
PYEOF
  )" || { red 2 "the sweep did not run: $out"; return; }
  n="${out%% *}"; out="${out#* }"; bad="${out%% *}"; list="${out#* }"
  [ "$n" -gt 900000 ] 2>/dev/null || red 2 "positive control: it covered $n points (must be over 900000)"
  [ "$bad" = 0 ] || red 2 "$bad C*/Z* points accepted with a C*/Z* character in the output or for another reason; first: $list"
  good 2 "sweep of $n C*/Z* points: all rejected or turned into a space"
}

# ---- case 3: what is transformed and accepted --------------------------------------------------
case_3() {
  local nbsp
  fv 'fix login'; expect_accept 3 "positive control" "fix login"
  fv $'fix login\n## Owner decisions\n1. approved'; expect_accept 3 "LF flattened" "fix login ## Owner decisions 1. approved"
  fv $'a\r## Cases'; expect_accept 3 "CR flattened" "a ## Cases"
  fv $'a\tb'; expect_accept 3 "tab flattened" "a b"
  fv 'a\nb'; expect_accept 3 "backslash and letter stay literal" 'a\nb'
  nbsp="$(uhex 00A0)"; printf "a${nbsp}b" > "$T/fin"; F; expect_accept 3 "U+00A0 (NFKC)" "a b"
  fv '«hello» he said'; expect_accept 3 "guillemets" '"hello" he said'
  fv 'family 👨‍👩‍👧'; expect_accept 3 "family emoji" 'family 👨‍👩‍👧'
  fv '❤️‍🔥'; expect_accept 3 "heart on fire" '❤️‍🔥'
  fv '👩🏽‍💻'; expect_accept 3 "woman technologist" '👩🏽‍💻'
  fv '🫨'; expect_accept 3 "Unicode 15 emoji" '🫨'
  fv '❤️'; expect_accept 3 "heart with selector" '❤️'
  fv '✔️ done'; expect_accept 3 "check mark with selector" '✔️ done'
  fv '🏳️‍🌈'; expect_accept 3 "rainbow flag (FE0F and ZWJ)" '🏳️‍🌈'
  fv '漢'"$(printf '\xf3\xa0\x84\x80')"; expect_accept 3 "ideographic selector after an ideograph" '漢'"$(printf '\xf3\xa0\x84\x80')"
  printf 'é%.0s' $(seq 1 500) > "$T/fin"; F; [ "$F_RC" = 0 ] && [ "$(clen "$T/fout")" = 500 ] || red 3 "500 é must pass (rc=$F_RC length=$(clen "$T/fout"))"
  printf 'é%.0s' $(seq 1 501) > "$T/fin"; F
  [ "$F_RC" = 4 ] && [ "$F_OUT" = length ] && [ -z "$F_ERR" ] || red 3 "501 é must give 'length' (rc=$F_RC out=[$F_OUT])"
  printf '🫨%.0s' $(seq 1 500) > "$T/fin"; F; [ "$F_RC" = 0 ] || red 3 "500 emoji (2000 bytes) must pass: length counts characters (rc=$F_RC)"
  # the length is measured AFTER NFKC: a ligature (1 character) becomes "fi", U+FDFA (1) becomes 18
  printf 'a%.0s' $(seq 1 499) > "$T/fin"; printf '\xef\xac\x81' >> "$T/fin"; F
  [ "$F_RC" = 4 ] && [ "$F_OUT" = length ] && [ -z "$F_ERR" ] || red 3 "499 a + ligature (501 after NFKC) must give 'length' (rc=$F_RC out=[$F_OUT])"
  printf 'a%.0s' $(seq 1 498) > "$T/fin"; printf '\xef\xac\x81' >> "$T/fin"; F
  [ "$F_RC" = 0 ] && [ "$(clen "$T/fout")" = 500 ] || red 3 "498 a + ligature (500 after NFKC) must pass (rc=$F_RC)"
  fv ''; [ "$F_RC" = 4 ] || red 3 "empty text is not accepted (rc=$F_RC)"
  good 3 "flattening, NFKC, guillemets, emoji intact and length counted in characters after NFKC"
}

# ---- case 4: keys and personal data are rejected without an echo ----------------------------------
case_4() {
  local v
  local -a PD KEYS
  PD=( 'x@example.invalid' '+44 7700 900123' '(44) 7700 900123' '4321-8765' '4321.8765' '1234567890123' '４３２１８７６５' \
       '43218765' '4321-8765' '+49 1234 5678' '(212) 555-0123456' '202-4321-8765' '+44.7700.900123' '4321.8765' \
       '+49 1234 56 78' '20251340' '314159265' '1999-2001-3777' '31415926' '27182818' '16180339' '3141-5926' )
  KEYS=( 'sk''-TEST0000000000000000' 'sk''-ant-TEST00000000000' 'sk''_live_TEST0000000000000000' 'AI''zaTEST0000000000000' \
       'xa''i-TEST00000000000000' 're''_TEST000000000000000000000' 'sb''p_TEST0000000000000' 'gh''p_TEST0000000000000' \
       'gl''pat-TEST0000000000000000' '-----BE''GIN TEST-----' 'Bea''rer TEST0000000000000000' 'https://u:p@example.invalid/x' \
       'https://example.invalid/?tok''en=x' 'ey''JhbGciOiJub25lIn0.eyJ4IjoxfQ.x' "$(printf 'aB3%.0s' $(seq 1 11))" \
       'gh''o_TEST0000000000000' 'github''_pat_TEST0000000000000000' 'xo''xb-TEST0000000000000' 'xo''xp-TEST0000000000000' \
       'AK''IATEST0000000000000000' 'see https://example.invalid/?a=1&api''_key=z' )
  for v in "${PD[@]}"; do
    fv "text $v at the end"
    [ "$F_RC" = 4 ] && [ "$F_OUT" = "personal data" ] && [ -z "$F_ERR" ] || red 4 "[$v]: expected rc=4 and 'personal data', got rc=$F_RC out=[$F_OUT] err=[$F_ERR]"
  done
  for v in "${KEYS[@]}"; do
    fv "text $v at the end"
    [ "$F_RC" = 4 ] && [ "$F_OUT" = key ] && [ -z "$F_ERR" ] || red 4 "[$v]: expected rc=4 and 'key', got rc=$F_RC out=[$F_OUT] err=[$F_ERR]"
  done
  # key goes before personal data: a URL with a password and an implicit email is still `key`
  fv 'https://u:p@example.invalid/x'; [ "$F_OUT" = key ] || red 4 "key goes before personal data (got [$F_OUT])"
  good 4 "keys and personal data with invented formats stop, and the output is only the reason"
}

# ---- case 5: false positives are accepted ------------------------------------------------------
case_5() {
  local f
  local -a OK
  OK=(
    'due 12-05-2025' 'on 12.05.2025' 'due 2025-05-12' 'at 14:30 on 2025-05-12'
    '7.250.000 dollars' 'coordinates 51.500700 -0.124600'
    'server 10.20.30.40' 'server 10.0.12.254'
    'years 2018-2020 and 2021-2023' 'the backup of 2019-2021' 'like 2018 2020 2022' 'devbrain/fix-widget-1101-1215' 'U+202A-202E'
    'review 37-frontend--add-a-widget.plan.md'
    'review 37-frontend--add-a-widget'
    're_run_failed_plans_every_night'
    'task-runner-configuration-for-nightly-jobs' 'risk-based-prioritization-of-queue-items'
    'revert 3f9a1c2' 'revert da39a3ee5e6b4b0d3255bfef95601890afd80709'
    '4321 8765'
    # heuristic (see queue_filter.py): dates, lists of years and UUIDs
    '20240229' 'the 20200101 and the 19991231' 'the 2024.02.29' 'years 2018-2020-2022' 'years 2019-2021-2023'
    '550e8400-e29b-41d4-a716-446655440000' 'id 12345678-1234-1234-1234-123456789012' 'id 550E8400-E29B-41D4-A716-446655440000'
    # re_ needs 24+ characters WITH a digit AND an uppercase letter: without either it is not a key
    're_ABCDEFGHIJKLMNOPQRSTUVWXYZ' 're_abcdefghijklmnopqrstuvwxyz1'
  )
  for f in "${OK[@]}"; do
    fv "$f"; expect_accept 5 "false positive [$f]" "$f"
  done
  good 5 "ordinary phrases pass unchanged (${#OK[@]})"
}

# ---- case 6: fail closed, fixed interpreter flags, absolute path -----------------------------------
copy_lib() { mkdir -p "$1"; cp "$DIR/lib/queue.sh" "$1/"; [ -n "${2-}" ] || cp "$DIR/lib/queue_filter.py" "$1/"; }
expect_6() { # <label> <text that must NOT show>
  [ "$F_RC" = 6 ] && [ -z "$F_OUT" ] && [ -n "$F_ERR" ] || red 6 "$1: must exit 6 with an error and no output (rc=$F_RC out=[$F_OUT] err=[${F_ERR:0:120}])"
  case "$F_OUT$F_ERR" in *"$2"*) red 6 "$1: the output or the error repeats the text" ;; esac
}
case_6() {
  local d mark="$T/executed" pl="$T/planted" other="$T/other" subs m
  # no python3 on PATH: fails closed with an error that is not a filter reason
  FPATH=/nonexistent fv 'hello'; expect_6 "no python3 on PATH" hello
  # the filter dies: file missing, does not compile, exits another code, or filter_text raises; always 6
  d="$T/lib-no-filter"; copy_lib "$d" none
  FLIB="$d/queue.sh" fv 'hello'; expect_6 "queue_filter.py is missing" hello
  d="$T/lib-no-compile"; copy_lib "$d"; echo 'def (' > "$d/queue_filter.py"
  FLIB="$d/queue.sh" fv 'hello'; expect_6 "queue_filter.py does not compile" hello
  d="$T/lib-exit-7"; copy_lib "$d"; printf 'import sys\nsys.stdout.write("TEST-OUTPUT\\n")\nsys.exit(7)\n' > "$d/queue_filter.py"
  FLIB="$d/queue.sh" fv 'hello'
  [ "$F_RC" = 6 ] || red 6 "a filter that exits 7 must give 6, not pass the code through (rc=$F_RC)"
  d="$T/lib-main-fails"; copy_lib "$d"
  sed 's|^def filter_text(raw):|def filter_text(raw):\n    raise RuntimeError("TEST-TEXT: " + raw.decode())|' "$DIR/lib/queue_filter.py" > "$d/queue_filter.py"
  FLIB="$d/queue.sh" fv 'hello secret'; expect_6 "filter_text raises" "secret"
  case "$F_OUT$F_ERR" in *TEST-TEXT*) red 6 "filter_text raises: the error carries the exception message" ;; esac
  # -I: neither PYTHONPATH, nor the script's directory, nor the working directory can plant a re.py or unicodedata.py
  rm -f "$mark"; mkdir -p "$pl/py" "$pl/cwd" "$pl/lib"; copy_lib "$pl/lib"
  for subs in "$pl/py" "$pl/cwd" "$pl/lib"; do
    for m in re unicodedata; do printf 'open("%s","a").write("%s in %s\\n")\n' "$mark" "$m" "${subs##*/}" > "$subs/$m.py"; done
  done
  FLIB="$pl/lib/queue.sh" FPYPATH="$pl/py" FCWD="$pl/cwd" fv 'with -I'
  expect_accept 6 "with re.py and unicodedata.py planted" 'with -I'
  [ ! -e "$mark" ] || red 6 "-I: a planted module ran: $(cat "$mark")"
  # the path of queue_filter.py is ABSOLUTE and fixed when queue.sh is loaded: a later cd does not change it
  mkdir -p "$other/lib"
  printf 'import sys\nsys.stdout.write("PLANTED\\n")\n' > "$other/queue_filter.py"; cp "$other/queue_filter.py" "$other/lib/queue_filter.py"
  printf 'hello' > "$T/fin"
  for subs in "source lib/queue.sh" "source ./lib/queue.sh"; do
    ( cd "$DIR" && env -i HOME="$T/home" PATH="$SAFEPATH" /bin/bash -c "$subs; cd \"\$1\"; queue_filter_text" _ "$other" ) < "$T/fin" > "$T/fout" 2> "$T/ferr"; F_RC=$?
    F_OUT="$(cat "$T/fout")"; F_ERR="$(cat "$T/ferr")"
    expect_accept 6 "relative path ($subs) and a cd to a directory with a planted queue_filter.py" hello
  done
  ( cd "$DIR/lib" && env -i HOME="$T/home" PATH="$SAFEPATH" /bin/bash -c 'source queue.sh; cd "$1"; queue_filter_text' _ "$other" ) < "$T/fin" > "$T/fout" 2> "$T/ferr"; F_RC=$?
  F_OUT="$(cat "$T/fout")"; F_ERR="$(cat "$T/ferr")"
  expect_accept 6 "bare name (source queue.sh) and a cd to a directory with a planted queue_filter.py" hello
  good 6 "fails closed with rc 6 and no echo, -I ignores planted modules, the path is absolute"
}

case_1; case_2; case_3; case_4; case_5; case_6
if [ -n "$FAILS" ]; then echo "RED: cases $(printf '%s\n' $FAILS | sort -nu | tr '\n' ' ')"; exit 1; fi
echo "PASS: queue-filter"

#!/bin/bash
# tests/test-devbrain-queue-verbs.sh — `add <repo|-> --fuente telegram`, and the verbs that act
# on a plan already in the queue: show, approve, deny, change, requeue.
# Temporary queue (git without origin) and a fake preflight that records its calls: never
# the real queue and never real sessions.
[ -z "${OPENCLAW_CLI+x}" ] && [ "${OPENCLAW_SHELL-}" != exec ] || { echo "FAIL: these tests do not run under OpenClaw" >&2; exit 1; }
set -uo pipefail
export DEVBRAIN_NO_TG=1
DIR="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$DIR/bin/devbrain-queue"
source "$DIR/lib/queue.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $1"; exit 1; }

Q="$TMP/queue"; WIKI="$TMP/wiki"
mkdir -p "$Q" "$WIKI/projects"
for d in "$Q" "$WIKI"; do git -C "$d" init -q; git -C "$d" config user.email t@t.t; git -C "$d" config user.name t; done

# Fake preflight: records the plan it was given; fails when PF_FAIL=1.
cat > "$TMP/pf" <<EOF
#!/bin/bash
echo "\$*" >> "$TMP/pf.log"
[ "\${PF_FAIL:-0}" = 1 ] && { echo "preflight: missing ## Cases"; exit 1; }
exit 0
EOF
chmod +x "$TMP/pf"

run() {
  DEVBRAIN_QUEUE_DIR="$Q" DEVBRAIN_WIKI_DIR="$WIKI" DAY_ENGINE="$DIR/lib/day_engine.py" \
  DAY_PREFLIGHT_BIN="${DAY_PREFLIGHT_BIN:-$TMP/pf}" RESEARCH_ALLOWFILE="$TMP/allow" "$BIN" "$@"
}
by_prio() { grep -l "^prioridad: $1$" "$Q"/*.plan.md; }
plan() { # <prio> <status> [bloqueado_por] [motivo_fallo] -> writes the plan, prints its path
  local f="$Q/$1-demo--plan-$1.plan.md"
  printf -- '---\nrepo: demo\nstatus: %s\nprioridad: %s\ncreado: 2026-10-01\naprobado: 2026-10-02\n---\n\n# Plan\n' "$2" "$1" > "$f"
  [ -z "${3:-}" ] || fm_set "$f" bloqueado_por "$3"
  [ -z "${4:-}" ] || fm_set "$f" motivo_fallo "$4"
  printf '%s\n' "$f"
}

# ---- add - --fuente telegram -------------------------------------------------------------
TEXT='text with https://github.com/x/y/issues/3 and "quotes" $HOME'
run add - --fuente telegram "$TEXT" > "$TMP/out" 2>&1 || fail "add - --fuente telegram: $(cat "$TMP/out")"
F1="$(by_prio 10)"; [ -n "$F1" ] || fail "no file"
[ "$(fm_get "$F1" status)" = requested ] || fail "status"
[ "$(fm_get "$F1" fuente)" = telegram ] || fail "fuente"
[ "$(fm_get "$F1" repo)" = - ] || fail "repo must stay '-' for the planner"
grep -qxF "$TEXT" "$F1" || fail "the text was not kept verbatim"
echo "OK: add - --fuente telegram -> requested, fuente: telegram, text intact"

run add demo "by hand" >/dev/null 2>&1 || fail "add without --fuente broke"
F2="$(by_prio 20)"
[ -z "$(fm_get "$F2" fuente)" ] || fail "add without --fuente must not write fuente:"
run add - "no source" >/dev/null 2>&1 && fail "repo '-' without --fuente must be refused"
run add demo --fuente "Tele gram" "x" >/dev/null 2>&1 && fail "a malformed fuente must be refused"
echo "OK: add without the flag is unchanged; '-' needs a source"

# exclusive creation: a name that already exists is never overwritten. The numbering is pinned
# to 20 in a copy of the scripts, so the second `add` collides with the first.
CP="$TMP/copy"; mkdir -p "$CP"; cp -R "$DIR/bin" "$CP/bin"; cp -R "$DIR/lib" "$CP/lib"
printf '\nqueue_next_nn() { echo 90; }\n' >> "$CP/lib/queue.sh"
BIN_CP="$CP/bin/devbrain-queue"
DEVBRAIN_QUEUE_DIR="$Q" "$BIN_CP" add demo "same task" >/dev/null 2>&1 || fail "the first add on a pinned number failed"
SAME="$Q/90-demo--same-task.plan.md"; [ -f "$SAME" ] || fail "the first pinned add did not create $SAME"
BEFORE="$(cksum < "$SAME")"
DEVBRAIN_QUEUE_DIR="$Q" "$BIN_CP" add demo "same task" > "$TMP/out" 2>&1; rc=$?
[ "$rc" = 3 ] && [ "$(cksum < "$SAME")" = "$BEFORE" ] || fail "a second add on the same name must exit 3 and leave the plan alone (rc=$rc)"
DEVBRAIN_QUEUE_DIR="$Q" "$BIN_CP" add demo "SAME TASK" >/dev/null 2>&1; rc=$?
[ "$rc" = 3 ] && [ "$(cksum < "$SAME")" = "$BEFORE" ] || fail "same name, other text: must exit 3 and leave the plan alone (rc=$rc)"
rm -f "${SAME:?}"
echo "OK: add never overwrites an existing plan file"

# ---- approve -----------------------------------------------------------------------------
# (a) a request with a source and no planificado: is refused, nothing touched, no preflight call.
run approve 10 > "$TMP/out" 2>&1 && fail "approve on an unplanned request must be refused"
[ "$(fm_get "$F1" status)" = requested ] && [ -z "$(fm_get "$F1" aprobado)" ] || fail "refused approve changed the plan"
[ ! -s "$TMP/pf.log" ] || fail "an unplanned request must not even reach the preflight"
echo "OK: approve refuses a telegram request without planificado:"

# (b) planned + red preflight -> not approved
fm_set "$F1" planificado 2026-10-03; fm_set "$F1" repo demo
PF_FAIL=1 run approve 10 > "$TMP/out" 2>&1 && fail "approve must not approve a plan the preflight rejects"
grep -q "missing ## Cases" "$TMP/out" || fail "the preflight's reason must be shown"
[ "$(fm_get "$F1" status)" = requested ] || fail "a rejected plan changed status"
echo "OK: approve runs the preflight and refuses on red"

# (c) planned + green preflight -> approved, aprobado:, committed
run approve 10 > "$TMP/out" 2>&1 || fail "approve on a planned request: $(cat "$TMP/out")"
[ "$(fm_get "$F1" status)" = approved ] || fail "status approved"
[ "$(fm_get "$F1" aprobado)" = "$(date +%Y-%m-%d)" ] || fail "aprobado: today"
grep -q -- "--plan $F1" "$TMP/pf.log" || fail "the preflight ran on another file"
LOG="$(git -C "$Q" log --format=%s)"   # capture, then grep: grep -q + pipefail turns SIGPIPE into a false failure
grep -q "queue: approve" <<<"$LOG" || fail "approve did not commit the queue"
run approve 10 >/dev/null 2>&1 && fail "an already approved plan must not be approved again"
echo "OK: a planned request is approved and committed"

# (d) hand-written (no fuente:) approves as usual
run approve 20 > "$TMP/out" 2>&1 || fail "hand-written plan: $(cat "$TMP/out")"
[ "$(fm_get "$F2" status)" = approved ] || fail "hand-written plan not approved"
echo "OK: a hand-written plan (no fuente:) is approved"

for BAD in "approve" "approve abc" "approve 0" "approve 999"; do
  run $BAD >/dev/null 2>&1 && fail "malformed '$BAD' was accepted"
done
echo "OK: approve rejects malformed or unknown numbers"

# a missing preflight fails closed
F9="$(plan 95 requested)"
DAY_PREFLIGHT_BIN=/nonexistent run approve 95 >/dev/null 2>&1 && fail "approve without a preflight must fail closed"
[ "$(fm_get "$F9" status)" = requested ] || fail "approve changed a plan without a preflight"
echo "OK: approve fails closed without a preflight"

# ---- deny --------------------------------------------------------------------------------
run add - --fuente telegram "a bad idea" >/dev/null 2>&1
N3="$(fm_get "$(ls -t "$Q"/*a-bad-idea*.plan.md | head -1)" prioridad)"; F3="$(by_prio "$N3")"
run deny "$N3" > /dev/null 2>&1 && fail "deny without a reason must be refused"
run deny "$N3" it already exists in another repo > "$TMP/out" 2>&1 || fail "deny: $(cat "$TMP/out")"
[ "$(fm_get "$F3" status)" = superseded ] || fail "status superseded"
[ "$(fm_get "$F3" motivo_fallo)" = "it already exists in another repo" ] || fail "motivo_fallo"
run deny 10 "too late" >/dev/null 2>&1 && fail "an approved plan must not be denied from here"
echo "OK: deny -> superseded with motivo_fallo; an approved plan cannot be denied"

# ---- change ------------------------------------------------------------------------------
run add - --fuente telegram "another idea" >/dev/null 2>&1
N4="$(fm_get "$(ls -t "$Q"/*another-idea*.plan.md | head -1)" prioridad)"; F4="$(by_prio "$N4")"
fm_set "$F4" planificado 2026-10-03; fm_set "$F4" status question
run change "$N4" >/dev/null 2>&1 && fail "change without text must be refused"
run change "$N4 option B" >/dev/null 2>&1 && fail "change without the colon must be refused"
run change "$N4:" "option B, in the other repo" > "$TMP/out" 2>&1 || fail "change: $(cat "$TMP/out")"
[ "$(fm_get "$F4" status)" = requested ] || fail "change must go back to requested"
[ -z "$(fm_get "$F4" planificado)" ] || fail "change must drop planificado:"
grep -q "^## Owner note — $(date +%Y-%m-%d)$" "$F4" || fail "change heading missing"
grep -qx "option B, in the other repo" "$F4" || fail "change text missing"
[ "$(head -1 "$F4")" = "---" ] && [ "$(fm_get "$F4" fuente)" = telegram ] || fail "change broke the frontmatter"
run approve "$N4" >/dev/null 2>&1 && fail "after change the request must need planning again"
run change "10: x" >/dev/null 2>&1 && fail "change on an approved plan must be refused"
echo "OK: change appends under a dated heading, back to requested without planificado:"

# ---- show: read only, cut for Telegram ---------------------------------------------------
printf '\n# Plan title\n\nShort body with accents: ñandú.\n' >> "$F2"
H0="$(git -C "$Q" rev-parse HEAD)"
run show 20 > "$TMP/out" 2>&1 || fail "show 20: $(cat "$TMP/out")"
[ "$(head -1 "$TMP/out")" = "#20 Plan title" ] || fail "show: title line: $(head -1 "$TMP/out")"
grep -qx "repo: demo · status: approved" "$TMP/out" || fail "show: repo/status line"
grep -qx "Short body with accents: ñandú." "$TMP/out" || fail "show: short body must print whole"
grep -q "^---$\|^prioridad:" "$TMP/out" && fail "show: frontmatter leaked"
grep -q "(cut;" "$TMP/out" && fail "show: a short plan must not be cut"
python3 -c 'print("\n".join("line %d — ñ" % i for i in range(1000)))' >> "$F2"
run show 20 > "$TMP/out" 2>&1 || fail "show 20 (long)"
[ "$(tail -1 "$TMP/out")" = "… (cut; the full plan is in the queue)" ] || fail "show: a long plan needs the cut line"
LEN="$(python3 -c 'import sys; print(len(sys.stdin.read()))' < "$TMP/out")"
[ "$LEN" -le 3700 ] || fail "show: output too long for Telegram ($LEN chars)"
[ "$(git -C "$Q" rev-parse HEAD)" = "$H0" ] || fail "show must not commit"
run show 999 > "$TMP/out" 2>&1 && fail "show on an unknown number must fail"
grep -q "there is no plan #999" "$TMP/out" || fail "show: unknown number needs a clear error"
echo "OK: show prints title/repo/status and the body, cut for Telegram; an unknown number fails"

# ---- requeue -----------------------------------------------------------------------------
# blocked -> requested, archived, aprobado: intact
F5="$(plan 110 blocked "python3 scripts/y.py" "missing permission")"
run requeue 110 > "$TMP/out" 2>&1 || fail "requeue of a blocked plan: $(cat "$TMP/out")"
[ "$(fm_get "$F5" status)" = requested ] || fail "requeue: the plan is not requested"
[ "$(fm_get "$F5" bloqueado_antes)" = "$(date +%Y-%m-%d): python3 scripts/y.py" ] || fail "requeue: bloqueado_antes: $(fm_get "$F5" bloqueado_antes)"
[ "$(fm_get "$F5" motivo_antes)" = "missing permission" ] || fail "requeue: motivo_antes"
[ -z "$(fm_get "$F5" bloqueado_por)" ] && [ -z "$(fm_get "$F5" motivo_fallo)" ] || fail "requeue: live keys still there"
[ "$(fm_get "$F5" aprobado)" = 2026-10-02 ] || fail "requeue: aprobado: changed"
LOG="$(git -C "$Q" log --format=%s)"
grep -q "queue: requeue" <<<"$LOG" || fail "requeue did not commit"
echo "OK: requeue: blocked -> requested with bloqueado_antes/motivo_antes; aprobado: intact"
# several commands, no motivo_fallo
F5B="$(plan 111 blocked "supabase db push ‖ python3 a.py")"
run requeue 111 >/dev/null 2>&1 || fail "requeue multi"
[ "$(fm_get "$F5B" bloqueado_antes)" = "$(date +%Y-%m-%d): supabase db push ‖ python3 a.py" ] || fail "requeue: multi-command archive"
grep -q '^motivo_antes:' "$F5B" && fail "requeue: no motivo_fallo means no motivo_antes"
echo "OK: requeue archives several commands whole"
# any other status -> exit 3, file untouched
n=120
for st in approved running done paused requested; do
  n=$((n+1)); F="$(plan $n "$st")"; B4="$(cat "$F")"
  run requeue "$n" > "$TMP/out" 2>&1; rc=$?
  [ "$rc" = 3 ] || fail "requeue of '$st' should exit 3, got $rc"
  [ "$(cat "$F")" = "$B4" ] || fail "requeue of '$st' changed the file"
done
echo "OK: requeue of any non-blocked status -> exit 3, file untouched"
# red preflight -> the real plan is untouched
F6="$(plan 130 blocked "python3 scripts/z.py" "another cause")"; B6="$(cat "$F6")"; : > "$TMP/pf.log"
PF_FAIL=1 run requeue 130 > "$TMP/out" 2>&1 && fail "requeue with a red preflight exited 0"
[ "$(cat "$F6")" = "$B6" ] || fail "the plan changed with a red preflight"
grep -q "missing ## Cases" "$TMP/out" || fail "the preflight output was not shown"
grep -q -- "--plan " "$TMP/pf.log" && ! grep -q -- "--plan $F6" "$TMP/pf.log" || fail "the preflight must check a COPY, not the real plan"
echo "OK: a red preflight leaves the plan blocked and unchanged"
# the branch of a blocked run is archived, not left as if current
F7="$(plan 140 blocked "python3 scripts/r.py" "x")"; fm_set "$F7" rama "devbrain/widget-0301-0915"
run requeue 140 >/dev/null 2>&1 || fail "requeue with a branch"
[ -z "$(fm_get "$F7" rama)" ] || fail "rama: still live"
[ "$(fm_get "$F7" rama_antes)" = "$(date +%Y-%m-%d): devbrain/widget-0301-0915" ] || fail "rama_antes: '$(fm_get "$F7" rama_antes)'"
F7B="$(plan 141 blocked "python3 scripts/r.py" "x")"; run requeue 141 >/dev/null 2>&1
grep -q '^rama_antes' "$F7B" && fail "a plan without a branch gained a rama_antes"
echo "OK: requeue archives rama: as rama_antes and writes nothing when there is none"
# the full cycle
F8="$(plan 150 blocked "python3 scripts/q.py" "x")"
run requeue 150 >/dev/null 2>&1 && run approve 150 >/dev/null 2>&1 || fail "requeue then approve"
[ "$(fm_get "$F8" status)" = approved ] && [ "$(fm_get "$F8" aprobado)" = "$(date +%Y-%m-%d)" ] || fail "approve after requeue"
echo "OK: requeue, then approve -> approved with today's aprobado:"
# the alert that sends people here
L="$(grep -E 'tg_send.*blocked' "$DIR/bin/devbrain-night" | head -1)"
grep -q 'requeue' <<<"$L" || fail "the night's blocked alert does not point to requeue"
echo "OK: the night's blocked alert points to requeue"

echo "PASS: devbrain-queue-verbs"

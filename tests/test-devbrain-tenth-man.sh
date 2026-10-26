#!/bin/bash
# tests/test-devbrain-tenth-man.sh: bin/devbrain-tenth-man and everything wired to it (the validator, the night
# gate, approve/deny/change, the digest counts, the PR block of `devbrain execute`).
#
# A fake `claude` returns whatever is in $FAKE_DIR/reply, so each case hands the script one canned model
# answer. Temporary queue (git, no origin), temporary HOME, fake preflight and gh: never the real queue, the
# network or a real session.
#
# Each case is a function `case_*  <root>` that returns 0 if it passes. They run against the real tree (all
# must pass) and, with the root pointing at a MUTATED COPY, the case that catches the mutation must go RED.
# A mutation no case notices is a test that cannot fail. At the end, a control mutation (a comment) must
# leave everything green: it proves "red" comes from the mutation and not from the setup.
[ -z "${OPENCLAW_CLI+x}" ] && [ "${OPENCLAW_SHELL-}" != exec ] || { echo "FAIL: these tests do not run under OpenClaw" >&2; exit 1; }
set -uo pipefail
export DEVBRAIN_NO_TG=1
die() { echo "FAIL: ${1:-test-devbrain-tenth-man.sh:${BASH_LINENO[0]}}"; exit 1; }
DIR="$(cd "$(dirname "$0")/.." && pwd)"
for f in bin/devbrain-tenth-man lib/tenth_validate.py; do [ -f "$DIR/$f" ] || die "$f does not exist"; done
bash -n "$DIR/bin/devbrain-tenth-man" && python3 -I -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' "$DIR/lib/tenth_validate.py" || die

REALHOME="$HOME"
TMP="$(cd "$(mktemp -d)" && pwd -P)"; trap 'rm -rf "${TMP:?}"' EXIT
mkdir -p "$TMP/home/.openclaw" "$TMP/tmpdir" "$TMP/fake"; export HOME="$TMP/home" TMPDIR="$TMP/tmpdir"
[ "$HOME" != "$REALHOME" ] || die "HOME is not temporary; aborting before touching anything"
export FAKE_DIR="$TMP/fake" DEVBRAIN_TENTH_LOG="$TMP/log" DEVBRAIN_CLAUDE_BIN="$TMP/claude"
TODAY="$(date +%Y-%m-%d)"

# repo under review: src/a.txt has 5 lines
REPO="$TMP/projects/demo"; PROJ="$TMP/projects"; mkdir -p "$REPO/src"
printf 'one\ntwo\nthree\nfour\nfive\n' > "$REPO/src/a.txt"
export DEVBRAIN_PROJECTS_DIR="$PROJ"

# The tenth man's session is recognized by its prompt; any other session gets a plain review answer.
cat > "$TMP/claude" <<'FAKE'
#!/bin/bash
p="$(cat)"
printf '%s\n' "$*" >> "$FAKE_DIR/args"
case "$*" in *acceptEdits*) echo feature > feature.txt; echo done; exit 0 ;; esac
case "$p" in *"TENTH MAN"*) echo x >> "$FAKE_DIR/calls"; cat "$FAKE_DIR/reply" 2>/dev/null; exit 0 ;; esac
echo "VERDICT: APPROVE"
FAKE
chmod +x "$TMP/claude"
printf '#!/bin/bash\nexit 0\n' > "$TMP/pf"; chmod +x "$TMP/pf"
cat > "$TMP/fake-gh" <<EOF
#!/bin/bash
while [ \$# -gt 0 ]; do [ "\$1" = --body ] && printf '%s' "\$2" > "$TMP/pr-body"; shift; done
echo https://example.test/pull/1
EOF
chmod +x "$TMP/fake-gh"
printf 'scratch\n' > "$TMP/allow"

fm() { sed -n "s/^$2: //p" "$1" | head -1; }
ncalls() { [ -f "$FAKE_DIR/calls" ] && wc -l < "$FAKE_DIR/calls" | tr -d ' ' || echo 0; }
clear_fake() { rm -f "${FAKE_DIR:?}/calls" "${FAKE_DIR:?}/args" "${FAKE_DIR:?}/reply"; }

# ---- canned model answers ----------------------------------------------------------------------------
sec() { local s; for s in "Failure modes" "Gaps in safeguards" "Blind spots" "Plausible worst case" "What would make it wrong" "How to revert"; do
          printf '## %s\n- something about %s\n\n' "$s" "$s"; done
        printf '## Residual risks\n- r1\n- r2\n- r3\n'; }
out() { local d="$1"; shift; { echo "DISSENT: $d"; echo; for o in "$@"; do echo "$o"; done; echo; sec; } > "$FAKE_DIR/reply"; }
BLOCK_OBJ='OBJECTION: the hash is not checked :: src/a.txt:3 :: MUST FIX'

mkplan() { # <file> [extra frontmatter lines...] -> a plan in $TMP
  local f="$1"; shift
  { echo "---"; echo "repo: demo"; echo "status: approved"; echo "prioridad: 5"; for x in "$@"; do echo "$x"; done
    echo "---"; echo; echo "## Plan"; echo "body"; } > "$f"
}
# tenth <root> <plan> -> runs the tenth man of <root> over the test repo
tenth() { "$1/bin/devbrain-tenth-man" plan --dir "$REPO" "$2" > "$TMP/out" 2>&1; }

# ---- the queue ---------------------------------------------------------------------------------------
Q="$TMP/queue"; mkdir -p "$Q" "$TMP/wiki/projects"
git -C "$Q" init -q 2>/dev/null; git -C "$Q" config user.email t@t.t; git -C "$Q" config user.name t
git -C "$TMP/wiki" init -q 2>/dev/null
qplan() { # <prio> <status> [extra frontmatter lines...] -> $Q/<prio>-demo.plan.md
  local p="$1" st="$2"; shift 2
  { echo "---"; echo "repo: demo"; echo "status: $st"; echo "prioridad: $p"; echo "creado: 2026-10-10"; echo "verificado: 2026-10-10"
    for x in "$@"; do echo "$x"; done
    echo "---"; echo; echo "## Plan"; echo "body $p"; } > "$Q/$p-demo.plan.md"
  git -C "$Q" add -A >/dev/null 2>&1; git -C "$Q" commit -qm "p$p" >/dev/null 2>&1
}
qf() { echo "$Q/$1-demo.plan.md"; }
qclear() { rm -f "${Q:?}"/*.plan.md; }
cq() { # <root> <args...>: devbrain-queue of <root>, no terminal
  local r="$1"; shift
  DEVBRAIN_QUEUE_DIR="$Q" DEVBRAIN_WIKI_DIR="$TMP/wiki" DAY_ENGINE="$r/lib/day_engine.py" DAY_PREFLIGHT_BIN="$TMP/pf" \
    "$r/bin/devbrain-queue" "$@" > "$TMP/qout" 2>&1 < /dev/null
}
cq_tty() { # <root> <args...>: like cq but with a real terminal (a `script` pty). RC travels in a marker; output in $TMP/tty-out.
  # TTY_REDIR (e.g. "< /dev/null") redirects the binary inside the pty, to take away one terminal condition at a time.
  local r="$1" o; shift
  o="$( export DEVBRAIN_QUEUE_DIR="$Q" DEVBRAIN_WIKI_DIR="$TMP/wiki" DAY_ENGINE="$r/lib/day_engine.py" DAY_PREFLIGHT_BIN="$TMP/pf"
        /usr/bin/script -q /dev/null /bin/bash -c '"$0" "$@" '"${TTY_REDIR:-}"'; echo "RC=$?"' "$r/bin/devbrain-queue" "$@" 2>&1 < /dev/null | tr -d '\r' )"
  printf '%s\n' "$o" > "$TMP/tty-out"
  return "$(printf '%s\n' "$o" | sed -n 's/.*RC=\([0-9][0-9]*\).*/\1/p' | tail -n 1)"
}

# ============================== cases ==============================================================================
case_blocks_by_computation() { local R="$1" P="$TMP/c1.plan.md"; mkplan "$P"; clear_fake
  out "DOES NOT BLOCK" "$BLOCK_OBJ"                      # the model says DOES NOT BLOCK, the evidence says BLOCKS
  tenth "$R" "$P" || return 1
  [ "$(fm "$P" disenso)" = BLOCKS ] || return 1
  grep -q '^## Tenth man (written by devbrain-tenth-man)$' "$P" || return 1
  grep -q '^NOTE:' "$P" || return 1
  out "BLOCKS" "OBJECTION: maybe :: src/a.txt:2 :: RISK"   # the model says BLOCKS, but a RISK never blocks
  tenth "$R" "$P" || return 1
  [ "$(fm "$P" disenso)" = "DOES NOT BLOCK" ] || return 1
  [ "$(grep -c '^## Tenth man' "$P")" = 1 ]              # the section is replaced, not appended again
}
case_evidence_rules() { local R="$1" P="$TMP/c2.plan.md"; mkplan "$P"; clear_fake
  out BLOCKS "OBJECTION: a :: src/zzz.txt:3 :: MUST FIX" "OBJECTION: b :: src/a.txt:99 :: MUST FIX" \
    "OBJECTION: c :: SCENARIO: fails :: MUST FIX" "OBJECTION: d :: ../../../etc/passwd:1 :: MUST FIX" \
    "OBJECTION: e :: src/a.txt:2 :: MAYBE"
  tenth "$R" "$P" || return 1
  [ "$(fm "$P" disenso)" = "DOES NOT BLOCK" ] && [ "$(grep -c ':: NO EVIDENCE :: RISK$' "$P")" = 5 ] || return 1
  # a real file outside the repo, reached by `..` or by a symlink inside it, is not evidence either
  printf 'a\nb\nc\n' > "$PROJ/outside.txt"; ln -sf ../../outside.txt "$REPO/src/link.txt"
  out BLOCKS "OBJECTION: m :: ../outside.txt:2 :: MUST FIX" "OBJECTION: n :: src/link.txt:2 :: MUST FIX"
  tenth "$R" "$P" || { rm -f "$REPO/src/link.txt"; return 1; }
  rm -f "$REPO/src/link.txt"
  [ "$(fm "$P" disenso)" = "DOES NOT BLOCK" ] && [ "$(grep -c ':: NO EVIDENCE :: RISK$' "$P")" = 2 ] || return 1
  out "DOES NOT BLOCK" "OBJECTION: g :: SCENARIO: the linter reads the plan before the override and approves an old hash :: MUST FIX"
  tenth "$R" "$P" || return 1
  [ "$(fm "$P" disenso)" = BLOCKS ] || return 1          # a concrete scenario (50+ characters) counts
  # the validator never crashes on hostile evidence, and a bulleted / bold OBJECTION still counts
  local ok V="$R/lib/tenth_validate.py"; ok="$(sed -n '/^## Failure modes/,$p' "$FAKE_DIR/reply")"
  vv() { { printf 'DISSENT: BLOCKS\n\n'; printf '%s\n' "$1"; printf '\n%s\n' "$ok"; } | python3 -I "$V" "$REPO" 2>&1; }
  [ "$(vv "OBJECTION: h :: src/a.txt:$(python3 -c 'print("9"*5000)') :: MUST FIX" | head -1)" = "DISSENT: DOES NOT BLOCK" ] || return 1
  { printf 'DISSENT: BLOCKS\n\n'; printf 'OBJECTION: i :: src/a\0.txt:2 :: MUST FIX\n\n%s\n' "$ok"; } > "$TMP/nul-in"
  [ "$(python3 -I "$V" "$REPO" < "$TMP/nul-in" 2>&1 | head -1)" = "DISSENT: DOES NOT BLOCK" ] || return 1
  [ "$(vv "- OBJECTION: j :: src/a.txt:2 :: MUST FIX" | head -1)" = "DISSENT: BLOCKS" ] \
    && [ "$(vv "**OBJECTION:** k :: src/a.txt:2 :: MUST FIX" | head -1)" = "DISSENT: BLOCKS" ]
}
case_invalid_output_is_unavailable() { local R="$1" P="$TMP/c3.plan.md"; mkplan "$P"
  bad() { : > "$TMP/log"; tenth "$R" "$P" || return 1
    [ "$(fm "$P" disenso)" = UNAVAILABLE ] && grep -qi 'invalid' "$TMP/log"; }
  clear_fake; : > "$FAKE_DIR/reply"; bad || return 1
  out BLOCKS; sed -i.bak '1s/.*/Here is my dissent/' "$FAKE_DIR/reply"; bad || return 1
  out "DOES NOT BLOCK"; grep -v '^## Blind spots$' "$FAKE_DIR/reply" > "$TMP/m2"; mv "$TMP/m2" "$FAKE_DIR/reply"; bad || return 1
  out "DOES NOT BLOCK"; awk '/^## How to revert$/{print; getline; next} {print}' "$FAKE_DIR/reply" > "$TMP/m2"; mv "$TMP/m2" "$FAKE_DIR/reply"; bad || return 1
  out "DOES NOT BLOCK"; grep -v '^- r3$' "$FAKE_DIR/reply" > "$TMP/m2"; mv "$TMP/m2" "$FAKE_DIR/reply"; bad || return 1
  DEVBRAIN_CLAUDE_BIN="$TMP/does-not-exist" tenth "$R" "$P"; [ "$(fm "$P" disenso)" = UNAVAILABLE ]
}
case_same_session_cannot_dissent() { local R="$1" P="$TMP/c4.plan.md"; mkplan "$P" "session_planner: session-abc" "session_reviewer: session-rev"
  clear_fake; out "DOES NOT BLOCK"; local n0 id; n0="$(ncalls)"
  for id in session-abc session-rev; do
    DEVBRAIN_TENTH_SESSION_ID="$id" tenth "$R" "$P" || return 1
    [ "$(fm "$P" disenso)" = UNAVAILABLE ] && [ "$(ncalls)" = "$n0" ] || return 1
  done
  DEVBRAIN_FORBIDDEN_SESSIONS="other session-xyz" DEVBRAIN_TENTH_SESSION_ID=session-xyz tenth "$R" "$P" || return 1
  [ "$(fm "$P" disenso)" = UNAVAILABLE ] && [ "$(ncalls)" = "$n0" ] || return 1
  DEVBRAIN_TENTH_SESSION_ID=session-new tenth "$R" "$P" || return 1
  [ "$(fm "$P" disenso)" = "DOES NOT BLOCK" ] && [ "$(ncalls)" = $((n0+1)) ]
}
case_read_only_argv() { local R="$1" P="$TMP/c5.plan.md"; mkplan "$P"; clear_fake; out "DOES NOT BLOCK"
  tenth "$R" "$P" || return 1
  local a; a="$(tail -1 "$FAKE_DIR/args")"
  case "$a" in *'--tools Read,Glob,Grep'*) ;; *) return 1 ;; esac
  case "$a" in *'Read(//'*) ;; *) return 1 ;; esac
  case "$a" in *Edit*|*Write*|*Bash*) return 1 ;; esac
  return 0
}
case_new_dissent_clears_override() { local R="$1" P="$TMP/c6.plan.md"
  mkplan "$P" "disenso: BLOCKS" "disenso_anulado: 2026-10-01 old note"; clear_fake
  out BLOCKS "$BLOCK_OBJ"; tenth "$R" "$P" || return 1
  [ -z "$(fm "$P" disenso_anulado)" ] && [ "$(fm "$P" disenso)" = BLOCKS ]
}
case_night_skips_blocked() { local R="$1"; qclear
  qplan 10 approved "aprobado: 2026-10-10" "disenso: BLOCKS"
  qplan 11 approved "aprobado: 2026-10-10" "disenso: UNAVAILABLE"
  night() { DEVBRAIN_QUEUE_DIR="$Q" PROBE_ROOT="$R" bash "$DIR/tests/_night_gate_probe.sh" 2>/dev/null; }
  [ "$(night)" = 11-demo.plan.md ] || return 1             # the blocked one is skipped, the next one runs
  qplan 10 approved "aprobado: 2026-10-10" "disenso: BLOCKS" "disenso_anulado: 2026-10-10 reviewed"
  [ "$(night)" = 10-demo.plan.md ]                          # overridden: it runs again
}
case_approve_needs_a_person() { local R="$1" F; qclear; qplan 20 requested "disenso: BLOCKS"; F="$(qf 20)"
  cq "$R" approve 20 && return 1
  cq "$R" approve 20 "   " && return 1
  DEVBRAIN_VIA=agent DEVBRAIN_CITA="approve 20 please" cq "$R" approve 20 "agent note" && return 1
  cq "$R" approve 20 "note without a terminal" && return 1
  grep -q "tenth man" "$TMP/qout" || return 1
  # a real terminal with an agent mark, or with OPENCLAW_*, still refuses (rc 3); each mark alone as well
  OPENCLAW_WHATEVER=1 cq_tty "$R" approve 20 "note with an OpenClaw mark"; [ $? = 3 ] || return 1
  DEVBRAIN_VIA=agent DEVBRAIN_CITA="x" cq_tty "$R" approve 20 "note from an agent with a tty"; [ $? = 3 ] || return 1
  DEVBRAIN_VIA=agent cq_tty "$R" approve 20 "only VIA"; [ $? = 3 ] || return 1
  DEVBRAIN_CITA=x cq_tty "$R" approve 20 "only CITA"; [ $? = 3 ] || return 1
  TTY_REDIR='< /dev/null' cq_tty "$R" approve 20 "stdin is not a terminal"; [ $? = 3 ] || return 1
  TTY_REDIR='> /dev/null' cq_tty "$R" approve 20 "stdout is not a terminal"; [ $? = 3 ] || return 1
  # a real terminal and no note (or a blank one): refused for the note, rc 2
  cq_tty "$R" approve 20; [ $? = 2 ] || return 1
  cq_tty "$R" approve 20 "   "; [ $? = 2 ] || return 1
  [ -z "$(fm "$F" disenso_anulado)" ] && [ "$(fm "$F" status)" = requested ] || return 1   # nothing was written
  cq_tty "$R" approve 20 "the linter checks the hash, see the lint rule"; [ $? = 0 ] || { cat "$TMP/tty-out"; return 1; }
  [ "$(fm "$F" disenso_anulado)" = "$TODAY the linter checks the hash, see the lint rule" ] || return 1
  [ "$(fm "$F" status)" = approved ] && [ "$(fm "$F" disenso_resultado)" = anulado ] || return 1
  qplan 21 requested "disenso: DOES NOT BLOCK"
  cq "$R" approve 21 || return 1                            # no block: approve without a note, as always
  [ -z "$(fm "$(qf 21)" disenso_anulado)" ] && [ "$(fm "$(qf 21)" status)" = approved ]
}
case_deny_and_change_leave_history() { local R="$1" F; qclear
  qplan 30 requested "disenso: BLOCKS"; F="$(qf 30)"
  cq "$R" change "30: the hash is checked" || return 1
  [ -z "$(fm "$F" disenso)" ] && [ "$(fm "$F" disenso_resultado)" = confirmado ] && [ "$(fm "$F" status)" = requested ] || return 1
  qplan 31 requested "disenso: BLOCKS" "disenso_anulado: 2026-10-01 old" "disenso_resultado: anulado"; F="$(qf 31)"
  cq "$R" change "31: another round" || return 1
  [ -z "$(fm "$F" disenso)" ] && [ -z "$(fm "$F" disenso_anulado)" ] && [ -z "$(fm "$F" disenso_resultado)" ] || return 1   # overridden earlier: not a confirmation
  qplan 32 requested "disenso: DOES NOT BLOCK" "disenso_resultado: anulado"; F="$(qf 32)"
  cq "$R" change "32: no block" || return 1
  [ -z "$(fm "$F" disenso)" ] && [ -z "$(fm "$F" disenso_resultado)" ] || return 1   # an old result does not dirty the counts
  qplan 33 requested "disenso: BLOCKS"; F="$(qf 33)"
  cq "$R" deny 33 "the tenth man was right" || return 1
  [ "$(fm "$F" disenso_resultado)" = confirmado ] && [ "$(fm "$F" status)" = superseded ] || return 1
  qplan 34 requested "disenso: DOES NOT BLOCK"; F="$(qf 34)"
  cq "$R" deny 34 "not needed any more" || return 1
  [ -z "$(fm "$F" disenso_resultado)" ] && [ "$(fm "$F" status)" = superseded ]
}
case_counts() { local R="$1" HQ="$TMP/hq"; rm -rf "${HQ:?}"; mkdir -p "$HQ"
  h() { printf -- '---\nrepo: demo\nstatus: %s\nprioridad: %s\n%s\n---\n' "$1" "$2" "$3" > "$HQ/$2-demo.plan.md"; }
  h approved 1 "disenso_resultado: anulado"
  h done     2 "disenso_resultado: anulado"
  h done     3 "disenso_resultado: anulado"
  h failed   4 "disenso_resultado: anulado"
  h superseded 5 "disenso_resultado: confirmado"
  h failed   6 "disenso: DOES NOT BLOCK"
  h failed   7 "disenso: UNAVAILABLE"
  h done     8 "disenso: DOES NOT BLOCK"
  h failed   9 "disenso: BLOCKS"
  [ "$(bash -c '. "$1/lib/queue.sh"; tenth_counts "$2"' _ "$R" "$HQ")" = "overridden 1 · confirmed 1 · wrong 2 · right 1 · missed 2" ]
}
case_pr_block() { local R="$1" P="$TMP/c9.plan.md"; mkplan "$P"; clear_fake
  local p0; p0="$(cksum < "$P")"
  pr() { "$R/bin/devbrain-tenth-man" pr --repo demo --dir "$REPO" --plan "$P" --base origin/main > "$TMP/pr-out" 2>/dev/null; }
  out BLOCKS "$BLOCK_OBJ"; pr || return 1
  grep -q '^## Tenth man (mandatory dissent)$' "$TMP/pr-out" && grep -q '^DISSENT: BLOCKS' "$TMP/pr-out" || return 1
  : > "$FAKE_DIR/reply"; pr || return 1
  grep -q '^DISSENT: UNAVAILABLE' "$TMP/pr-out" && [ "$(cksum < "$P")" = "$p0" ]   # it informs; the plan is not touched
}
exec_pr() { # <root> <stub bin or ""> -> runs `devbrain execute` of <root> in a fresh repo; the PR body lands in $TMP/pr-body
  local r="$1" s="$2" f="$TMP/ex"; rm -rf "${f:?}" "${TMP:?}/pr-body"; mkdir -p "$f/projects"
  git init -q --bare -b main "$f/origin.git"; git clone -q "$f/origin.git" "$f/projects/scratch" 2>/dev/null
  git -C "$f/projects/scratch" config user.email t@t.t; git -C "$f/projects/scratch" config user.name t
  printf '.devbrain/\n' > "$f/projects/scratch/.gitignore"; echo base > "$f/projects/scratch/a.txt"
  git -C "$f/projects/scratch" add -A; git -C "$f/projects/scratch" commit -qm base; git -C "$f/projects/scratch" push -q origin HEAD:main 2>/dev/null
  mkdir -p "$f/projects/scratch/.devbrain"
  printf 'Add feature.txt\n' > "$f/projects/scratch/.devbrain/plan-latest.md"; echo "add feature" > "$f/projects/scratch/.devbrain/task-latest.txt"
  env DEVBRAIN_PROJECTS_DIR="$f/projects" DEVBRAIN_ALLOWFILE="$TMP/allow" DEVBRAIN_GH_BIN="$TMP/fake-gh" \
    ${s:+DEVBRAIN_TENTH_BIN="$s"} perl -e 'alarm 120; exec @ARGV' "$r/bin/devbrain" execute scratch > "$TMP/exec-out" 2>&1
  grep -q 'https://example.test/pull/1' "$TMP/exec-out" && [ -s "$TMP/pr-body" ]
}
nl_of() { grep -n -m1 -- "$1" "$TMP/pr-body" | cut -d: -f1; }
case_execute_pr_body_order() { local R="$1" a b c rc
  clear_fake; out "DOES NOT BLOCK" "OBJECTION: x :: src/a.txt:1 :: RISK"
  exec_pr "$R" "" || { tail -5 "$TMP/exec-out"; return 1; }
  a="$(nl_of '^VERDICT: APPROVE')"; b="$(nl_of '^DISSENT: DOES NOT BLOCK')"; c="$(nl_of '^## Approved plan')"
  [ -n "$a" ] && [ -n "$b" ] && [ -n "$c" ] && [ "$a" -lt "$b" ] && [ "$b" -lt "$c" ] || { cat "$TMP/pr-body"; return 1; }
  : > "$FAKE_DIR/reply"                                     # invalid output: UNAVAILABLE in the same place
  exec_pr "$R" "" || return 1
  a="$(nl_of '^VERDICT: APPROVE')"; b="$(nl_of '^DISSENT: UNAVAILABLE')"; c="$(nl_of '^## Approved plan')"
  [ -n "$a" ] && [ -n "$b" ] && [ -n "$c" ] && [ "$a" -lt "$b" ] && [ "$b" -lt "$c" ] || return 1
  # any exit code of the tenth man other than 0 is a visible UNAVAILABLE in the PR, never a dead script
  for rc in 1 2 3 7 127; do
    printf '#!/bin/bash\nexit %s\n' "$rc" > "$TMP/tenth-rc$rc"; chmod +x "$TMP/tenth-rc$rc"
    exec_pr "$R" "$TMP/tenth-rc$rc" || return 1
    a="$(nl_of '^DISSENT: UNAVAILABLE')"; c="$(nl_of '^## Approved plan')"
    [ -n "$a" ] && [ "$a" -lt "$c" ] && grep -q "failed (code $rc)" "$TMP/pr-body" || return 1
  done
}

CASES="blocks_by_computation evidence_rules invalid_output_is_unavailable same_session_cannot_dissent read_only_argv new_dissent_clears_override night_skips_blocked approve_needs_a_person deny_and_change_leave_history counts pr_block execute_pr_body_order"
for c in $CASES; do "case_$c" "$DIR" && echo "OK: $c" || { echo "FAIL: case $c"; exit 1; }; done

# ---- mutations: each in a copy of the tree; the case that catches it must go RED ----
MUTD="$(mktemp -d "$TMP/mut.XXXXXX")"
mutate() { # <name> <file> <python expression s -> s>
  rm -rf "${MUTD:?}"/*; cp -R "$DIR/bin" "$DIR/lib" "$DIR/config" "$MUTD/"
  F="$MUTD/$2" EXPR="$3" python3 -c '
import os,sys
p=os.environ["F"]; s=open(p,encoding="utf-8").read()
n=eval("lambda s: "+os.environ["EXPR"])(s)   # only expressions written in THIS file
if n==s: sys.exit(3)
open(p,"w",encoding="utf-8").write(n)' || { echo "FAIL: could not plant the mutation \"$1\""; die; }
}
must_go_red() { # <mutation> <case>
  "case_$2" "$MUTD" && { echo "FAIL: the mutation \"$1\" goes unnoticed: case $2 cannot fail"; die; }
  echo "OK: the mutation \"$1\" goes red in $2"
}
V=lib/tenth_validate.py
mutate "a vague scenario counts as evidence" $V "s.replace('>= 50', '>= 0')"
must_go_red "a vague scenario counts" evidence_rules
mutate "a path outside the repo counts as evidence" $V "s.replace('not path.startswith(repo + os.sep) or ', '')"
must_go_red "a path outside the repo counts" evidence_rules
mutate "the model's verdict is trusted" $V "s.replace('computed = \"DISSENT: \" + (\"BLOCKS\" if blocks else \"DOES NOT BLOCK\")', 'computed = declared')"
must_go_red "the model's verdict is trusted" blocks_by_computation
mutate "a RISK blocks" $V "s.replace('parts[2].strip() == \"MUST FIX\"', 'True')"
must_go_red "a RISK blocks" blocks_by_computation
mutate "the session gets Edit" bin/devbrain-tenth-man "s.replace('Read,Glob,Grep', 'Read,Glob,Grep,Edit')"
must_go_red "the session gets Edit" read_only_argv
mutate "night ignores the block" bin/devbrain-night "s.replace('queue_disenso_bloquea \"\$f\" && continue', ':')"
must_go_red "night ignores the block" night_skips_blocked
mutate "an agent can override" bin/devbrain-queue "s.replace('[ -n \"\${DEVBRAIN_VIA+x}\" ] ||', 'false ||')"
must_go_red "an agent can override" approve_needs_a_person
mutate "deny forgets the history" bin/devbrain-queue "s.replace('queue_disenso_bloquea \"\$F\" && fm_set \"\$F\" disenso_resultado confirmado', ':')"
must_go_red "deny forgets the history" deny_and_change_leave_history
mutate "the counts mix right and wrong" lib/queue.sh "s.replace('failed) x=\$((x+1))', 'failed) s=\$((s+1))')"
must_go_red "the counts mix right and wrong" counts
mutate "the PR hides a failed tenth man" bin/devbrain "s.replace('if [ \"\$TENTH_RC\" -ne 0 ]', 'if false')"
must_go_red "the PR hides a failed tenth man" execute_pr_body_order

# control: a mutation that does not change behavior leaves everything green (if not, "red" proved nothing)
mutate "control: a comment" $V "s + '\n# control\n'"
for c in $CASES; do "case_$c" "$MUTD" || { echo "FAIL: the control (only a comment) broke $c: the mutation setup is not reliable"; die; }; done
echo "OK: the control (comment) leaves the $(echo $CASES | wc -w | tr -d ' ') cases green"
echo "PASS: test-devbrain-tenth-man"

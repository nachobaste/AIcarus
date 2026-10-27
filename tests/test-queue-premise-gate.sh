#!/bin/bash
# tests/test-queue-premise-gate.sh — the premise gate: queue_premisas_ok and the sites that call it
# (the night's next_plan, approve that only warns, change that deletes verificado:).
#
# Like tests/test-devbrain-verifier.sh: each case is a function `case_* <root>`; it runs against the real tree
# (green) and against mutated copies (the case that catches the mutation MUST go RED), plus a control mutation
# that must leave everything green. The night runs with its real text (tests/_night_gate_probe.sh extracts
# next_plan from bin/devbrain-night).
[ -z "${OPENCLAW_CLI+x}" ] && [ "${OPENCLAW_SHELL-}" != exec ] || { echo "FAIL: these tests do not run under OpenClaw" >&2; exit 1; }
set -uo pipefail
die() { echo "FAIL (see above)"; exit 1; }
DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(cd "$(mktemp -d)" && pwd -P)"; trap 'rm -rf "$TMP"' EXIT
Q="$TMP/queue"; mkdir -p "$Q"
export DEVBRAIN_NO_TG=1 HOME="$TMP/home"; mkdir -p "$HOME"

HOLDS='- the file exists :: app.txt:1 :: HOLDS'
FALSEP='- the function exists :: lib/x.sh:7 :: FALSE'
DOUBT='- the flag is on :: lib/x.sh:9 :: UNVERIFIABLE'
NOVERD='- the file exists :: app.txt:1'
V3='2026-10-24 (3 HOLDS, 0 FALSE, 0 UNVERIFIABLE)'

# plan <name> <verificado|-> <premise lines...> -> approved by hand; with `-` it writes no verificado:
plan() {
  local f="$Q/$1" v="$2"; shift 2
  { printf -- '---\nrepo: demo\nstatus: approved\naprobado: 2026-10-24\nprioridad: 5\n'
    [ "$v" = - ] || printf 'verificado: %s\n' "$v"
    printf -- '---\n\n# Title\n\n## What was already verified\n\n'
    for l in "$@"; do printf '%s\n' "$l"; done; printf '\n## Constraints\n\n- Nothing else.\n'; } > "$f"
}
clear_q() { rm -f "$Q"/*.plan.md; }
gate() { # <root> <plan> -> rc of queue_premisas_ok of tree <root>; the reason is left in $GATE_OUT
  GATE_OUT="$(/bin/bash -c ". '$1/lib/queue.sh'; queue_premisas_ok '$Q/$2'" 2>&1 < /dev/null)"; return $?
}
night() { # <root> -> basename of the plan the night's next_plan picks (empty if none)
  DEVBRAIN_QUEUE_DIR="$Q" PROBE_ROOT="$1" bash "$DIR/tests/_night_gate_probe.sh" 2>/dev/null
}

case_three_holds_pass() { local R="$1"
  clear_q; plan 10-a.plan.md "$V3" "$HOLDS" "$HOLDS" "$HOLDS"
  gate "$R" 10-a.plan.md && [ "$(night "$R")" = 10-a.plan.md ]
}
case_false_does_not_pass_anywhere() { local R="$1"
  clear_q; plan 10-a.plan.md "$V3" "$HOLDS" "$FALSEP"
  gate "$R" 10-a.plan.md && return 1
  case "$GATE_OUT" in *"the function exists"*) ;; *) return 1 ;; esac   # the reason names the premise
  [ -z "$(night "$R")" ]
}
case_unverifiable_does_not_pass_anywhere() { local R="$1"
  clear_q; plan 10-a.plan.md "$V3" "$HOLDS" "$DOUBT"
  gate "$R" 10-a.plan.md && return 1
  [ -z "$(night "$R")" ]
}
case_unverified_premises_do_not_pass() { local R="$1"
  clear_q; plan 10-a.plan.md - "$NOVERD"            # written by hand, premise line, no verificado:
  gate "$R" 10-a.plan.md && return 1
  clear_q; plan 10-a.plan.md "" "$NOVERD"           # `verificado:` present but empty
  gate "$R" 10-a.plan.md && return 1
  clear_q; plan 10-a.plan.md - "$HOLDS"             # hand-written verdict, no verificado: (nobody ran the verifier)
  gate "$R" 10-a.plan.md && return 1
  [ -z "$(night "$R")" ]
}
case_premise_added_after_verifying() { local R="$1"
  clear_q; plan 10-a.plan.md "$V3" "$HOLDS" "$NOVERD"   # verificado: present, but a new line without a verdict
  gate "$R" 10-a.plan.md && return 1
  return 0
}
case_no_premise_lines_pass() { local R="$1"
  clear_q; plan 10-a.plan.md - "- a note without a citation" "a line with :: but no path" "something :: ../x"
  gate "$R" 10-a.plan.md && [ "$(night "$R")" = 10-a.plan.md ]
}
case_applies_without_planificado() { local R="$1"
  # the check does not depend on `planificado:` or `fuente:`: a hand-written plan with a FALSE does not run either
  clear_q; plan 10-a.plan.md "$V3" "$FALSEP"
  grep -q '^planificado:' "$Q/10-a.plan.md" && return 1
  gate "$R" 10-a.plan.md && return 1
  clear_q; plan 10-a.plan.md "$V3" "$FALSEP"
  python3 -c 'import sys; p=sys.argv[1]; s=open(p).read(); open(p,"w").write(s.replace("status: approved\n","status: approved\nplanificado: 2026-10-24\nfuente: telegram\n",1))' "$Q/10-a.plan.md"
  gate "$R" 10-a.plan.md && return 1
  return 0
}
case_the_verifier_section_is_not_exempt() { local R="$1"
  # a FALSE under the "## Verifier" heading counts all the same: that section is not an exempt zone
  clear_q; plan 10-a.plan.md "$V3" "$HOLDS" "" "## Verifier (written by devbrain-verifier)" "" "$FALSEP"
  gate "$R" 10-a.plan.md && return 1
  return 0
}
case_tenth_man_is_not_a_premise() { local R="$1"
  # the tenth man writes `OBJECTION: x :: evidence :: MUST FIX` under its own heading; that is not a premise
  local OBJ='OBJECTION: the hash is not checked :: src/a.txt:3 :: MUST FIX' H='## Tenth man (written by devbrain-tenth-man)'
  clear_q; plan 10-a.plan.md - "" "$H" "" "### Objections" "$OBJ"   # no premises: the gate only looks at unreadable lines if there are none
  gate "$R" 10-a.plan.md || return 1
  # the same line outside that section is still an unreadable premise: it blocks
  clear_q; plan 10-a.plan.md - "$OBJ"
  gate "$R" 10-a.plan.md && return 1
  # and the zone ends at the next `## `: a FALSE after the section blocks
  clear_q; plan 10-a.plan.md "$V3" "$HOLDS" "" "$H" "" "$OBJ"; printf '%s\n' "$FALSEP" >> "$Q/10-a.plan.md"
  gate "$R" 10-a.plan.md && return 1
  return 0
}
# Fails closed: EVERY line with a `:: FALSE|UNVERIFIABLE` verdict blocks, however the citation looks.
blocks() { # <root> <line> -> the gate must say no
  clear_q; plan 10-a.plan.md "$V3" "$HOLDS" "$2"; gate "$1" 10-a.plan.md && return 1
  return 0
}
case_verdict_without_citation_blocks() { blocks "$1" '- x :: FALSE'; }
case_verdict_with_note_blocks() { blocks "$1" '- x :: a.sh:7 :: FALSE (note)'; }
case_lowercase_verdict_blocks() { blocks "$1" '- x :: a.sh:7 :: false'; }
case_range_citation_blocks() { blocks "$1" '- x :: a.sh:7-9 :: FALSE'; }
case_backtick_citation_blocks() { blocks "$1" '- x :: `a.sh:7` :: FALSE'; }
case_range_and_backticks_is_a_premise() { local R="$1"   # recognized as a premise: without verificado: it no longer passes
  clear_q; plan 10-a.plan.md - '- x :: `app.txt:1-1`'
  gate "$R" 10-a.plan.md && return 1
  clear_q; plan 10-a.plan.md "$V3" '- x :: `app.txt:1-1` :: HOLDS'
  gate "$R" 10-a.plan.md
}
case_section_with_unreadable_premises_blocks() { local R="$1"
  clear_q; plan 10-a.plan.md "$V3" '- x :: app.txt line 1' '- y :: app.txt#L2'
  gate "$R" 10-a.plan.md && return 1
  case "$GATE_OUT" in *"none could be read"*) return 0 ;; *) return 1 ;; esac
}
case_fails_closed_if_it_cannot_read() { local R="$1"
  clear_q; gate "$R" no-such.plan.md && return 1
  clear_q; plan 10-a.plan.md "$V3" "$HOLDS"; chmod 000 "$Q/10-a.plan.md"
  gate "$R" 10-a.plan.md; local rc=$?; chmod 644 "$Q/10-a.plan.md"
  [ "$rc" != 0 ]
}

CASES="three_holds_pass false_does_not_pass_anywhere unverifiable_does_not_pass_anywhere unverified_premises_do_not_pass premise_added_after_verifying no_premise_lines_pass applies_without_planificado the_verifier_section_is_not_exempt verdict_without_citation_blocks verdict_with_note_blocks lowercase_verdict_blocks range_citation_blocks backtick_citation_blocks range_and_backticks_is_a_premise section_with_unreadable_premises_blocks tenth_man_is_not_a_premise fails_closed_if_it_cannot_read"
for c in $CASES; do "case_$c" "$DIR" && echo "OK: $c" || { echo "FAIL: case $c"; exit 1; }; done

# ---- approve: warns, does not block (the decision is the owner's, but they see it first) ----
git -C "$Q" init -q 2>/dev/null; git -C "$Q" config user.email t@t.t; git -C "$Q" config user.name t
printf '#!/bin/bash\nexit 0\n' > "$TMP/pf"; chmod +x "$TMP/pf"
mkdir -p "$TMP/wiki/projects"; git -C "$TMP/wiki" init -q 2>/dev/null
cq() { DEVBRAIN_QUEUE_DIR="$Q" DEVBRAIN_WIKI_DIR="$TMP/wiki" DAY_ENGINE="$DIR/lib/day_engine.py" DAY_PREFLIGHT_BIN="$TMP/pf" \
  RESEARCH_ALLOWFILE="$TMP/allow" "$DIR/bin/devbrain-queue" "$@" 2>&1 < /dev/null; }
fmget() { sed -n "s/^$2: //p" "$1" | head -1; }
clear_q
{ printf -- '---\nrepo: demo\nstatus: requested\nprioridad: 30\n---\n\n# T\n\n%s\n%s\n' "$HOLDS" "$FALSEP"; } > "$Q/30-x.plan.md"
git -C "$Q" add -A >/dev/null 2>&1; git -C "$Q" commit -qm base >/dev/null 2>&1
out="$(cq approve 30)"; rc=$?
[ "$rc" = 0 ] && [ "$(fmget "$Q/30-x.plan.md" status)" = approved ] && echo "OK: approve approves a plan with a FALSE (does not block)" || { echo "$out"; die; }
case "$out" in *"the function exists"*) echo "OK: and warns which premise is FALSE" ;; *) echo "$out"; die ;; esac
clear_q
{ printf -- '---\nrepo: demo\nstatus: requested\nprioridad: 31\nverificado: %s\n---\n\n# T\n\n%s\n' "$V3" "$HOLDS"; } > "$Q/31-x.plan.md"
git -C "$Q" add -A >/dev/null 2>&1; git -C "$Q" commit -qm base2 >/dev/null 2>&1
out="$(cq approve 31)"
case "$out" in *"Approved: #31"*) ;; *) echo "$out"; die ;; esac
case "$out" in *premise*|*FALSE*|*UNVERIFIABLE*) echo "FAIL: a plan without a FALSE should carry no premise warning: $out"; die ;; esac
echo "OK: a plan without a FALSE is approved with no warning"

# ---- change deletes verificado: (the changed plan is verified again) ----
clear_q
{ printf -- '---\nrepo: demo\nstatus: requested\nprioridad: 32\nverificado: %s\n---\n\n# T\n\n%s\n' "$V3" "$HOLDS"; } > "$Q/32-x.plan.md"
git -C "$Q" add -A >/dev/null 2>&1; git -C "$Q" commit -qm base3 >/dev/null 2>&1
out="$(cq change 32: "change something")"; case "$out" in *"Noted on #32"*) ;; *) echo "$out"; die ;; esac
[ -z "$(fmget "$Q/32-x.plan.md" verificado)" ] && echo "OK: change deletes verificado:" || die
python3 -c 'import sys,re; p=sys.argv[1]; s=open(p).read(); open(p,"w").write(re.sub(r"(?m)^status: .*$","status: approved\naprobado: 2026-10-24",s,count=1))' "$Q/32-x.plan.md"
gate "$DIR" 32-x.plan.md && { echo "FAIL: after change the plan still passes the gate"; die; }; echo "OK: after change the plan does not pass the gate until it is re-verified"

# ---- mutations ----
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
must_red() { "case_$2" "$MUTD" && { echo "FAIL: the mutation \"$1\" goes unnoticed: case $2 cannot fail"; die; }; echo "OK: the mutation \"$1\" goes red in $2"; }
mutate "ignores FALSE" lib/verifier.py "s.replace('BAD_VERDICTS = (\"FALSE\", \"UNVERIFIABLE\")', 'BAD_VERDICTS = (\"UNVERIFIABLE\",)')"
must_red "ignores FALSE" false_does_not_pass_anywhere
mutate "ignores UNVERIFIABLE" lib/verifier.py "s.replace('BAD_VERDICTS = (\"FALSE\", \"UNVERIFIABLE\")', 'BAD_VERDICTS = (\"FALSE\",)')"
must_red "ignores UNVERIFIABLE" unverifiable_does_not_pass_anywhere
mutate "accepts an empty verificado: with premises" lib/verifier.py "s.replace('if not verified:', 'if False:')"
must_red "accepts an empty verificado:" unverified_premises_do_not_pass
mutate "only plans with planificado:" lib/verifier.py "s.replace('def gate(', 'def gate(path, root=None):\n    return gate_old(path, root) if \"\\\\nplanificado:\" in open(path, encoding=\"utf-8\").read() else (0, \"\")\n\n\ndef gate_old(')"
must_red "only plans with planificado:" applies_without_planificado
mutate "the verifier section is an exempt zone" lib/verifier.py "s.replace('EXEMPT = \"## Tenth man (written by devbrain-tenth-man)\"', 'EXEMPT = \"## Verifier\"')"
must_red "the verifier section is an exempt zone" the_verifier_section_is_not_exempt
mutate "the night does not call the gate" bin/devbrain-night "s.replace('queue_premisas_ok \"\$f\" || continue', ':')"
must_red "the night does not call the gate" false_does_not_pass_anywhere
mutate "fails open if it cannot read" lib/queue.sh "s.replace('|| return 1  # fail closed', '|| return 0  # fail closed')"
must_red "fails open if it cannot read" fails_closed_if_it_cannot_read
mutate "the verdict only in uppercase" lib/verifier.py "s.replace(', re.I)', ')')"
must_red "the verdict only in uppercase" lowercase_verdict_blocks
mutate "unreadable premises pass" lib/verifier.py "s.replace('if odd:', 'if False:')"
must_red "unreadable premises pass" section_with_unreadable_premises_blocks
mutate "the tenth man is not an exempt zone" lib/verifier.py "s.replace('EXEMPT = \"## Tenth man', 'EXEMPT = None  # \"## Tenth man')"
must_red "the tenth man is not an exempt zone" tenth_man_is_not_a_premise

# control: a mutation with no effect leaves everything green
mutate "control: a comment" lib/verifier.py "s + '\n# control\n'"
for c in $CASES; do "case_$c" "$MUTD" || { echo "FAIL: the control (just a comment) broke $c: the mutation setup is not reliable"; die; }; done
echo "OK: the control leaves the $(echo $CASES | wc -w | tr -d ' ') cases green"
echo "PASS: test-queue-premise-gate"

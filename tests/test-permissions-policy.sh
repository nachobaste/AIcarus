#!/bin/bash
# tests/test-permissions-policy.sh — `devbrain-permissions check` validates the repo's permission files
# (config/devbrain-projects.allow + .excluded, openclaw/exec-approvals.json) and FAILS CLOSED.
#
#   1  the shipped files: exit 0
#   2  each rule has a planted case that must go red (and a control that must stay green)
#   3  missing / unreadable / wrongly shaped files are never green
#   4  every rule, removed in a COPY of the validator, turns its planted case green (the test can see)
#   5  it never prints a value read from a file, never writes, never touches HOME
#   6  the preflight runs it and fails closed when it cannot
[ -z "${OPENCLAW_CLI+x}" ] && [ "${OPENCLAW_SHELL-}" != exec ] || { echo "FAIL: these tests do not run under OpenClaw" >&2; exit 1; }
set -uo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
VAL="$DIR/bin/devbrain-permissions"; PF="$DIR/bin/devbrain-preflight"
die() { echo "FAIL: line ${BASH_LINENO[0]}" >&2; exit 1; }
T="$(cd "$(mktemp -d)" && pwd -P)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/home"
CFG="$T/config"; EX="$T/exec-approvals.json"

tree() { # healthy tree built from the shipped files
  rm -rf "$CFG"; mkdir -p "$CFG"
  cp "$DIR/config/devbrain-projects.allow" "$DIR/config/devbrain-projects.excluded" "$CFG/"
  printf 'example-org/app\n' >> "$CFG/devbrain-projects.allow"
  printf 'example-org/old # retired\n' >> "$CFG/devbrain-projects.excluded"
  cp "$DIR/openclaw/exec-approvals.json" "$EX"
}
mut() { # <file> <python on s, assigns n>
  python3 -c 'import sys
f=sys.argv[1]; s=open(f).read(); n=s; exec(sys.argv[2]); assert n != s, "mutation changed nothing"
open(f,"w").write(n)' "$1" "$2" || { echo "FAIL: mutation did not run: $2" >&2; exit 1; }
}
run() { # [validator] -> $T/out, RC
  env -i HOME="$T/home" PATH="$PATH" DEVBRAIN_MC_DIR="$CFG" DEVBRAIN_EXEC_APPROVALS="$EX" "${1:-$VAL}" check >"$T/out" 2>&1; RC=$?
}
red()   { run; [ "$RC" = 1 ] && grep -qF -- "$2" "$T/out" && echo "ok: $1" || { cat "$T/out" >&2; echo "(rc=$RC)" >&2; die; }; }
green() { run; [ "$RC" = 0 ] && echo "ok: $1" || { cat "$T/out" >&2; echo "(rc=$RC)" >&2; die; }; }
ej() { tree; mut "$EX" "$1"; }

# ---- 1. shipped files ---------------------------------------------------------------------------------
env -i HOME="$T/home" PATH="$PATH" DEVBRAIN_MC_DIR="$DIR/config" DEVBRAIN_EXEC_APPROVALS="$DIR/openclaw/exec-approvals.json" "$VAL" check >"$T/out" 2>&1 \
  && [ ! -s "$T/out" ] && echo "ok: 1 the shipped files pass, silently" || { cat "$T/out" >&2; die; }
tree; green "1 healthy tree"

# ---- 2. one planted case per rule ---------------------------------------------------------------------
tree; printf 'example-org/app\n' >> "$CFG/devbrain-projects.allow";    red "2 duplicate in allow" "devbrain-projects.allow line"
tree; printf 'Example-Org/APP\n' >> "$CFG/devbrain-projects.allow";    red "2 duplicate differing by case" "duplicate repo"
tree; printf 'example-org/app/\n' >> "$CFG/devbrain-projects.allow";   red "2 duplicate differing by trailing slash" "duplicate repo"
tree; printf 'example-org/old\n' >> "$CFG/devbrain-projects.excluded"; red "2 duplicate in excluded" "devbrain-projects.excluded line"
tree; printf 'example-org/old\n' >> "$CFG/devbrain-projects.allow";    red "2 repo in both allow and excluded" "also in devbrain-projects.excluded"
tree; printf 'EXAMPLE-ORG/OLD/\n' >> "$CFG/devbrain-projects.allow";   red "2 in both despite case and slash" "also in"
ej "n = s.replace('\"version\": 1', '\"version\": 2')";               red "2 version 2" "version"
ej "n = s.replace('\"version\": 1', '\"version\": true')";            red "2 version true (True == 1 in python)" "version"
ej "n = s.replace('\"version\": 1,', '')";                             red "2 no version" "version"
ej "n = s.replace('\"security\": \"allowlist\"', '\"security\": \"full\"')"; red "2 agents.main.security full" "security"
ej "n = s.replace('\"security\": \"deny\"', '\"security\": \"allowlist\"')"; red "2 defaults.security not deny" "defaults"
ej "n = s.replace('\"main\"', '\"primary\"')";                         red "2 no main agent" "main"
ej "n = s.replace('\"agents\": {', '\"agents\": {\"other\": {\"security\": \"full\", \"allowlist\": []},')"; red "2 other agent with security full, named by position" "agents[0].security"
ej "n = s.replace('/ABSOLUTE/PATH/TO/YOUR/CLONE/OF/THIS/REPO/bin/devbrain-queue', '/usr/local/bin/*')"; red "2 wildcard" "wildcard"
ej "n = s.replace('/ABSOLUTE/PATH/TO/YOUR/CLONE/OF/THIS/REPO/bin/devbrain-queue', 'bin/devbrain-queue')"; red "2 relative path" "absolute"
ej "n = s.replace('/ABSOLUTE/PATH/TO/YOUR/CLONE/OF/THIS/REPO/bin/devbrain-queue', '~/bin/devbrain-queue')"; green "2 control: ~/ path is valid"
ej "n = s.replace('\"pattern\"', '\"patron\"', 1)";                    red "2 entry without pattern" "pattern"
ej "n = s.replace('\"allowlist\": [', '\"allowlist\": {\"pattern\": \"/x\"}, \"x\": [', 1)"; red "2 allowlist not a list" "not a list"

# ---- 3. unreadable: never green -----------------------------------------------------------------------
tree; head -c 60 "$EX" > "$T/t" && mv "$T/t" "$EX";                  red "3 truncated JSON" "JSON"
tree; : > "$EX";                                                       red "3 empty JSON" "JSON"
tree; rm "$EX";                                                        red "3 missing exec-approvals" "exec-approvals"
tree; echo '[]' > "$EX";                                               red "3 root not an object" "object"
tree; echo '{"version":1,"defaults":{"security":"deny"},"agents":[]}' > "$EX"; red "3 agents not an object" "agents"
tree; rm "$CFG/devbrain-projects.allow";                               red "3 allow missing" "devbrain-projects.allow"
tree; rm "$CFG/devbrain-projects.excluded";                            red "3 excluded missing" "devbrain-projects.excluded"
tree; printf '\377\376 not utf-8\n' > "$CFG/devbrain-projects.allow";  red "3 allow not UTF-8" "devbrain-projects.allow"

# ---- 4. each rule, removed in a copy, lets its planted case through -----------------------------------
mutated() { # <name> <old> <new>... -> path of a copy of the validator with exact replacements
  local d="$T/mut-${1// /_}"; shift; mkdir -p "$d/bin"; ln -sfn "$DIR/lib" "$d/lib"
  python3 -c 'import sys
s=open(sys.argv[1]).read(); a=sys.argv[3:]
for i in range(0, len(a), 2):
    assert s.count(a[i]) == 1, "not found exactly once: " + a[i]
    s = s.replace(a[i], a[i+1])
open(sys.argv[2], "w").write(s)' "$VAL" "$d/bin/devbrain-permissions" "$@" || { echo "FAIL: cannot mutate" >&2; exit 1; }
  chmod +x "$d/bin/devbrain-permissions"; echo "$d/bin/devbrain-permissions"
}
norule() { # <rule id> -> copy whose rule returns [] straight away
  local d="$T/nor-$1"; mkdir -p "$d/bin"; ln -sfn "$DIR/lib" "$d/lib"
  python3 -c 'import re,sys
s=open(sys.argv[1]).read()
n=re.sub(r"(^def rule_"+sys.argv[2]+r"\(.*\):\n)", r"\1    return []\n", s, count=1, flags=re.M)
assert n != s, "no rule_"+sys.argv[2]
open(sys.argv[3],"w").write(n)' "$VAL" "$1" "$d/bin/devbrain-permissions" || { echo "FAIL: no rule $1" >&2; exit 1; }
  chmod +x "$d/bin/devbrain-permissions"; echo "$d/bin/devbrain-permissions"
}
canary() { # <name> <planting function> <validator copy>: red with the real one, green with the copy
  tree; "$2"; run; [ "$RC" = 1 ] || { cat "$T/out" >&2; echo "FAIL: planted case $1 is not red with the real validator" >&2; die; }
  run "$3"; [ "$RC" = 0 ] && echo "ok: 4 without $1 its planted case goes green (the test can see)" || { cat "$T/out" >&2; die; }
}
p_duplicate() { printf 'example-org/app\n' >> "$CFG/devbrain-projects.allow"; }
p_both()      { printf 'example-org/old\n' >> "$CFG/devbrain-projects.allow"; }
p_json()      { head -c 60 "$EX" > "$T/t" && mv "$T/t" "$EX"; }
p_form()      { mut "$EX" "n = s.replace('\"allowlist\": [', '\"allowlist\": {\"pattern\": \"/x\"}, \"x\": [', 1)"; }
p_version()   { mut "$EX" "n = s.replace('\"version\": 1', '\"version\": 2')"; }
p_main()      { mut "$EX" "n = s.replace('\"security\": \"allowlist\"', '\"security\": \"full\"')"; }
p_defaults()  { mut "$EX" "n = s.replace('\"security\": \"deny\"', '\"security\": \"allowlist\"')"; }
p_wildcard()  { mut "$EX" "n = s.replace('/ABSOLUTE/PATH/TO/YOUR/CLONE/OF/THIS/REPO/bin/devbrain-queue', '/usr/local/bin/*')"; }
p_absolute()  { mut "$EX" "n = s.replace('/ABSOLUTE/PATH/TO/YOUR/CLONE/OF/THIS/REPO/bin/devbrain-queue', 'bin/x')"; }
for r in duplicate both json form version main defaults wildcard absolute; do
  case "$r" in duplicate) id=p_duplicate;; both) id=p_both;; json) id=e_json;; form) id=e_form;; version) id=e_version;;
    main) id=e_main;; defaults) id=e_defaults;; wildcard) id=e_wildcard;; absolute) id=e_absolute;; esac
  canary "rule_$id" "p_$r" "$(norule "$id")"
done
# the normalisation, one step at a time; the wildcard class, one character at a time; missing-file rules
n_both_lower() { printf 'EXAMPLE-ORG/OLD\n' >> "$CFG/devbrain-projects.allow"; }
n_both_slash() { printf 'example-org/old/\n' >> "$CFG/devbrain-projects.allow"; }
NORM='return repo.strip().rstrip("/").lower()'
canary "lower()"  n_both_lower "$(mutated lower "$NORM" 'return repo.strip().rstrip("/")')"
canary "rstrip()" n_both_slash "$(mutated rstrip "$NORM" 'return repo.strip().lower()')"
WC='WILDCARD = re.compile(r"[*?\[\]{}]")'
i=0; for ch in '*' '?' '[' ']' '{' '}'; do
  i=$((i+1)); p() { mut "$EX" "n = s.replace('/ABSOLUTE/PATH/TO/YOUR/CLONE/OF/THIS/REPO/bin/devbrain-queue', '/usr/local/bin/a${ch}b')"; }
  new="$(python3 -c 'import sys;print("WILDCARD = re.compile(r\"[" + "*?\\[\\]{}".replace(sys.argv[1], "", 1) + "]\")")' "$ch")"
  canary "wildcard $ch" p "$(mutated "w$i" "$WC" "$new")"
done
p_no_allow() { rm "$CFG/devbrain-projects.allow"; }; p_no_ex() { rm "$CFG/devbrain-projects.excluded"; }
canary "allow-missing check" p_no_allow "$(mutated noallow 'note("devbrain-projects.allow", ["missing or unreadable"])' 'pass')"
canary "excluded-missing check" p_no_ex "$(mutated noex 'note("devbrain-projects.excluded", ["missing or unreadable"])' 'pass')"
# a rule that crashes is red, never green; an uncaught exception is one line, never a traceback
BOOM='df = d.get("defaults")'
tree; m="$(mutated boom "$BOOM" 'raise ValueError("CANARYboom0123456789")')"; run "$m"
[ "$RC" = 1 ] && grep -q 'rule_e_defaults could not run (ValueError)' "$T/out" && ! grep -q CANARY "$T/out" \
  && echo "ok: 4 a crashing rule is red, message not printed" || { cat "$T/out" >&2; die; }
m="$(mutated boom-open "$BOOM" 'raise ValueError("x")' 'return [f"rule {f.__name__} could not run ({type(e).__name__})"]' 'return []')"; run "$m"
[ "$RC" = 0 ] && echo "ok: 4 without the crash guard a broken rule goes green (the test can see)" || { cat "$T/out" >&2; die; }
SINK='problems, warnings = [], []'
tree; m="$(mutated deep "$SINK" "$SINK; raise RecursionError('CANARYdeep0123456789')")"; run "$m"
[ "$RC" = 1 ] && grep -q '^permissions: validator could not finish (RecursionError)' "$T/out" && ! grep -q 'Traceback\|CANARY' "$T/out" \
  && echo "ok: 4 uncaught exception: one line, red" || { cat "$T/out" >&2; die; }
m="$(mutated nocatch "$SINK" "$SINK; raise RecursionError('x')" 'except Exception as e:  # no traceback' 'except KeyError as e:  # no traceback')"; run "$m"
grep -q Traceback "$T/out" && echo "ok: 4 without the outer catch a traceback shows (the test can see)" || { cat "$T/out" >&2; die; }
tree; "$VAL" bogus >/dev/null 2>&1; [ $? = 2 ] && echo "ok: 4 unknown subcommand: usage, rc 2" || die

# ---- 5. no values printed, no writes ------------------------------------------------------------------
K1=sk-ant-api03-CANARYone0123456789ABCDEFGHIJKLMNOP; K2=ghp_CANARYtwo0123456789abcdefghijklmnopqrstu; K3=CANARYthree0123456789abcdef0123456789abcdef01
leaky() {
  tree
  printf '%s\n%s\n%s\n' "$K1" "$K1" "$K2" >> "$CFG/devbrain-projects.allow"; printf '%s\n%s\n' "$K2" "$K2" >> "$CFG/devbrain-projects.excluded"
  python3 -c 'import json,sys
f=sys.argv[1]; d=json.load(open(f)); k=sys.argv[2:]; ag=d["agents"]
ag[k[0]]={"security":"full","allowlist":[{"pattern":k[1]+"*"},{"pattern":k[1]},{"pattern":5}]}
ag[k[1]]=5; ag[k[2]]={"security":"allowlist","allowlist":{"pattern":k[2]}}
d["version"]=k[2]; d["defaults"]["security"]=k[0]; d[k[1]]=k[0]
json.dump(d,open(f,"w"))' "$EX" "$K1" "$K2" "$K3"
}
leak() { grep -E 'CANARY|sk-ant|ghp_' "$1" >/dev/null; }
leaky; run; [ "$RC" = 1 ] && echo "ok: 5 control: the tree with keys is red" || die
for m in "duplicate repo" "also in" "not an object" "not a list" "wildcard" "not an absolute path" "has no text pattern" \
         ".security is not allowlist" "version is not 1" "defaults.security is not deny"; do
  grep -qF -- "$m" "$T/out" || { cat "$T/out" >&2; echo "FAIL: rule \"$m\" did not fire: the canary would prove nothing" >&2; die; }
done
! leak "$T/out" && echo "ok: 5 no key is printed (repo, agent name, pattern, version, defaults)" || { cat "$T/out" >&2; die; }
leakmut() { local m; m="$(mutated "$@")"; leaky; run "$m"; leak "$T/out" && echo "ok: 5 mutant \"$1\": the key shows (the test can see)" || { cat "$T/out" >&2; die; }; }
leakmut leak-agent 'return "agents.main" if name == "main" else f"agents[{list(agents).index(name)}]"' 'return f"agents.{name}"'
leakmut leak-repo 'duplicate repo (compared' 'duplicate repo {r} (compared'
leakmut leak-both 'the repo is also in' '{r} is also in'
leakmut leak-wild 'f"{where}: the pattern has a wildcard"' 'f"{where}: the pattern {p} has a wildcard"'
leakmut leak-abs 'f"{where}: the pattern is not an absolute path' 'f"{where}: the pattern {p} is not an absolute path'
tree; before="$(cd "$T" && find config exec-approvals.json -type f -print0 | sort -z | xargs -0 shasum | shasum)"; run
after="$(cd "$T" && find config exec-approvals.json -type f -print0 | sort -z | xargs -0 shasum | shasum)"
[ "$before" = "$after" ] && [ -z "$(ls -A "$T/home")" ] && echo "ok: 5 writes nothing, leaves HOME alone" || die

# ---- 6. the preflight runs it -------------------------------------------------------------------------
pf() { # <preflight> -> $T/pout, PRC (empty queue, no network)
  rm -rf "$T/q" "$T/projects"; mkdir -p "$T/q" "$T/projects"
  env -i HOME="$T/home" PATH="$PATH" DEVBRAIN_QUEUE_DIR="$T/q" DEVBRAIN_MC_DIR="$CFG" DEVBRAIN_EXEC_APPROVALS="$EX" \
    DEVBRAIN_PROJECTS_DIR="$T/projects" DEVBRAIN_PREFLIGHT_NO_FETCH=1 "$1" >"$T/pout" 2>&1; PRC=$?
}
pftree() { rm -rf "$1"; mkdir -p "$1/bin"; ln -sfn "$DIR/lib" "$1/lib"; cp "$PF" "$1/bin/devbrain-preflight"; }
tree; pf "$PF"; ! grep -q 'permissions' "$T/pout" && echo "ok: 6 control: healthy tree, no permissions line" || { cat "$T/pout" >&2; die; }
tree; mut "$EX" "n = s.replace('\"version\": 1', '\"version\": 2')"; pf "$PF"
[ "$PRC" = 1 ] && grep -q 'permissions' "$T/pout" && echo "ok: 6 broken exec-approvals: preflight red" || { cat "$T/pout" >&2; die; }
tree; printf 'example-org/old\n' >> "$CFG/devbrain-projects.allow"; pf "$PF"
[ "$PRC" = 1 ] && grep -q 'also in' "$T/pout" && echo "ok: 6 repo in allow and excluded: preflight red" || { cat "$T/pout" >&2; die; }
leaky; pf "$PF"; grep 'permissions:' "$T/pout" > "$T/pl"
[ -s "$T/pl" ] && ! leak "$T/pl" && echo "ok: 6 no key reaches the preflight output" || { cat "$T/pout" >&2; die; }
tree; pftree "$T/pf-none"; pf "$T/pf-none/bin/devbrain-preflight"
[ "$PRC" = 1 ] && grep -q 'permissions' "$T/pout" && echo "ok: 6 validator missing next to the preflight: red" || { cat "$T/pout" >&2; die; }
tree; pftree "$T/pf-bad"; printf '#!/bin/bash\necho SECRET-NOT-TO-SHOW\nexit 2\n' > "$T/pf-bad/bin/devbrain-permissions"; chmod +x "$T/pf-bad/bin/devbrain-permissions"
pf "$T/pf-bad/bin/devbrain-preflight"
[ "$PRC" = 1 ] && grep -q 'permissions' "$T/pout" && ! grep -q SECRET-NOT "$T/pout" && echo "ok: 6 validator exit 2: red, output not dumped" || { cat "$T/pout" >&2; die; }
tree; pftree "$T/pf-ok"; printf '#!/bin/bash\necho "warning: x"\nexit 0\n' > "$T/pf-ok/bin/devbrain-permissions"; chmod +x "$T/pf-ok/bin/devbrain-permissions"
pf "$T/pf-ok/bin/devbrain-preflight"; [ "$PRC" = 0 ] && echo "ok: 6 validator exit 0: preflight green" || { cat "$T/pout" >&2; die; }
echo "ok: test-permissions-policy complete"

#!/bin/bash
# tests/test-devbrain-security.sh: the security reviewer (bin/devbrain-security, bin/devbrain-security-accept,
# lib/security.py) and its PR wiring in `devbrain execute`.
#
# A fake `claude` writes whatever is in $FAKE_DIR/reply. Temporary HOME, results dir, session registry and repo:
# nothing real is touched, nothing leaves the machine.
#
# Each case is a function `case_*  <root>` returning 0 on pass. They run against the real tree and, against a
# MUTATED COPY, the case that catches the mutation must go RED (a mutation nobody notices is a test that cannot
# fail). A final control mutation (a comment) must leave everything green.
[ -z "${OPENCLAW_CLI+x}" ] && [ "${OPENCLAW_SHELL-}" != exec ] || { echo "FAIL: these tests do not run under OpenClaw" >&2; exit 1; }
set -uo pipefail
export DEVBRAIN_NO_TG=1
die() { echo "FAIL: ${1:-test-devbrain-security.sh:${BASH_LINENO[0]}}"; exit 1; }
DIR="$(cd "$(dirname "$0")/.." && pwd)"
for f in bin/devbrain-security bin/devbrain-security-accept lib/security.py; do [ -f "$DIR/$f" ] || die "$f does not exist"; done

REALHOME="$HOME"
TMP="$(cd "$(mktemp -d)" && pwd -P)"; trap 'rm -rf "${TMP:?}"' EXIT
mkdir -p "$TMP/home" "$TMP/tmpdir" "$TMP/fake" "$TMP/sec"; export HOME="$TMP/home" TMPDIR="$TMP/tmpdir"
[ "$HOME" != "$REALHOME" ] || die "HOME is not temporary; aborting before touching anything"
export FAKE_DIR="$TMP/fake" DEVBRAIN_SECURITY_DIR="$TMP/sec" DEVBRAIN_SESSIONS_FILE="$TMP/sessions.tsv" DEVBRAIN_CLAUDE_BIN="$TMP/claude"

# worktree under review: src/a.txt has 5 lines
WT="$TMP/wt"; mkdir -p "$WT/src"; printf 'one\ntwo\nthree\nfour\nfive\n' > "$WT/src/a.txt"
cat > "$TMP/claude" <<'FAKE'
#!/bin/bash
cat > /dev/null
printf '%s\n' "$*" >> "$FAKE_DIR/args"
cat "$FAKE_DIR/reply" 2>/dev/null
FAKE
chmod +x "$TMP/claude"

# ---- inputs ------------------------------------------------------------------------------------------
diff_of() { # <path> <line>   -> a one-line diff that adds <line> to <path>
  printf 'diff --git a/%s b/%s\n--- a/%s\n+++ b/%s\n@@ -1,1 +1,2 @@\n context\n+%s\n' "$1" "$1" "$1" "$1" "$2"; }
model() { # <verdict> <finding lines...> -> the model's answer
  { echo "SECURITY: $1"; echo "## Scope"; echo "read the diff"; echo "## Findings"; shift; for l in "$@"; do echo "$l"; done; } > "$FAKE_DIR/reply"; }
reg() { printf '%s\t%s\t%s\t2026-01-01T00:00:00Z\n' "$1" "$2" "$3" >> "$DEVBRAIN_SESSIONS_FILE"; }
# acc <root> <plan> <diff-file> [extra args...] -> runs the acceptor with the model's reply; result in $TMP/acc-out
acc() { local r="$1" p="$2" d="$3"; shift 3
  "$r/bin/devbrain-security-accept" --mode pr --plan "$p" --worktree "$WT" --dir "$TMP/sec" --input "$d" \
    --output "$FAKE_DIR/reply" --session "s-$p" --registry "$DEVBRAIN_SESSIONS_FILE" "$@" > "$TMP/acc-out" 2>&1; }
first() { head -1 "$TMP/acc-out"; }
newplan() { rm -f "$TMP/sec/$1.md"; reg "s-$1" "$1" security; }

# ============================== cases ==============================================================================
case_fixed_rule_blocks() { local R="$1" d="$TMP/d.diff"
  newplan 1; rm -f "$FAKE_DIR/reply"                                  # the model produced nothing at all
  diff_of ".claude/settings.json" "x" > "$d"; acc "$R" 1 "$d" || return 1
  [ "$(first)" = "SECURITY: BLOCKS" ] && grep -q 'change to an agent configuration file' "$TMP/acc-out" || return 1
  newplan 2; model OK; diff_of "src/b.txt" '  "allowedTools": ["Bash"]' > "$d"; acc "$R" 2 "$d" || return 1
  [ "$(first)" = "SECURITY: BLOCKS" ] && grep -q 'NOTE: the model declared SECURITY: OK' "$TMP/acc-out" || return 1
  newplan 3; model OK; diff_of "src/b.txt" 'just text' | sed 's/^+just text/ allowedTools in context/' > "$d"; acc "$R" 3 "$d" || return 1
  [ "$(first)" = "SECURITY: OK" ]                                      # a context line never trips the rule
}
case_model_findings() { local R="$1" d="$TMP/d.diff"; diff_of "src/b.txt" 'plain' > "$d"
  newplan 4; model BLOCKS "FINDING: secrets :: src/a.txt:2 :: BLOCKS :: a key is read :: confidence: 79"; acc "$R" 4 "$d" || return 1
  [ "$(first)" = "SECURITY: OK" ] && grep -q 'dropped for confidence below 80' "$TMP/acc-out" || return 1   # below the threshold
  newplan 5; model OK "FINDING: secrets :: src/a.txt:2 :: BLOCKS :: a key is read :: confidence: 90"; acc "$R" 5 "$d" || return 1
  [ "$(first)" = "SECURITY: BLOCKS" ] || return 1                      # real evidence at 90: it blocks, whatever the model says
  newplan 6; model BLOCKS "FINDING: secrets :: src/a.txt:99 :: BLOCKS :: a key is read :: confidence: 95" \
    "FINDING: made-up :: src/a.txt:2 :: BLOCKS :: invented :: confidence: 95" "FINDING: secrets :: ../x:1 :: BLOCKS :: escape :: confidence: 95"; acc "$R" 6 "$d" || return 1
  [ "$(first)" = "SECURITY: OK" ] && [ "$(grep -c 'NOTICE (NO EVIDENCE)' "$TMP/acc-out")" = 3 ]   # no evidence or invented category: a NOTICE
}
case_secrets_are_masked() { local R="$1" d="$TMP/d.diff"; diff_of "src/b.txt" 'plain' > "$d"
  newplan 7; model OK "FINDING: secrets :: src/a.txt:2 :: NOTICE :: found ghp_$(printf 'a%.0s' $(seq 36)) in the file :: confidence: 90"; acc "$R" 7 "$d" || return 1
  grep -q '\[secret:github\]' "$TMP/acc-out" && ! grep -q "ghp_a" "$TMP/acc-out" && ! grep -q "ghp_a" "$TMP/sec/7.md"
}
case_session_must_be_new() { local R="$1" d="$TMP/d.diff"; diff_of "src/b.txt" 'plain' > "$d"; model OK
  rm -f "$TMP/sec/8.md" "$DEVBRAIN_SESSIONS_FILE"                      # not registered
  acc "$R" 8 "$d"; [ $? = 3 ] && [ ! -f "$TMP/sec/8.md" ] && grep -q 'not registered' "$TMP/acc-out" || return 1
  reg "s-8" 8 security; reg "s-8" 8 executor                           # it also had another role
  acc "$R" 8 "$d"; [ $? = 3 ] && [ ! -f "$TMP/sec/8.md" ] && grep -q 'another role' "$TMP/acc-out" || return 1
  # a rejected session still lets the fixed rule write (the rule never depends on the model)
  diff_of ".claude/settings.json" "x" > "$d"
  acc "$R" 8 "$d" --fixed-rule-only || return 1
  [ "$(first)" = "SECURITY: BLOCKS" ] && [ -f "$TMP/sec/8.md" ]
}
case_override_is_bound_to_the_result() { local R="$1" d="$TMP/d.diff" a="$1/bin/devbrain-security-accept"
  newplan 9; model OK; diff_of ".mcp.json" "x" > "$d"; acc "$R" 9 "$d" || return 1
  [ "$("$a" state --dir "$TMP/sec" --plan 9)" = blocks ] || return 1
  "$a" override --dir "$TMP/sec" --plan 9 --via owner --note "   " >/dev/null 2>&1; [ $? = 2 ] || return 1   # the note is required
  "$a" override --dir "$TMP/sec" --plan 9 --via owner --note "reviewed the change" >/dev/null || return 1
  [ "$("$a" state --dir "$TMP/sec" --plan 9)" = overridden ] || return 1
  sleep 1; reg "s-9" 9 security; acc "$R" 9 "$d" || return 1          # a new run is a new result: the old override does not cover it
  [ "$("$a" state --dir "$TMP/sec" --plan 9)" = blocks ]
}
case_wrapper_is_read_only() { local R="$1" r="$TMP/gitrepo"
  rm -rf "${r:?}"; mkdir -p "$r/.claude"; git -C "$r" init -q -b main; git -C "$r" config user.email t@t.t; git -C "$r" config user.name t
  echo base > "$r/a.txt"; git -C "$r" add -A; git -C "$r" commit -qm base
  echo '{}' > "$r/.claude/settings.json"; git -C "$r" add -A; git -C "$r" commit -qm change
  rm -f "$FAKE_DIR/args" "$TMP/sec/10.md"; model OK
  DEVBRAIN_SECURITY_SESSION="s-10" bash -c 'printf "s-10\t10\tsecurity\tx\n" >> "$DEVBRAIN_SESSIONS_FILE"; exec "$0" pr "$1" HEAD~1 10' "$R/bin/devbrain-security" "$r" > "$TMP/wrap-out" 2>&1
  head -1 "$TMP/wrap-out" | grep -q '^SECURITY: BLOCKS$' || { cat "$TMP/wrap-out"; return 1; }   # the fixed rule, not the model
  local a; a="$(tail -1 "$FAKE_DIR/args")"
  case "$a" in *'--tools Read,Glob,Grep'*) ;; *) return 1 ;; esac
  case "$a" in *Edit*|*Write*|*Bash*) return 1 ;; esac
  return 0
}
case_failed_run_keeps_a_recorded_block() { local R="$1" d="$TMP/d.diff"; diff_of "src/b.txt" 'plain' > "$d"
  newplan 11; model BLOCKS "FINDING: secrets :: src/a.txt:3 :: BLOCKS :: a key is read :: confidence: 95"; acc "$R" 11 "$d" || return 1
  [ "$(first)" = "SECURITY: BLOCKS" ] || return 1
  cp "$TMP/sec/11.md" "$TMP/previous.md"
  acc "$R" 11 "$d" --output - || return 1                                # the session failed: no output at all
  cmp -s "$TMP/sec/11.md" "$TMP/previous.md" && [ "$(first)" = "SECURITY: BLOCKS" ] && grep -q 'recorded BLOCKS stands' "$TMP/acc-out"
}
exec_pr() { # <root> -> runs `devbrain execute` of <root>; PR create args land in $TMP/gh-args
  local r="$1" f="$TMP/ex"; rm -rf "${f:?}" "${TMP:?}/gh-args"; mkdir -p "$f/projects"
  git init -q --bare -b main "$f/origin.git"; git clone -q "$f/origin.git" "$f/projects/scratch" 2>/dev/null
  git -C "$f/projects/scratch" config user.email t@t.t; git -C "$f/projects/scratch" config user.name t
  printf '.devbrain/\n' > "$f/projects/scratch/.gitignore"; echo base > "$f/projects/scratch/a.txt"
  git -C "$f/projects/scratch" add -A; git -C "$f/projects/scratch" commit -qm base; git -C "$f/projects/scratch" push -q origin HEAD:main 2>/dev/null
  mkdir -p "$f/projects/scratch/.devbrain"
  printf 'Add feature.txt\n' > "$f/projects/scratch/.devbrain/plan-latest.md"; echo "add feature" > "$f/projects/scratch/.devbrain/task-latest.txt"
  echo 77 > "$f/projects/scratch/.devbrain/prio-latest.txt"
  cat > "$TMP/fake-exec-claude" <<'EOS'
#!/bin/bash
cat >/dev/null
case "$*" in
  *acceptEdits*) echo feature > feature.txt ;;
  *) echo "VERDICT: APPROVE" ;;
esac
EOS
  printf '#!/bin/bash\nprintf "%%s\\n" "$@" > "%s"\necho https://example.test/pull/1\n' "$TMP/gh-args" > "$TMP/fake-gh"
  printf '#!/bin/bash\nprintf "SECURITY: %%s\\n## Scope\\nx\\n## Findings\\n(none)\\n" "$(cat "%s/verdict")"\n' "$TMP" > "$TMP/stub-sec"
  chmod +x "$TMP/fake-exec-claude" "$TMP/fake-gh" "$TMP/stub-sec"; printf 'scratch\n' > "$TMP/allow"
  env DEVBRAIN_PROJECTS_DIR="$f/projects" DEVBRAIN_ALLOWFILE="$TMP/allow" DEVBRAIN_GH_BIN="$TMP/fake-gh" DEVBRAIN_SECURITY_BIN="$TMP/stub-sec" \
    DEVBRAIN_CLAUDE_BIN="$TMP/fake-exec-claude" DEVBRAIN_TENTH_BIN=/usr/bin/true perl -e 'alarm 120; exec @ARGV' "$r/bin/devbrain" execute scratch > "$TMP/exec-out" 2>&1
  grep -q 'https://example.test/pull/1' "$TMP/exec-out" && [ -s "$TMP/gh-args" ]
}
case_execute_draft_on_block() { local R="$1" d="$TMP/d.diff"
  newplan 77; model OK; diff_of ".mcp.json" "x" > "$d"; acc "$R" 77 "$d" || return 1   # a standing BLOCKS result for plan 77
  echo BLOCKS > "$TMP/verdict"; exec_pr "$R" || { tail -5 "$TMP/exec-out"; return 1; }
  grep -qx -- '--draft' "$TMP/gh-args" && grep -q '^\[SECURITY: BLOCKS\] devbrain: ' "$TMP/gh-args" && grep -q '^## Security review$' "$TMP/gh-args" || return 1
  echo OK > "$TMP/verdict"; exec_pr "$R" || return 1                  # no block: a normal PR
  ! grep -qx -- '--draft' "$TMP/gh-args" && ! grep -q 'SECURITY: BLOCKS\] ' "$TMP/gh-args" && grep -q '^## Security review$' "$TMP/gh-args"
}

CASES="fixed_rule_blocks model_findings secrets_are_masked session_must_be_new override_is_bound_to_the_result failed_run_keeps_a_recorded_block wrapper_is_read_only execute_draft_on_block"
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
must_go_red() { "case_$2" "$MUTD" && { echo "FAIL: the mutation \"$1\" goes unnoticed: case $2 cannot fail"; die; }; echo "OK: the mutation \"$1\" goes red in $2"; }
S=lib/security.py
mutate "threshold 0" $S "s.replace('MIN_CONF = 80', 'MIN_CONF = 0')"
must_go_red "threshold 0" model_findings
mutate "settings.json is not an agent file" $S "s.replace('settings[^/]*\\\\.json\$\", r\"\\\\.plist', 'nothing\", r\"\\\\.plist')"
must_go_red "settings.json is not an agent file" fixed_rule_blocks
mutate "the fixed rule does not block" $S "s.replace('bool(fixed) and True', 'False')"
must_go_red "the fixed rule does not block" fixed_rule_blocks
mutate "the override ignores the result hash" $S "s.replace('and c[3] == sha:', ':')"
must_go_red "the override ignores the result hash" override_is_bound_to_the_result
mutate "a rejected session writes a result" $S "s.replace('if reason:', 'if False:')"
must_go_red "a rejected session writes a result" session_must_be_new
mutate "a failed run replaces a recorded BLOCKS" $S "s.replace('if previous.startswith(\"SECURITY: BLOCKS\\\\n\"):', 'if False:')"
must_go_red "a failed run replaces a recorded BLOCKS" failed_run_keeps_a_recorded_block
mutate "secrets are not masked" $S "s.replace('text = secret_patterns.redact(text)', 'pass')"
must_go_red "secrets are not masked" secrets_are_masked
mutate "the session gets Edit" bin/devbrain-security "s.replace('TOOLS=\"Read,Glob,Grep\"', 'TOOLS=\"Read,Glob,Grep,Edit\"')"
must_go_red "the session gets Edit" wrapper_is_read_only
mutate "the PR is never a draft" bin/devbrain "s.replace('PR_DRAFT=(--draft)', 'PR_DRAFT=()')"
must_go_red "the PR is never a draft" execute_draft_on_block

mutate "control: a comment" $S "s + '\n# control\n'"
for c in $CASES; do "case_$c" "$MUTD" || { echo "FAIL: the control (only a comment) broke $c: the mutation setup is not reliable"; die; }; done
echo "OK: the control (comment) leaves the $(echo $CASES | wc -w | tr -d ' ') cases green"
echo "PASS: test-devbrain-security"

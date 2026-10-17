#!/bin/bash
# tests/test-devbrain-env-whitelist.sh — the environment whitelist under OpenClaw.
#
# The two commands the messaging bridge can start (devbrain-queue and devbrain) drop, when
# OpenClaw marks the call, every environment variable that is not on a fixed whitelist; they
# start with `#!/bin/bash -p`; and lib/telegram.sh runs `python3 -I`. The marks mean "comes from
# OpenClaw", not "comes from the person on the other end of the chat".
#
# Cases: S (structure), G (every test refuses to run under the marks), P (isolated python3),
# C1/C1b (end to end: canary executables never run, caller-chosen paths are ignored),
# C2/C2b/C2c/C2d/C2e (the canary table, the control, an undroppable name, the predicate and
# inherited functions), C7 (the privileged shebang).
#
# Run it like this (the OpenClaw marks outside the environment of whoever starts it):
#   env -u OPENCLAW_CLI -u OPENCLAW_SHELL bash tests/test-devbrain-env-whitelist.sh
#
# Set-up: each binary runs under `env -i HOME=$T/home PATH=...`, BY PATH (so the shebang counts),
# with stdout and stderr to files. $T/home is all they see. `claude` is a fake that records
# argv, `pwd -P` and the environment in $T/trace/<key>, and ABORTS if `~` is not $T/home. A check
# that was only ever seen passing is not distinguishable from one that looks at nothing: C2b,
# the controls of C1 and C7 and the planted files of G prove that what they look at can fail.
[ -z "${OPENCLAW_CLI+x}" ] && [ "${OPENCLAW_SHELL-}" != exec ] || { echo "FAIL: these tests do not run under OpenClaw" >&2; exit 1; }
set -uo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; T="$(cd "$T" && pwd -P)"
SAFEPATH=/opt/homebrew/bin:/usr/bin:/bin
FAILS=""
RC=0

# Whatever starts with $T on its command line is killed on exit.
reap() {
  local pids
  pids="$(pgrep -f "$T" 2>/dev/null | grep -vx "$$" || true)"
  [ -z "$pids" ] || kill $pids 2>/dev/null
  printf '%s' "$pids"
}
trap 'reap >/dev/null; rm -rf "$T"' EXIT

red() { FAILS="$FAILS $1 "; echo "FAIL $1: $2"; }
# `good` only speaks if the case has no red: no "OK" under a FAIL.
good() { case "$FAILS" in *" $1 "*) ;; *) echo "OK   $1: $2" ;; esac; }
close_case() {
  local alive
  alive="$(reap)"
  [ -z "$alive" ] || red "$1" "processes with $T were left alive: $alive"
}

# ---- set-up -----------------------------------------------------------------------------------
g() { env -i HOME="$T/home" PATH="$SAFEPATH" git -c user.email=t@t.t -c user.name=t "$@"; }

mkdir -p "$T/home/.local/bin" "$T/home/dev" "$T/trace" "$T/out" "$T/err" "$T/trap" "$T/other" "$T/mc/bin" "$T/mc/config"
# A fake `claude` and a fake preflight. If `~` is not $T/home the child is not the one we think: ABORT.
for who in claude dumper; do
  case "$who" in claude) dest="$T/home/.local/bin/claude"; code=0 ;; *) dest="$T/mc/bin/devbrain-preflight"; code=1 ;; esac
  cat > "$dest" <<EOF
#!/bin/bash
[ "\$(cd ~ 2>/dev/null && pwd -P)" = "$T/home" ] || { echo "~ is not $T/home" > "$T/ABORT"; exit 99; }
n="\$(cat "$T/cur")"
{
  echo "ARGV: \$*"
  echo "CWD: \$(pwd -P)"
  echo "---ENV---"
  /usr/bin/env
} > "$T/trace/\$n"
[ "$who" = claude ] && cat > /dev/null
echo "fake output of $who"
exit $code
EOF
  chmod +x "$dest"
done
# devbrain-queue and devbrain run from a copy of the repo, byte for byte, with their own
# allowlist; the preflight is the dumper above. No case dispatches anything.
cp "$DIR/bin/devbrain-queue" "$DIR/bin/devbrain" "$T/mc/bin/"
cp -R "$DIR/lib" "$T/mc/lib"
printf 'scratch-test\n' > "$T/mc/config/devbrain-projects.allow"

[ "$(env -i HOME="$T/home" PATH="$SAFEPATH" /bin/bash -c 'cd ~ && pwd -P')" = "$T/home" ] \
  || { echo "ABORT: ~ in the child is not $T/home"; exit 1; }
# No token: openclaw.json exists and is empty.
mkdir -p "$T/home/.openclaw"; echo '{}' > "$T/home/.openclaw/openclaw.json"

fresh_scratch() { # the repo `devbrain plan` works on; no `.devbrain/` in .gitignore, so devbrain runs git
  rm -rf "$T/home/dev/projects/scratch-test"; mkdir -p "$T/home/dev/projects/scratch-test"
  g -C "$T/home/dev/projects/scratch-test" init -q -b main
  echo base > "$T/home/dev/projects/scratch-test/a.txt"
  g -C "$T/home/dev/projects/scratch-test" add -A
  g -C "$T/home/dev/projects/scratch-test" commit -q -m base
  g -C "$T/home/dev/projects/scratch-test" config user.email t@t.t
  g -C "$T/home/dev/projects/scratch-test" config user.name t
}
fresh_queue() { # the queue in $T/home, plan 10 not yet approved
  rm -rf "$T/home/dev/queue"; mkdir -p "$T/home/dev/queue"
  printf -- '---\nrepo: scratch-test\nstatus: requested\nprioridad: 10\ncreado: 2026-10-15\n---\n\n# Plan real-home\n\nText.\n' \
    > "$T/home/dev/queue/10-real-home.plan.md"
  g -C "$T/home/dev/queue" init -q -b main
  g -C "$T/home/dev/queue" add -A
  g -C "$T/home/dev/queue" commit -q -m base
}

# run <key> <path> [NAME=value ...] -- [args ...]
# Under env -i, by path, in $RUN_CWD (default $T), output to files.
run() {
  local key="$1" bin="$2"; shift 2
  local assign=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do assign+=("$1"); shift; done
  shift
  rm -f "$T/trace/$key" "$T/py-hit"; printf '%s' "$key" > "$T/cur"
  ( cd "${RUN_CWD:-$T}" && env -i HOME="$T/home" PATH="$SAFEPATH" ${assign[@]+"${assign[@]}"} "$bin" "$@" ) \
    > "$T/out/$key" 2> "$T/err/$key" < /dev/null
  RC=$?
  [ ! -e "$T/ABORT" ] || { echo "ABORT: $(cat "$T/ABORT")"; exit 1; }
}

# invoke <key> [NAME=value ...]: the standard call of each binary (C2).
KEYS="devbrain queue"
invoke() {
  local key="$1"; shift
  case "$key" in
    devbrain) fresh_scratch; run devbrain "$T/mc/bin/devbrain" "$@" -- plan scratch-test "x" ;;
    queue)    fresh_queue; run queue "$T/mc/bin/devbrain-queue" "$@" -- approve 10 ;;
  esac
}

# ---- tables (they live only here) -----------------------------------------------------------
# Canaries: names that are NOT on the whitelist, in families.
# SHELLOPTS is left out on purpose (bash -p makes it readonly and exported: under the mark the
# binary would exit 2, fail closed, and no canary would ever be seen) and POSIXLY_CORRECT (it would
# put bash in POSIX mode from the start and hide the C2e mutations).
FAM_SHELL="BASH_ENV ENV BASHOPTS PS1 PS2 PS4 PROMPT_COMMAND CDPATH IFS GLOBIGNORE FIGNORE MAIL MAILPATH MAILCHECK HISTFILE HISTSIZE HISTCONTROL HISTIGNORE HISTTIMEFORMAT INPUTRC TMPDIR TERM TERMINFO SHELL TIMEFORMAT TMOUT OLDPWD LD_PRELOAD LD_LIBRARY_PATH DYLD_INSERT_LIBRARIES DYLD_LIBRARY_PATH DYLD_FRAMEWORK_PATH DYLD_FALLBACK_LIBRARY_PATH COLUMNS LINES EDITOR VISUAL PAGER TZ LANG LC_ALL LC_CTYPE LC_COLLATE"
FAM_DEVBRAIN="DEVBRAIN_CLAUDE_BIN DEVBRAIN_GH_BIN TELEGRAM_CURL_BIN DEVBRAIN_QUEUE_DIR DEVBRAIN_WIKI_DIR DEVBRAIN_PROJECTS_DIR DEVBRAIN_CONFIG_DIR DEVBRAIN_ALLOWFILE DEVBRAIN_HOUSE_RULES DEVBRAIN_BASE_BRANCH_OVERRIDE_FILE DEVBRAIN_VERIFY_COMMANDS_FILE DEVBRAIN_MIGRATION_BLOCK_FILE DEVBRAIN_MODELS_FILE DAY_ENGINE DAY_PREFLIGHT_BIN RESEARCH_ALLOWFILE SHOW_MAX DEVBRAIN_NO_TG DEVBRAIN_ROOT DEVBRAIN_MC_DIR DEVBRAIN_PREFLIGHT_NO_FETCH DEVBRAIN_MODEL_PLAN DEVBRAIN_MODEL_EXECUTE DEVBRAIN_MODEL_REVIEW DEVBRAIN_MODEL_DIGEST DEVBRAIN_EFFORT_PLAN DEVBRAIN_EFFORT_EXECUTE DEVBRAIN_EFFORT_REVIEW DEVBRAIN_EFFORT_DIGEST DEVBRAIN_PLAN_MODEL DEVBRAIN_EXEC_MODEL"
FAM_GIT="GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CONFIG GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM GIT_CONFIG_NOSYSTEM GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0 GIT_CONFIG_PARAMETERS GIT_EXEC_PATH GIT_TEMPLATE_DIR GIT_ASKPASS GIT_SSH GIT_SSH_COMMAND GIT_PROXY_COMMAND GIT_EDITOR GIT_PAGER GIT_SEQUENCE_EDITOR GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL GIT_NAMESPACE GIT_CEILING_DIRECTORIES GIT_TRACE GIT_CURL_VERBOSE GIT_TERMINAL_PROMPT GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GH_HOST GH_CONFIG_DIR GH_PATH GH_BROWSER GH_REPO GH_PAGER"
FAM_RUNTIME="PYTHONPATH PYTHONHOME PYTHONSTARTUP PYTHONUSERBASE PYTHONINSPECT PYTHONWARNINGS PYTHONDONTWRITEBYTECODE PYTHONPYCACHEPREFIX PYTHONIOENCODING PYTHONUTF8 NODE_OPTIONS NODE_PATH NODE_TLS_REJECT_UNAUTHORIZED NODE_DEBUG SSL_CERT_FILE SSL_CERT_DIR CURL_CA_BUNDLE CURL_HOME REQUESTS_CA_BUNDLE HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY http_proxy https_proxy all_proxy no_proxy SSH_AUTH_SOCK SSH_ASKPASS XDG_CONFIG_HOME XDG_DATA_HOME XDG_CACHE_HOME ANTHROPIC_API_KEY ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN ANTHROPIC_MODEL CLAUDE_CONFIG_DIR CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_OAUTH_TOKEN CLAUDE_CODE_USE_VERTEX OPENAI_API_KEY CLAUDE_CODE_DISABLE_TERMINAL_TITLE"
# Names that do not change which binary runs (C2b, C2d): an invented one, a locale one, a git trace
# one and a `claude` setting that does not redirect it.
NEUTRAL="ZZ_INVENTED LC_MESSAGES GIT_TRACE CLAUDE_CODE_DISABLE_TERMINAL_TITLE"
# Own exports: what each binary exports to its children by itself, outside the whitelist.
own() {
  case "$1" in
    queue)    echo "DAY_ENGINE" ;;   # bin/devbrain-queue exports it for lib/day.sh
    devbrain) echo "" ;;             # `plan`: none (execute exports nothing either)
  esac
}
ALLOWED=" HOME PATH NODE_EXTRA_CA_CERTS NODE_USE_SYSTEM_CA OPENCLAW_CLI OPENCLAW_SHELL PWD SHLVL _ USER LOGNAME "

CAN=()
for n in $FAM_SHELL $FAM_DEVBRAIN $FAM_GIT $FAM_RUNTIME; do CAN+=("$n=zz-$n"); done
CAN+=("USER=zz-USER" "LOGNAME=zz-LOGNAME" "NODE_EXTRA_CA_CERTS=ok-NODE_EXTRA_CA_CERTS" "NODE_USE_SYSTEM_CA=ok-NODE_USE_SYSTEM_CA")
NEU=()
for n in $NEUTRAL; do NEU+=("$n=zz-$n"); done

# verify <case> <key> <label> <mark> ...: what C2, C2d and C2e share (a run with canaries).
verify() {
  local case_="$1" key="$2" label="$3" k envf="$T/envx" own_
  shift 3
  local f="$T/trace/$key"
  [ -f "$f" ] || { red "$case_" "$label: no trace (rc=$RC)"; return 1; }
  sed '1,/^---ENV---$/d' "$f" > "$envf"
  for k in HOME PATH "$@"; do
    grep -q "^$k=" "$envf" || red "$case_" "$label: the trace has no $k"
  done
  if grep -qE '^[A-Za-z_][A-Za-z0-9_]*=zz-' "$envf"; then
    red "$case_" "$label: zz- values arrived: $(grep -E '^[A-Za-z_][A-Za-z0-9_]*=zz-' "$envf" | cut -d= -f1 | tr '\n' ' ')"
  fi
  own_=" $(own "$key") "
  for k in $(sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p' "$envf"); do
    case "$ALLOWED$own_" in *" $k "*) ;; *) red "$case_" "$label: key outside the list: $k" ;; esac
  done
  [ "$(sed -n 's/^USER=//p' "$envf")" = "$(/usr/bin/id -un)" ] || red "$case_" "$label: USER is not id -un"
  [ "$(sed -n 's/^LOGNAME=//p' "$envf")" = "$(/usr/bin/id -un)" ] || red "$case_" "$label: LOGNAME is not id -un"
  grep -qx "NODE_EXTRA_CA_CERTS=ok-NODE_EXTRA_CA_CERTS" "$envf" || red "$case_" "$label: NODE_EXTRA_CA_CERTS did not arrive with its ok-"
  grep -qx "NODE_USE_SYSTEM_CA=ok-NODE_USE_SYSTEM_CA" "$envf" || red "$case_" "$label: NODE_USE_SYSTEM_CA did not arrive with its ok-"
  [ "$(sed -n 's/^HOME=//p' "$envf")" = "$T/home" ] || red "$case_" "$label: HOME is not $T/home"
  return 0
}

# ---- S: structure ------------------------------------------------------------------------------
IFS= read -r -d '' BLOCK <<'BLOCK_END' || true
case "${OPENCLAW_CLI+x}:${OPENCLAW_SHELL-}" in
x:*|:exec)
  POSIXLY_CORRECT=1
  unset -f compgen echo
  for _f in $(compgen -A function); do unset -f "$_f"; done
  for _v in $(compgen -e); do
    case "$_v" in
    HOME|PATH|NODE_EXTRA_CA_CERTS|NODE_USE_SYSTEM_CA|OPENCLAW_CLI|OPENCLAW_SHELL|PWD|SHLVL|_) ;;
    *) unset "$_v" || { echo "whitelist: could not drop $_v" >&2; exit 2; } ;;
    esac
  done
  USER="$(/usr/bin/id -un)"; LOGNAME="$USER"; export USER LOGNAME
  unset _f _v POSIXLY_CORRECT
  ;;
esac
BLOCK_END
BLOCK="${BLOCK%$'\n'}"
case_S() {
  local b f start end n before
  for b in devbrain-queue devbrain; do
    f="$DIR/bin/$b"
    bash -n "$f" 2> "$T/err/n" || red S "$b: bash -n fails"
    [ "$(head -n 1 "$f")" = '#!/bin/bash -p' ] || red S "$b: the first line is not exactly '#!/bin/bash -p'"
    n="$(grep -c '^#== openclaw-whitelist: start ==$' "$f")"
    [ "$n" = 1 ] || red S "$b: the block starts $n times"
    n="$(grep -c '^#== openclaw-whitelist: end ==$' "$f")"
    [ "$n" = 1 ] || red S "$b: the block ends $n times"
    [ "$(sed -n '/^#== openclaw-whitelist: start ==$/,/^#== openclaw-whitelist: end ==$/p' "$f" | sed '1d;$d' | grep -v '^#')" = "$BLOCK" ] \
      || red S "$b: the block is not, byte for byte, the one in this test"
    # the first thing that runs after the header: before the block there are only comments and blank lines
    start="$(grep -n '^#== openclaw-whitelist: start ==$' "$f" | head -n 1 | cut -d: -f1)"
    if [ -n "$start" ]; then
      before="$(sed -n "2,$((start - 1))p" "$f" | grep -vE '^[[:space:]]*(#.*)?$' || true)"
      [ -z "$before" ] || red S "$b: there is code before the block: $(printf '%s' "$before" | head -n 1)"
    else
      red S "$b: there is no block"
    fi
    [ "$(grep -c '^export PATH=' "$f")" = 1 ] || red S "$b: not exactly one '^export PATH=' line"
  done
  # the existing static guard
  env -i HOME="$T/home" PATH="$SAFEPATH" /bin/bash "$DIR/tests/test-claude-bin-absolute.sh" > "$T/out/g2" 2>&1 \
    || red S "tests/test-claude-bin-absolute.sh fails: $(tail -n 1 "$T/out/g2")"
  good S "structure checked in both binaries"
  close_case S
}

# ---- G: the guard of the tests -----------------------------------------------------------------
GUARD='[ -z "${OPENCLAW_CLI+x}" ] && [ "${OPENCLAW_SHELL-}" != exec ] || { echo "FAIL: these tests do not run under OpenClaw" >&2; exit 1; }'
first_code_line() { awk '/^[[:space:]]*#/ {next} /^[[:space:]]*$/ {next} {print; exit}' "$1"; }
without_guard() { # <directory>: every *.sh whose first line of code is not the guard
  local f
  for f in "$1"/*.sh; do
    [ -f "$f" ] || continue
    [ "$(first_code_line "$f")" = "$GUARD" ] || echo "$f"
  done
}
case_G() {
  local p="$T/planted" bad n f
  # the scanner can fail: a file with no guard and one with it, one that has comments before it
  rm -rf "$p"; mkdir -p "$p"
  printf '#!/bin/bash\n# planted test\nset -u\ndevbrain-queue list\n' > "$p/bare.sh"
  printf '#!/bin/bash\n# note\n\n%s\nset -u\ndevbrain-queue list\n' "$GUARD" > "$p/guarded.sh"
  bad="$(without_guard "$p")"
  case "$bad" in *bare.sh*) ;; *) red G "the scanner did not flag the planted file with no guard" ;; esac
  case "$bad" in *guarded.sh*) red G "the scanner flagged a guarded file: $bad" ;; esac
  # static over tests/
  bad="$(without_guard "$DIR/tests")"
  [ -z "$bad" ] || red G "without the guard as the first line of code: $(printf '%s' "$bad" | sed "s|$DIR/||" | tr '\n' ' ')"
  # a run: a guarded file, under a mark, exits 1 and does not touch its HOME
  f="$DIR/tests/test-devbrain-queue-verbs.sh"
  for n in OPENCLAW_CLI=1 OPENCLAW_SHELL=exec; do
    rm -rf "$T/home4"; mkdir -p "$T/home4"
    env -i HOME="$T/home4" PATH=/usr/bin:/bin "$n" /bin/bash "$f" > "$T/out/g" 2> "$T/err/g" < /dev/null
    RC=$?
    [ "$RC" = 1 ] || red G "[$n] exited $RC, expected 1"
    grep -q '^FAIL' "$T/err/g" || red G "[$n] the FAIL line is missing"
    [ -z "$(ls -A "$T/home4")" ] || red G "[$n] \$T/home4 is no longer empty"
  done
  good G "scanner with plants, static over tests/ and a guarded run"
  close_case G
}

# ---- P: isolated python3 -----------------------------------------------------------------------
case_P() {
  local m
  printf 'open(%s, "w").close()\n' "'$T/py-hit'" > "$T/trap/json.py"
  for m in "" OPENCLAW_CLI=1; do
    RUN_CWD="$T/trap" run p "$T/mc/bin/devbrain" ${m:+"$m"} -- plan not-in-the-allowlist "x"
    [ "$RC" = 3 ] || red P "[${m:-no mark}] exited $RC, expected 3"
    [ ! -e "$T/py-hit" ] || red P "[${m:-no mark}] python3 imported the json.py of the current directory"
  done
  # static: covers tg_send_checked, which this case does not run
  [ "$(grep -c 'python3 -c' "$DIR/lib/telegram.sh")" = 0 ] || red P "lib/telegram.sh has a 'python3 -c' without -I"
  [ "$(grep -c 'python3 -I -c' "$DIR/lib/telegram.sh")" = 2 ] || red P "lib/telegram.sh does not have exactly two 'python3 -I -c'"
  good P "python3 -I: the trap's json.py is not imported"
  close_case P
}

# ---- C1 and C1b: end to end, devbrain-queue approve ----------------------------------------------
# Canary executables: they leave $T/hit and exit 1 (nothing is approved, with or without the mark).
case_C1() {
  mkdir -p "$T/canary" "$T/canpy"
  printf '#!/bin/bash\n/usr/bin/touch "%s/hit"\nexit 1\n' "$T" > "$T/canary/exe"; chmod +x "$T/canary/exe"
  printf 'open(%s, "w").close()\n' "'$T/hit'" > "$T/canpy/sitecustomize.py"
  local ex=() n pl="$T/home/dev/queue/10-real-home.plan.md"
  for n in DAY_PREFLIGHT_BIN DEVBRAIN_CLAUDE_BIN DEVBRAIN_GH_BIN TELEGRAM_CURL_BIN DAY_ENGINE; do
    ex+=("$n=$T/canary/exe")
  done
  ex+=("PYTHONPATH=$T/canpy")

  # control: without the mark the canary fires (the case can see)
  fresh_queue; rm -f "$T/hit"
  run c1 "$T/mc/bin/devbrain-queue" "${ex[@]}" -- approve 10
  [ -e "$T/hit" ] && good C1 "control: without the mark the canary fires" \
    || red C1 "control: without the mark the canary did NOT fire; the case cannot see"

  fresh_queue; rm -f "$T/hit"
  run c1 "$T/mc/bin/devbrain-queue" OPENCLAW_CLI=1 "${ex[@]}" -- approve 10
  [ ! -e "$T/hit" ] || red C1 "under the mark a canary executable fired"
  [ "$RC" = 7 ] || red C1 "exit $RC, expected 7"
  grep -q "was NOT approved" "$T/out/c1" || red C1 "the preflight's rejection is missing"
  [ "$(sed -n 's/^status: //p' "$pl")" = requested ] || red C1 "the plan is no longer requested"
  ! grep -q '^aprobado:' "$pl" || red C1 "the plan got aprobado:"
  [ -z "$(g -C "$T/home/dev/queue" status --porcelain)" ] || red C1 "the queue was modified"
  good C1 "approve 10 under the mark: rc=$RC, the real preflight's rejection, plan untouched"
  close_case C1
}
hash_tree() { (cd "$1" && find . -type f | sort | while read -r f; do shasum "$f"; done | shasum); }
case_C1b() {
  local ex=() n
  rm -rf "$T/fake"; mkdir -p "$T/fake"
  printf -- '---\nrepo: scratch-test\nstatus: requested\nprioridad: 10\n---\n\n# Plan fake\n' > "$T/fake/10-fake.plan.md"
  for n in DEVBRAIN_QUEUE_DIR DEVBRAIN_ROOT DEVBRAIN_MC_DIR DEVBRAIN_PROJECTS_DIR DEVBRAIN_WIKI_DIR DEVBRAIN_CONFIG_DIR; do
    ex+=("$n=$T/fake")
  done
  local before; before="$(hash_tree "$T/fake")"
  fresh_queue
  run c1b "$T/mc/bin/devbrain-queue" OPENCLAW_CLI=1 "${ex[@]}" -- approve 10
  [ "$RC" = 7 ] || red C1b "exit $RC, expected 7"
  grep -q "preflight" "$T/out/c1b" || red C1b "the rejection did not come from the real preflight path"
  [ "$(hash_tree "$T/fake")" = "$before" ] || red C1b "\$T/fake changed"
  [ "$(sed -n 's/^status: //p' "$T/fake/10-fake.plan.md")" = requested ] || red C1b "the fake queue's plan changed"
  [ "$(sed -n 's/^status: //p' "$T/home/dev/queue/10-real-home.plan.md")" = requested ] || red C1b "the real queue's plan changed"
  good C1b "caller-chosen paths are ignored; the fake queue stayed the same"
  close_case C1b
}

# ---- C2: the canary table -------------------------------------------------------------------------
case_C2() {
  local fam n k m
  for fam in FAM_SHELL FAM_DEVBRAIN FAM_GIT FAM_RUNTIME; do
    n="$(eval "echo \$$fam" | wc -w | tr -d ' ')"
    [ "$n" -ge 28 ] || red C2 "family $fam has $n names, it needs 28"
  done
  for m in "OPENCLAW_CLI=1" "OPENCLAW_CLI="; do
    for k in $KEYS; do
      invoke "$k" "${CAN[@]}" "$m"
      verify C2 "$k" "$k [$m]" OPENCLAW_CLI
      if [ "$k" = devbrain ] && grep -q GIT_TRACE "$T/err/devbrain"; then red C2 "devbrain [$m]: git saw GIT_TRACE"; fi
    done
  done
  good C2 "the canary run finished (2 binaries, mark 1 and empty)"
  close_case C2
}

# C2b, the control: without the mark the neutral names reach every trace.
case_C2b() {
  local k n
  for k in $KEYS; do
    invoke "$k" "${NEU[@]}"
    [ -f "$T/trace/$k" ] || { red C2b "$k: no trace (rc=$RC)"; continue; }
    for n in $NEUTRAL; do
      grep -q "^$n=zz-$n$" "$T/trace/$k" || red C2b "$k: $n did not arrive without the mark"
    done
  done
  # in `devbrain plan` the git output to a file shows the effect of the trace
  grep -q GIT_TRACE "$T/err/devbrain" || red C2b "devbrain: the git trace left no visible effect (the control cannot see)"
  good C2b "without the mark the neutral names reach both traces"
  close_case C2b
}

# C2c: a name that cannot be dropped is a refusal: exit 2, no trace, two lines.
case_C2c() {
  local k l
  for k in $KEYS; do
    invoke "$k" OPENCLAW_CLI=1 "A(B)=zz"
    [ "$RC" = 2 ] || red C2c "$k: exited $RC, expected 2"
    [ ! -e "$T/trace/$k" ] || red C2c "$k: left a trace or a dump"
    l="$(wc -l < "$T/err/$k" | tr -d ' ')"
    [ "$l" = 2 ] || red C2c "$k: stderr has $l lines, expected exactly 2"
    sed -n 1p "$T/err/$k" | grep -q 'not a valid identifier' || red C2c "$k: line 1 is not bash's own complaint about the unset"
    sed -n 2p "$T/err/$k" | grep -qF 'whitelist: could not drop A(B)' || red C2c "$k: line 2 is not the block's, naming A(B)"
  done
  good C2c "A(B) closes both with 2 and two lines"
  close_case C2c
}

# C2d: the predicate. (OPENCLAW_CLI=1 on its own is the C2 run.)
case_C2d() {
  local k n
  for k in $KEYS; do
    invoke "$k" "${CAN[@]}" OPENCLAW_SHELL=exec
    verify C2d "$k" "$k [OPENCLAW_SHELL=exec]" OPENCLAW_SHELL
    invoke "$k" "${NEU[@]}" OPENCLAW_SHELL=tui-local
    [ -f "$T/trace/$k" ] || { red C2d "$k [tui-local]: no trace (rc=$RC)"; continue; }
    for n in $NEUTRAL; do
      grep -q "^$n=zz-$n$" "$T/trace/$k" || red C2d "$k [OPENCLAW_SHELL=tui-local]: $n was dropped; that value is not the mark"
    done
  done
  good C2d "OPENCLAW_SHELL=exec is enough; tui-local does not count"
  close_case C2d
}

# C2e: inherited functions. /bin/bash <binary> ignores the shebang's -p, so the block is what we see.
PRELUDE_FN="dirname() { /usr/bin/touch '$T/fn-hit'; command dirname \"\$@\"; }
unset() { /usr/bin/touch '$T/fn-hit'; builtin unset \"\$@\"; }
compgen() { /usr/bin/touch '$T/fn-hit'; builtin compgen \"\$@\"; }
export -f dirname unset compgen
exec /bin/bash \"\$0\" \"\$@\""
case_C2e() {
  local k script args
  for k in $KEYS; do
    case "$k" in
      devbrain) script="$T/mc/bin/devbrain"; args="plan scratch-test x"; fresh_scratch ;;
      queue)    script="$T/mc/bin/devbrain-queue"; args="approve 10"; fresh_queue ;;
    esac
    rm -f "$T/trace/$k" "$T/fn-hit"; printf '%s' "$k" > "$T/cur"
    # shellcheck disable=SC2086
    ( cd "$T" && env -i HOME="$T/home" PATH="$SAFEPATH" "${CAN[@]}" OPENCLAW_CLI=1 /bin/bash -c "$PRELUDE_FN" "$script" $args ) \
      > "$T/out/$k" 2> "$T/err/$k" < /dev/null
    RC=$?
    [ ! -e "$T/ABORT" ] || { echo "ABORT: $(cat "$T/ABORT")"; exit 1; }
    [ ! -e "$T/fn-hit" ] || red C2e "$k: an inherited function got to run"
    verify C2e "$k" "$k [as /bin/bash binary]" OPENCLAW_CLI
  done
  good C2e "no inherited function runs, neither under the name unset nor compgen"
  close_case C2e
}

# ---- C7: the privileged shebang ---------------------------------------------------------------------
# BASH_ENV, SHELLOPTS=xtrace with a PS4 that runs something, and an exported function `cd` would run
# before the first line with `#!/bin/bash`. The prelude injects the three from a clean bash.
sed 's|@T@|'"$T"'|g' > "$T/c7-prelude" <<'EOF'
cd() { /usr/bin/touch '@T@/hit-fn'; builtin cd "$@"; }
export -f cd
exec /usr/bin/env 'BASH_ENV=@T@/benv' SHELLOPTS=xtrace 'PS4=$(/usr/bin/touch @T@/hit-ps4)+ ' "$@"
EOF
printf '/usr/bin/touch %s\n' "$T/hit-benv" > "$T/benv"
c7_run() { # <binary> [mark]: with no arguments every binary exits with the usage, after start-up
  local bin="$1"; shift
  rm -f "$T/hit-benv" "$T/hit-ps4" "$T/hit-fn"
  env -i HOME="$T/home" PATH="$SAFEPATH" "$@" /bin/bash "$T/c7-prelude" "$bin" > "$T/out/c7" 2> "$T/err/c7" < /dev/null
}
case_C7() {
  local b m h
  for b in devbrain-queue devbrain; do
    for m in "" OPENCLAW_CLI=1; do
      c7_run "$DIR/bin/$b" ${m:+"$m"}
      for h in benv ps4 fn; do
        [ ! -e "$T/hit-$h" ] || red C7 "$b [${m:-no mark}]: the $h mark ran before the first line"
      done
    done
  done
  # control: the same binaries with a bare `#!/bin/bash` DO leave the three marks (the case can see)
  rm -rf "$T/ctl"; mkdir -p "$T/ctl"; cp -R "$DIR/bin" "$DIR/lib" "$T/ctl/"
  for b in devbrain-queue devbrain; do
    sed -i.bak '1s|.*|#!/bin/bash|' "$T/ctl/bin/$b"
    c7_run "$T/ctl/bin/$b"
    for h in benv ps4 fn; do
      [ -e "$T/hit-$h" ] || red C7 "control $b without -p: the $h mark did not run; the case cannot see"
    done
  done
  good C7 "with -p no mark runs; without -p all three run (control)"
  close_case C7
}

case_S
case_G
case_P
case_C7
case_C1
case_C1b
case_C2
case_C2b
case_C2c
case_C2d
case_C2e

if [ -z "$FAILS" ]; then echo "PASS: env-whitelist"; exit 0; fi
echo "RED:$(printf '%s\n' $FAILS | sort -u | tr '\n' ' ')"
exit 1

#!/bin/bash
# tests/test-models.sh — model and effort per role (lib/models.sh, config/models.conf).
#
# Runs every script that calls the model, end to end, against a fake `claude` that
# records its argv, and compares that argv with tests/fixtures/models-argv.txt, which
# was captured from main BEFORE lib/models.sh existed (with the "opus" alias then
# pinned to its exact ID, the one intended change):
#   1. with no configuration the argv is byte-for-byte the fixture (shipped file too);
#   2. a models.conf alone (no env, as under launchd) and the env alone change only
#      --model/--effort; every other argument stays identical;
#   3. the old DEVBRAIN_PLAN_MODEL / DEVBRAIN_EXEC_MODEL variables keep working;
#   4. a value that could inject a flag is rejected before the binary runs.
#
# `bash tests/test-models.sh --record` rewrites the fixture. Only do that when a call's
# argv changes on purpose, and say so in the PR.
set -uo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURE="$DIR/tests/fixtures/models-argv.txt"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
T="$(cd "$T" && pwd -P)"
die() { echo "FAIL: test-models (line ${BASH_LINENO[0]})"; exit 1; }

# Every role, in the order the scenarios below produce them.
ROLES="plan execute review research interview digest wikilint"
OLD_VARS="DEVBRAIN_PLAN_MODEL DEVBRAIN_PLAN_EFFORT DEVBRAIN_EXEC_MODEL DEVBRAIN_EXEC_EFFORT"

cat > "$T/fake-claude" <<'EOF'
#!/bin/bash
# One line per call, each argument %q-quoted. The digest's prompt carries the day's
# raw data after "Data:"; that tail is not argv shape, so it is cut.
line=""
for a in "$@"; do
  case "$a" in *Data:*) a="${a%%Data:*}Data:<context>" ;; esac
  line+="$(printf '%q' "$a") "
done
printf '%s\n' "$line" >> "$ARGV_LOG"
cat > /dev/null
case "$*" in *acceptEdits*) [ -n "${FAKE_EDIT:-}" ] && echo done > feature.txt ;; esac
if [ -n "${FAKE_OUT:-}" ]; then cat "$FAKE_OUT"; else echo "VERDICT: APPROVE"; fi
EOF
printf '#!/bin/bash\nexit 0\n' > "$T/ok"
printf '#!/bin/bash\nexit 1\n' > "$T/no"
chmod +x "$T/fake-claude" "$T/ok" "$T/no"
FAKE="$T/fake-claude"
q() { git -c user.email=t@t -c user.name=t "$@" >/dev/null 2>&1; }

# setup <W>: fresh fixtures for one full capture (runs change state: backlogs dedupe).
setup() {
  local W="$1"
  mkdir -p "$W/home/dev/wiki" "$W/home/.openclaw/logs" "$W/projects" "$W/queue" "$W/wiki/status" "$W/wiki/projects"
  # devbrain plan/execute. The origin refuses pushes, so execute stops right after the
  # review: `gh pr create` (bare, on PATH) is never reached.
  git init -q --bare -b main "$W/origin.git"
  printf '#!/bin/sh\nexit 1\n' > "$W/origin.git/hooks/pre-receive"; chmod +x "$W/origin.git/hooks/pre-receive"
  git init -q -b main "$W/projects/scratch-test"
  printf '.devbrain/\n' > "$W/projects/scratch-test/.gitignore"; echo base > "$W/projects/scratch-test/a.txt"
  q -C "$W/projects/scratch-test" add -A; q -C "$W/projects/scratch-test" commit -m base
  mv "$W/origin.git/hooks/pre-receive" "$W/pre-receive"
  q -C "$W/projects/scratch-test" remote add origin "$W/origin.git"
  q -C "$W/projects/scratch-test" push origin HEAD:main
  mv "$W/pre-receive" "$W/origin.git/hooks/pre-receive"
  printf 'scratch-test\n' > "$W/allow-db"
  # research
  mkdir -p "$W/projects/demo/src"; printf 'a\nb\nc\n' > "$W/projects/demo/src/real.js"
  git -C "$W/projects/demo" init -q; printf 'demo\n' > "$W/allow"
  printf '# demo — status\n' > "$W/wiki/status/demo.md"
  printf '### Real debt\n- repo: demo\n- evidence: src/real.js:2\n- why: duplicated\n- size: 1 night\n' > "$W/finding"
  printf '### Proposal\n- repo: demo\n- effort: 1 night\n- risks: none\n- verify: tests\n\n#### Option A — a\n- files: src/real.js\n- pros: p\n- cons: c\n' > "$W/promote"
  # digest: one repo with activity, every external tool stubbed
  git init -q "$W/digest-projects/active"; q -C "$W/digest-projects/active" commit --allow-empty -m today
  # wiki-lint: a wiki under the fake HOME
  printf '# SCHEMA\n' > "$W/home/dev/wiki/SCHEMA.md"; printf '# Index\n- [s](SCHEMA.md)\n' > "$W/home/dev/wiki/index.md"
  git -C "$W/home/dev/wiki" init -q; q -C "$W/home/dev/wiki" add -A; q -C "$W/home/dev/wiki" commit -m init
}

# cap <W> <roles> <cmd...>: runs one scenario; it must produce exactly one call per role.
cap() {
  local W="$1" roles="$2" n=0 r; shift 2
  : > "$W/cur"
  ARGV_LOG="$W/cur" "$@" </dev/null >"$W/last.out" 2>&1
  [ "$(wc -l < "$W/cur" | tr -d ' ')" = "$(echo $roles | wc -w | tr -d ' ')" ] \
    || { echo "  scenario '$roles' made $(wc -l < "$W/cur" | tr -d ' ') call(s): $(tail -3 "$W/last.out")" >&2; CAP_OK=0; }
  for r in $roles; do
    n=$((n + 1))
    printf '%s\t%s\n' "$r" "$(sed -n "${n}p" "$W/cur")" >> "$W/all"
  done
}

# capture <name>: every model call in the repo, normalized. Writes $T/<name>.txt.
capture() {
  local W="$T/$1"; CAP_OK=1
  setup "$W"; : > "$W/all"
  local GIT_ID=(GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t)
  local DB=(env "${GIT_ID[@]}" HOME="$W/home" DEVBRAIN_NO_TG=1 DEVBRAIN_PROJECTS_DIR="$W/projects"
            DEVBRAIN_ALLOWFILE="$W/allow-db" DEVBRAIN_CLAUDE_BIN="$FAKE")
  cap "$W" "plan" "${DB[@]}" "$DIR/bin/devbrain" plan scratch-test "add a feature"
  cap "$W" "execute review" "${DB[@]}" FAKE_EDIT=1 "$DIR/bin/devbrain" execute scratch-test
  local RS=(env HOME="$W/home" RESEARCH_CLAUDE_BIN="$FAKE" RESEARCH_PROJECTS_DIR="$W/projects" RESEARCH_ALLOWFILE="$W/allow"
            RESEARCH_BACKLOG="$W/wiki/projects/mejoras-propuestas.md" RESEARCH_WIKI="$W/wiki"
            RESEARCH_LOG="$W/research.log" RESEARCH_STATE_DIR="$W/state" RESEARCH_RAW_DIR="$W")
  cap "$W" "research" "${RS[@]}" FAKE_OUT="$W/finding" "$DIR/bin/devbrain-research" demo
  cap "$W" "research" "${RS[@]}" FAKE_OUT="$W/promote" "$DIR/bin/devbrain-research" --promote demo
  cap "$W" "interview" env HOME="$W/home" DEVBRAIN_QUEUE_DIR="$W/queue" DEVBRAIN_INTERVIEW_CLAUDE_BIN="$FAKE" "$DIR/bin/devbrain-interview"
  cap "$W" "digest" env HOME="$W/home" DEVBRAIN_NO_TG=1 DEVBRAIN_TG_CHAT_ID=1 TELEGRAM_CURL_BIN="$T/no" \
    DEVBRAIN_PROJECTS_DIR="$W/digest-projects" DEVBRAIN_WIKI_DIR="$W/wiki" DEVBRAIN_QUEUE_DIR="$W/queue" \
    DEVBRAIN_DIGEST_LOG="$W/digest.log" DEVBRAIN_DIGEST_GH_BIN="$T/ok" DEVBRAIN_DIGEST_CLAUDE_BIN="$FAKE" \
    DEVBRAIN_DIGEST_OPENCLAW_BIN="$T/ok" DEVBRAIN_DIGEST_GOG_BIN="$T/no" DEVBRAIN_PERSONAL_DIGEST_BIN="$T/ok" \
    DEVBRAIN_REPO_AUDIT_BIN="$T/ok" "$DIR/bin/devbrain-digest"
  cap "$W" "wikilint" env HOME="$W/home" DEVBRAIN_TG_CHAT_ID=1 TELEGRAM_CURL_BIN="$T/no" \
    DEVBRAIN_WIKI_LINT_CLAUDE_BIN="$FAKE" DEVBRAIN_WIKI_LINT_OPENCLAW_BIN="$T/ok" \
    STACKED_PR_GH="$T/no" WIKI_STATUS_AUDIT_GH="$T/no" REPO_AUDIT_GH="$T/no" "$DIR/bin/devbrain-wiki-lint"
  LC_ALL=C sed -e "s#$W#<W>#g" -e "s#$DIR#<ROOT>#g" "$W/all" > "$T/$1.txt"
  [ "$CAP_OK" = 1 ]
}

# A run with nothing configured: no env knobs, models file pointing at nothing.
EMPTY="$T/empty-config"; mkdir -p "$EMPTY"
unset $OLD_VARS
for r in $ROLES; do R="$(echo "$r" | tr a-z A-Z)"; unset "DEVBRAIN_MODEL_$R" "DEVBRAIN_EFFORT_$R"; done

if [ "${1:-}" = "--record" ]; then
  DEVBRAIN_MODELS_FILE="$EMPTY/models.conf" capture record || { echo "FAIL: a scenario did not reach its call"; exit 1; }
  mkdir -p "$(dirname "$FIXTURE")"
  cp "$T/record.txt" "$FIXTURE"; echo "recorded $(wc -l < "$FIXTURE" | tr -d ' ') calls to $FIXTURE"; exit 0
fi
[ -s "$FIXTURE" ] || { echo "FAIL: no fixture $FIXTURE"; exit 1; }
[ "$(LC_ALL=C awk -F'\t' '!seen[$1]++ { printf "%s ", $1 }' "$FIXTURE")" = "$ROLES " ] || die   # every role is covered

# ---- 1. nothing configured: identical to the fixture --------------------------
DEVBRAIN_MODELS_FILE="$EMPTY/models.conf" capture none || die
diff "$FIXTURE" "$T/none.txt" >&2 || die
echo "OK: no file and no variables: all 8 calls (7 roles) match the fixture byte for byte"
capture shipped || die   # the repo's own config/models.conf
diff "$FIXTURE" "$T/shipped.txt" >&2 || die
echo "OK: with the repo's own config/models.conf, identical too"

# expected <model-prefix> <effort>: the fixture with only --model/--effort changed.
# Calls that pass no --model today get both right after -p.
expected() {
  local r rest m
  while IFS=$'\t' read -r r rest; do
    m="$1-$r"
    case " $rest" in
      *" --model "*) rest="$(printf '%s' "$rest" | sed -E "s#--model [^ ]+ (--effort [^ ]+ )?#--model $m --effort $2 #")" ;;
      " -p "*) rest="-p --model $m --effort $2 ${rest#-p }" ;;
      *) echo "no model slot for $r" >&2; return 1 ;;
    esac
    case "$rest" in *"--model $m --effort $2 "*) ;; *) echo "no model slot for $r" >&2; return 1 ;; esac
    printf '%s\t%s\n' "$r" "$rest"
  done < "$FIXTURE"
}

# ---- 2a. file only (as under launchd: no env) ---------------------------------
mkdir -p "$T/cfg"
for r in $ROLES; do printf '%s = file-%s   # comment\n%s.effort=low\n' "$r" "$r" "$r"; done > "$T/cfg/models.conf"
expected file low > "$T/exp-file.txt" || die
DEVBRAIN_MODELS_FILE="$T/cfg/models.conf" capture file || die
diff "$T/exp-file.txt" "$T/file.txt" >&2 || die
echo "OK: models.conf alone (no env) changes each role's --model/--effort and nothing else"

# ---- 2b. env only -------------------------------------------------------------
expected env max > "$T/exp-env.txt" || die
for r in $ROLES; do R="$(echo "$r" | tr a-z A-Z)"; export "DEVBRAIN_MODEL_$R=env-$r" "DEVBRAIN_EFFORT_$R=max"; done
DEVBRAIN_MODELS_FILE="$EMPTY/models.conf" capture env || die
diff "$T/exp-env.txt" "$T/env.txt" >&2 || die
echo "OK: DEVBRAIN_MODEL_<ROLE>/DEVBRAIN_EFFORT_<ROLE> alone change --model/--effort and nothing else"

# ---- 2c. env beats file -------------------------------------------------------
DEVBRAIN_MODELS_FILE="$T/cfg/models.conf" capture both || die
diff "$T/exp-env.txt" "$T/both.txt" >&2 || die
for r in $ROLES; do R="$(echo "$r" | tr a-z A-Z)"; unset "DEVBRAIN_MODEL_$R" "DEVBRAIN_EFFORT_$R"; done
echo "OK: the environment wins over the file"

# The unit-level checks below source lib/models.sh directly: same code, no scripts.
resolve() { ( source "$DIR/lib/models.sh"; models_resolve "$@" && echo ${MODEL_ARGS[@]+"${MODEL_ARGS[@]}"} ) 2>&1; }

# ---- 2d. the reviewer: own role, empty = plan's, as before --------------------
printf 'plan=p-model\nplan.effort=low\n' > "$T/cfg/models.conf"
[ "$(DEVBRAIN_MODELS_FILE="$T/cfg/models.conf" resolve review claude-opus-5-5 high plan)" = "--model p-model --effort low" ] || die
printf 'plan=p-model\nreview=r-model\n' > "$T/cfg/models.conf"
[ "$(DEVBRAIN_MODELS_FILE="$T/cfg/models.conf" resolve review claude-opus-5-5 high plan)" = "--model r-model --effort high" ] || die
[ "$(DEVBRAIN_MODELS_FILE="$EMPTY/models.conf" resolve digest "" "")" = "" ] || die
echo "OK: review with no value uses plan's; with a value, its own; no default means no flags"

# ---- 2e. the old variables: below DEVBRAIN_MODEL_<ROLE>, above the file -------
printf 'plan=file-plan\nplan.effort=low\nexecute=file-exec\n' > "$T/cfg/models.conf"
export DEVBRAIN_MODELS_FILE="$T/cfg/models.conf"
[ "$(DEVBRAIN_PLAN_MODEL=old-plan DEVBRAIN_PLAN_EFFORT=xhigh resolve plan claude-opus-5-5 high)" = "--model old-plan --effort xhigh" ] || die
[ "$(DEVBRAIN_PLAN_MODEL=old-plan resolve review claude-opus-5-5 high plan)" = "--model old-plan --effort low" ] || die
[ "$(DEVBRAIN_EXEC_MODEL=old-exec DEVBRAIN_EXEC_EFFORT=low resolve execute claude-sonnet-5-5 medium)" = "--model old-exec --effort low" ] || die
[ "$(DEVBRAIN_MODEL_PLAN=new-plan DEVBRAIN_PLAN_MODEL=old-plan resolve plan claude-opus-5-5 high)" = "--model new-plan --effort low" ] || die
[ "$(DEVBRAIN_PLAN_MODEL=-x resolve plan claude-opus-5-5 high)" != "--model -x --effort low" ] || die
unset DEVBRAIN_MODELS_FILE
# End to end through bin/devbrain: the old variables move plan and review, not execute.
DEVBRAIN_PLAN_MODEL=old-plan DEVBRAIN_EXEC_EFFORT=low DEVBRAIN_MODELS_FILE="$EMPTY/models.conf" capture old || die
LC_ALL=C sed -E -e '/^(plan|review)\t/s/--model claude-opus-5-5 /--model old-plan /' \
  -e '/^execute\t/s/--effort medium /--effort low /' "$FIXTURE" > "$T/exp-old.txt"
diff "$T/exp-old.txt" "$T/old.txt" >&2 || die
echo "OK: DEVBRAIN_PLAN_MODEL/DEVBRAIN_EXEC_MODEL (+ _EFFORT) still work, also for the reviewer, and are validated"

# ---- 3. validation: rejected before the binary runs ---------------------------
bad_case() { # <label> <expect-in-stderr> <env...>  — devbrain plan must not call claude
  local W="$T/bad"; rm -rf "$W"; setup "$W"; : > "$W/cur"
  env "${@:3}" ARGV_LOG="$W/cur" HOME="$W/home" DEVBRAIN_NO_TG=1 DEVBRAIN_PROJECTS_DIR="$W/projects" \
    DEVBRAIN_ALLOWFILE="$W/allow-db" DEVBRAIN_CLAUDE_BIN="$FAKE" "$DIR/bin/devbrain" plan scratch-test x </dev/null >"$W/out" 2>&1
  local rc=$?
  [ "$rc" -ne 0 ] || { echo "  $1: exit 0" >&2; return 1; }
  [ ! -s "$W/cur" ] || { echo "  $1: claude ran: $(cat "$W/cur")" >&2; return 1; }
  grep -q -- "$2" "$W/out" || { echo "  $1: no clear error: $(cat "$W/out")" >&2; return 1; }
}
bad_case "flag via env" "invalid model for role plan" DEVBRAIN_MODELS_FILE="$EMPTY/models.conf" DEVBRAIN_MODEL_PLAN=--dangerously-skip-permissions || die
bad_case "spaces via env" "invalid model for role plan" DEVBRAIN_MODELS_FILE="$EMPTY/models.conf" "DEVBRAIN_MODEL_PLAN=claude-opus-5-5 --dangerously-skip-permissions" || die
bad_case "flag via old variable" "invalid model for role plan" DEVBRAIN_MODELS_FILE="$EMPTY/models.conf" DEVBRAIN_PLAN_MODEL=--dangerously-skip-permissions || die
bad_case "made-up effort" "invalid effort for role plan" DEVBRAIN_MODELS_FILE="$EMPTY/models.conf" DEVBRAIN_EFFORT_PLAN=turbo || die
printf 'plan=claude-opus-5-5 --permission-mode bypassPermissions\n' > "$T/cfg/models.conf"
bad_case "spaces via file" "invalid model for role plan" DEVBRAIN_MODELS_FILE="$T/cfg/models.conf" || die
printf 'plan.effort=--dangerously-skip-permissions\n' > "$T/cfg/models.conf"
bad_case "flag in effort via file" "invalid effort for role plan" DEVBRAIN_MODELS_FILE="$T/cfg/models.conf" || die
echo "OK: a flag, spaces, or an effort outside low|medium|high|xhigh|max is rejected and claude does not run"

# Every role validates, not only plan: a bad value for role R means no call for R.
BAD=""
for r in $ROLES; do
  R="$(echo "$r" | tr a-z A-Z)"
  DEVBRAIN_MODELS_FILE="$EMPTY/models.conf" env "DEVBRAIN_MODEL_$R=-x" bash -c "source '$DIR/lib/models.sh'; models_resolve $r m e" >/dev/null 2>&1 \
    && BAD="$BAD $r"
done
[ -z "$BAD" ] || { echo "accepted -x for:$BAD" >&2; die; }
export DEVBRAIN_MODEL_RESEARCH=-x DEVBRAIN_MODEL_INTERVIEW=-x DEVBRAIN_MODEL_DIGEST=-x DEVBRAIN_MODEL_WIKILINT=-x
DEVBRAIN_MODELS_FILE="$EMPTY/models.conf" capture rejected >/dev/null 2>&1
for r in research interview digest wikilint; do
  [ -z "$(awk -F'\t' -v r="$r" '$1==r && $2!=""' "$T/rejected.txt")" ] || { echo "  $r called claude with a rejected value" >&2; die; }
done
unset DEVBRAIN_MODEL_RESEARCH DEVBRAIN_MODEL_INTERVIEW DEVBRAIN_MODEL_DIGEST DEVBRAIN_MODEL_WIKILINT
echo "OK: the other scripts (not only devbrain) never call claude with a rejected value"

echo "PASS: models"

#!/bin/bash
# tests/test-block-config-secrets-dump.sh — hook block-config-secrets-dump.sh
# and bin/devbrain-conf-get.
#
# The failure under test: a session prints a "filtered" section of
# ~/.openclaw/openclaw.json and the API keys in it land in the chat. Both
# directions are planted (blocks AND allows), and the canaries prove each block
# test can fail: with the pattern lists emptied the block_* tests must go red
# and nothing else; with `key` removed from the helper's deny list ONLY
# helper_refuses_apiKey must go red. Paths are simulated strings: the hook
# judges text and never opens the files; the helper runs on fakes in $TMP.
[ -z "${OPENCLAW_CLI+x}" ] && [ "${OPENCLAW_SHELL-}" != exec ] || { echo "FAIL: these tests do not run under OpenClaw" >&2; exit 1; }
set -uo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$DIR/claude/hooks/block-config-secrets-dump.sh"
HELPER="$DIR/bin/devbrain-conf-get"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
FAKEHOME="$TMP/home"; mkdir -p "$FAKEHOME/.claude/hooks"
cat > "$TMP/fake.json" <<'J'
{"agents":{"defaults":{"model":{"primary":"provider/model-x"}}},
 "models":{"providers":{"acme":{"apiKey":"FAKE-NOT-REAL"}}}}
J
printf 'agents:\n  defaults:\n    model:\n      primary: yaml-model\n' > "$TMP/fake.yaml"
echo "hello" > "$TMP/some-repo-file.txt"

OC='/home/x/.openclaw/openclaw.json'
json_bash() { COMMAND="$1" python3 -c 'import json,os;print(json.dumps({"tool_name":"Bash","tool_input":{"command":os.environ["COMMAND"]}}))'; }
json_read() { FP="$1" python3 -c 'import json,os;print(json.dumps({"tool_name":"Read","tool_input":{"file_path":os.environ["FP"]}}))'; }
FAILED=""

# check <name> <expected rc> <hook|helper script> <json>   (hook cases)
hk() { local got; got=$(printf '%s' "$3" | HOME="$FAKEHOME" bash "$HOOKUT" >/dev/null 2>&1; echo $?)
  [ "$got" = "$2" ] || FAILED="$FAILED $1"; }
# he <name> <expected rc> <expected stdout|-> <file> <key>
he() { local out got; out=$(bash "$HELPERUT" "$4" "$5" 2>/dev/null); got=$?
  [ "$got" = "$2" ] && { [ "$3" = "-" ] || [ "$out" = "$3" ]; } || FAILED="$FAILED $1"; }

suite() {  # HOOKUT HELPERUT
  HOOKUT="$1"; HELPERUT="$2"; FAILED=""
  hk block_cat 2 "$(json_bash "cat $OC")"
  hk block_cat_bak 2 "$(json_bash "cat $OC.bak.1")"
  hk block_python_json_load_print 2 "$(json_bash "python3 -c \"import json;print(json.load(open('$OC'))['models'])\"")"
  hk block_jq_local_env 2 "$(json_bash "jq . /home/x/dev/devbrain/devbrain.local.env")"
  hk block_read_tool_openclaw 2 "$(json_read "$OC")"
  hk block_read_tool_local_env 2 "$(json_read /home/x/dev/devbrain/devbrain.local.env)"
  hk block_read_tool_env 2 "$(json_read /home/x/dev/app/.env.local)"
  hk block_supabase_secrets_list 2 "$(json_bash "supabase secrets list --project-ref abc")"
  hk block_gh_auth_token 2 "$(json_bash "gh auth token")"
  hk block_vercel_env_pull 2 "$(json_bash "vercel env pull .env.local")"
  hk block_grep_content 2 "$(json_bash "grep apiKey $OC")"
  hk block_piped_head 2 "$(json_bash "echo hi && head -50 /home/x/dev/devbrain/devbrain.local.env")"
  hk block_cp_out 2 "$(json_bash "cp $OC /tmp/readable.json")"
  hk block_relative_after_cd 2 "$(json_bash "cd ~/.openclaw && cat openclaw.json")"
  hk block_project_env 2 "$(json_bash "cat apps/web/.env.production")"
  hk block_grep_recursive_dir 2 "$(json_bash "grep -rn apiKey ~/.openclaw/")"
  hk block_git_c_no_index 2 "$(json_bash "git -c core.pager=cat diff --no-index /dev/null /home/x/.openclaw/openclaw.json")"
  hk block_git_C_show 2 "$(json_bash "git -C /home/x/.openclaw show HEAD:openclaw.json")"
  hk block_sed_w_command 2 "$(json_bash "sed -i '' -e 'w /dev/stdout' apps/web/.env")"
  hk block_sed_s_w_flag 2 "$(json_bash "sed -i 's/a/b/w /dev/stdout' apps/web/.env")"
  hk block_mv_out 2 "$(json_bash "mv openclaw.json /tmp/x; cat /tmp/x")"
  hk failclosed_malformed_input 2 "this is not json"
  hk failclosed_not_an_object 2 "[1, 2]"
  hk allow_mv_into 0 "$(json_bash "mv /tmp/new.env /home/x/dev/app/.env")"
  hk allow_sed_i_plain 0 "$(json_bash "sed -i '' 's/a/b/' apps/web/.env")"
  hk allow_sed_i_word_with_w 0 "$(json_bash "sed -i '' 's/word/new/' apps/web/.env")"
  hk allow_git_C_status 0 "$(json_bash "git -C /home/x/.openclaw status")"
  hk allow_ls 0 "$(json_bash "ls -la ~/.openclaw")"
  hk allow_wc 0 "$(json_bash "wc -l ~/dev/devbrain/devbrain.local.env")"
  hk allow_grep_count 0 "$(json_bash "grep -c apiKey $OC")"
  hk allow_grep_quiet 0 "$(json_bash "grep -q apiKey $OC && echo yes")"
  hk allow_test_stat 0 "$(json_bash "test -f $OC && stat -f %z $OC")"
  hk allow_cat_repo_file 0 "$(json_bash "cat $DIR/README.md")"
  hk allow_cat_env_example 0 "$(json_bash "cat apps/web/.env.example")"
  hk allow_git_status 0 "$(json_bash "git status")"
  hk allow_helper_call 0 "$(json_bash "devbrain-conf-get $OC agents.defaults.model.primary")"
  hk allow_read_repo_file 0 "$(json_read "$DIR/README.md")"
  hk allow_write_into_env 0 "$(json_bash "cp /tmp/new.env /home/x/dev/app/.env")"
  he helper_prints_model 0 provider/model-x "$TMP/fake.json" agents.defaults.model.primary
  he helper_prints_yaml 0 yaml-model "$TMP/fake.yaml" agents.defaults.model.primary
  he helper_refuses_apiKey 2 - "$TMP/fake.json" models.providers.acme.apiKey
  he helper_refuses_object 2 - "$TMP/fake.json" agents.defaults.model
}
names() { echo "$FAILED" | tr ' ' '\n' | grep . | sort | tr '\n' ' '; }

echo "== real hook + helper =="
suite "$HOOK" "$HELPER"
[ -z "$FAILED" ] && echo "OK: all cases pass" || { echo "FAIL:$FAILED"; exit 1; }

echo "== canary 1: both pattern lists emptied -> only block_* may fail =="
export DEVBRAIN_SECRET_PATH_RE= DEVBRAIN_SECRET_CMD_RE=
suite "$HOOK" "$HELPER"; unset DEVBRAIN_SECRET_PATH_RE DEVBRAIN_SECRET_CMD_RE
echo "red: $(names)"
case " $FAILED " in *" block_cat "*) ;; *) echo "FAIL: canary: block_cat did not go red"; exit 1;; esac
echo "$FAILED" | tr ' ' '\n' | grep . | grep -v '^block_' && { echo "FAIL: canary: a non-block test went red"; exit 1; }
[ "$(echo "$FAILED" | wc -w)" -eq 21 ] || { echo "FAIL: canary: expected all 21 block_* red, got $(echo "$FAILED" | wc -w)"; exit 1; }
echo "OK: canary 1 (hook disabled -> all 21 block_* red, no allow_*/helper_*/failclosed_* red)"

echo "== canary 2: 'key' removed from helper deny list -> only helper_refuses_apiKey red =="
sed 's/DENY = r"key|/DENY = r"/' "$HELPER" > "$TMP/helper-mutant"
cmp -s "$HELPER" "$TMP/helper-mutant" && { echo "FAIL: canary: mutation did not change the helper"; exit 1; }
suite "$HOOK" "$TMP/helper-mutant"
echo "red: $(names)"
[ "$(names)" = "helper_refuses_apiKey " ] || { echo "FAIL: canary 2: expected exactly helper_refuses_apiKey"; exit 1; }
echo "OK: canary 2 (exactly helper_refuses_apiKey went red)"

echo "== canary 3: the fail-open mutant of the hook is allowed, a broken python is blocked =="
# the fail-open form: the python call's failure is swallowed and an empty reason means "allowed"
sed 's/^) || reason="could not be evaluated (the hook itself failed)"$/) || reason=""/' "$HOOK" > "$TMP/hook-open"
cmp -s "$HOOK" "$TMP/hook-open" && { echo "FAIL: canary 3: mutation did not change the hook"; exit 1; }
suite "$TMP/hook-open" "$HELPER"
echo "red: $(names)"
[ "$(names)" = "" ] || { echo "FAIL: canary 3 (the parse branch still catches bad input; nothing else may change): $(names)"; exit 1; }
# a hook whose python cannot start: blocked, not allowed
sed 's|^reason=$(HOOK_INPUT="$input" python3 - |reason=$(HOOK_INPUT="$input" /usr/bin/false - |' "$HOOK" > "$TMP/hook-nopy"
cmp -s "$HOOK" "$TMP/hook-nopy" && { echo "FAIL: canary 3: python mutation did not change the hook"; exit 1; }
out=$(printf '%s' "$(json_bash "ls")" | HOME="$FAKEHOME" bash "$TMP/hook-nopy" >/dev/null 2>&1; echo $?)
[ "$out" = 2 ] || { echo "FAIL: a hook whose python fails must block (got rc=$out)"; exit 1; }
sed 's/^) || reason="could not be evaluated (the hook itself failed)"$/) || reason=""/' "$TMP/hook-nopy" > "$TMP/hook-nopy-open"
out=$(printf '%s' "$(json_bash "ls")" | HOME="$FAKEHOME" bash "$TMP/hook-nopy-open" >/dev/null 2>&1; echo $?)
[ "$out" = 0 ] || { echo "FAIL: canary 3: the fail-open mutant should allow (got rc=$out), so the check cannot see"; exit 1; }
echo "OK: canary 3 (a broken python blocks; the fail-open mutant would have allowed)"

echo "== deny list: every pattern word refused, any case/segment =="
for w in key token secret password pass credential auth bearer cookie private dsn; do
  W=$(echo "$w" | tr a-z A-Z)
  printf '{"x":{"My%s":"v"}}' "$W" > "$TMP/w.json"
  bash "$HELPER" "$TMP/w.json" "x.My$W" >/dev/null 2>&1; [ $? = 2 ] || { echo "FAIL: helper printed segment with $w"; exit 1; }
done
echo "OK: all 11 words refused"
echo "ALL OK"

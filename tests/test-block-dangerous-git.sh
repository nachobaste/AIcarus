#!/bin/bash
# tests/test-block-dangerous-git.sh -- claude/hooks/block-dangerous-git.sh.
#
# The hook is a PreToolUse guard on Bash: it must BLOCK (exit 2) the dangerous
# forms of git and let everything else through (exit 0). Both directions are
# planted: a hook that blocks everything fails the "pass" cases, a hook that
# blocks nothing fails the "block" cases. A mutation run copies the
# hook, breaks one rule, and points HOOK_UNDER_TEST at the copy.
#
# Hermetic: temp repos, fabricated PreToolUse JSON, no network, no real Claude.
# HOME points at a temp dir so the block log of the real machine stays clean,
# and global/system git config is disabled so the fixtures behave the same here
# and on any other machine.
[ -z "${OPENCLAW_CLI+x}" ] && [ "${OPENCLAW_SHELL-}" != exec ] || { echo "FAIL: these tests do not run under OpenClaw" >&2; exit 1; }
set -uo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="${HOOK_UNDER_TEST:-$DIR/claude/hooks/block-dangerous-git.sh}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
FAKEHOME="$TMP/home"; mkdir -p "$FAKEHOME/.claude/hooks"
LOG="$FAKEHOME/.claude/hooks/blocked-actions.log"

# ---- fixtures ---------------------------------------------------------------
mkrepo() {  # dir branch [origin-url]
  mkdir -p "$1"
  git -C "$1" init -q -b "$2"
  git -C "$1" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  [ -n "${3:-}" ] && git -C "$1" remote add origin "$3"
  return 0
}
PLAIN="$TMP/plain-repo";        mkrepo "$PLAIN" feat/x git@github.com:x/plain-repo.git
git -C "$PLAIN" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
ONMAIN="$TMP/on-main";          mkrepo "$ONMAIN" main git@github.com:x/on-main.git
TRUNK="$TMP/trunk-repo";        mkrepo "$TRUNK" work git@github.com:x/trunk-repo.git
git -C "$TRUNK" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/trunk
GEO="$TMP/app-repo";           mkrepo "$GEO" work
APPWT="$TMP/wt-app-1";          mkrepo "$APPWT" work git@github.com:x/app-repo.git
NOGIT="$TMP/not-a-repo";        mkdir -p "$NOGIT"
OVR="$TMP/override"
printf '# comment\n\napp-repo=develop\n' > "$OVR"

# ---- harness ----------------------------------------------------------------
mk_json() { COMMAND="$1" CWD="$2" python3 -c 'import json,os;print(json.dumps({"tool_name":"Bash","tool_input":{"command":os.environ["COMMAND"]},"cwd":os.environ["CWD"]}))'; }
FAILED=""; N=0
run_json() { printf '%s' "$1" | HOME="$FAKEHOME" DEVBRAIN_BASE_OVERRIDE="$OVR" bash "$HOOK" 2>"$TMP/stderr" >/dev/null; echo $?; }
# chk <name> <expected rc> <command> [cwd]
chk() {
  local rc; rc=$(run_json "$(mk_json "$3" "${4:-$PLAIN}")")
  N=$((N+1))
  [ "$rc" = "$2" ] || { FAILED="$FAILED $1"; echo "FAIL $1: expected exit $2, got $rc  [$3]"; }
}
ok()  { chk "$1" 0 "$2" "${3:-}"; }
blk() { chk "$1" 2 "$2" "${3:-}"; }

# ---- basics -----------------------------------------------------------------
ok  commit_plain               'git commit -m "x"'
blk commit_no_verify           'git commit --no-verify -m "x"'
blk commit_nm                  'git commit -nm "x"'
ok  push_feature               'git push -u origin devbrain/abc'
blk push_force                 'git push --force'
blk push_f_origin_x            'git push -f origin x'
blk push_plus_refspec          'git push origin +x'
blk push_origin_main           'git push origin main'
blk push_develop_in_override_repo    'git push origin develop' "$GEO"
ok  push_develop_elsewhere     'git push origin develop' "$PLAIN"
blk reset_hard_head            'git reset --hard HEAD~1'
blk clean_fdx                  'git clean -fdx'
blk branch_D                   'git branch -D x'
ok  reset_head_file            'git reset HEAD file'
ok  commit_msg_mentions_flag   'git commit -m "doc: do not use --no-verify"'
ok  non_git_ls                 'ls -la'

# ---- --no-verify / -n -------------------------------------------------------
blk commit_n                   'git commit -n -m x'
blk commit_an                  'git commit -an -m x'
blk commit_abbrev_no_verify    'git commit --no-veri -m x'
blk push_no_verify             'git push --no-verify origin feat'
blk commit_hookspath_override  'git -c core.hooksPath=/dev/null commit -m x'
blk chained_commit_then_nv_push 'git commit -m "ok" && git push --no-verify'
ok  commit_msg_dash_n          'git commit -m "-n"'
ok  commit_msg_eq_no_verify    'git commit --message="--no-verify"'
ok  commit_message_long_flag   'git commit --message "--no-verify"'
ok  commit_am                  'git commit -am "x"'
ok  commit_amend_no_edit       'git commit --amend --no-edit'
ok  log_n                      'git log --oneline -n 5'
ok  push_dry_run_n             'git push -n origin feat'

# ---- force pushes -----------------------------------------------------------
blk push_force_with_lease      'git push --force-with-lease origin feat'
blk push_force_with_lease_eq   'git push --force-with-lease=feat:abc origin feat'
blk push_uf_cluster            'git push -uf origin feat'
blk push_force_abbrev          'git push --forc origin feat'
blk push_mirror                'git push --mirror'
blk push_all                   'git push --all'
ok  push_no_force_with_lease   'git push --no-force-with-lease origin feat'
ok  push_tags                  'git push --tags'
ok  push_tag_name              'git push origin v1.0'
ok  push_feature_to_feature    'git push origin feat/x:feat/x'

# ---- push to protected branches --------------------------------------------
blk push_origin_master         'git push origin master'
blk push_head_main             'git push origin HEAD:main'
blk push_refspec_refs_heads    'git push origin feat:refs/heads/main'
blk push_delete_main_colon     'git push origin :main'
blk push_delete_flag_main      'git push --delete origin main'
blk push_glob_refspec          'git push origin "refs/heads/*:refs/heads/*"'
blk push_main_from_nogit       'git push origin main' "$NOGIT"
ok  push_maintenance_branch    'git push origin maintenance'
ok  push_slash_main_branch     'git push origin feature/main'
blk push_implicit_on_main      'git push' "$ONMAIN"
blk push_origin_implicit_main  'git push origin' "$ONMAIN"
blk push_head_on_main          'git push -u origin HEAD' "$ONMAIN"
ok  push_implicit_on_feature   'git push' "$PLAIN"
ok  push_head_on_feature       'git push -u origin HEAD' "$PLAIN"
blk push_default_branch_trunk  'git push origin trunk' "$TRUNK"
ok  push_trunk_in_plain        'git push origin trunk' "$PLAIN"
blk push_develop_head_refspec  'git push origin HEAD:develop' "$GEO"
blk push_develop_worktree_url  'git push origin develop' "$APPWT"
blk cd_then_push_develop       "cd $GEO && git push origin develop" "$PLAIN"
blk dash_C_push_develop        "git -C $GEO push origin develop" "$PLAIN"

# ---- destructive local commands --------------------------------------------
blk reset_hard_abbrev          'git reset --har HEAD'
blk reset_hard_after_ref       'git reset HEAD~1 --hard'
ok  reset_soft                 'git reset --soft HEAD~1'
blk clean_f                    'git clean -f'
blk clean_force_long           'git clean --force -d'
blk clean_xdf                  'git clean -xdf'
ok  clean_dry_n                'git clean -n'
ok  clean_dry_fdn              'git clean -fdn'
ok  clean_dry_long             'git clean --dry-run -d'
blk checkout_dd_dot            'git checkout -- .'
blk checkout_dot               'git checkout .'
ok  checkout_dd_file           'git checkout -- file'
ok  checkout_branch            'git checkout -b newbranch'
ok  checkout_main              'git checkout main'
blk restore_dot                'git restore .'
ok  restore_staged_dot         'git restore --staged .'
blk branch_force_delete_long   'git branch --delete --force x'
blk branch_d_f                 'git branch -d -f x'
blk branch_fD                  'git branch -fD x'
ok  branch_d_lower             'git branch -d x'
ok  branch_list                'git branch --list'
blk update_ref_d               'git update-ref -d refs/heads/x'
blk update_ref_delete          'git update-ref --delete refs/heads/x'
ok  update_ref_set             'git update-ref refs/heads/x HEAD'

# ---- prefixes, chains and wrappers -----------------------------------------
blk dash_C_force               "git -C $PLAIN push --force"
blk dash_c_kv_force            'git -c k=v push -f'
blk cd_and_force               'cd /tmp && git push --force'
blk semicolon_reset_hard       'echo a; git reset --hard'
blk pipe_into_git              'echo x | git push -f origin x'
blk or_chain                   'echo ok || git reset --hard'
blk newline_chain              $'echo a\ngit reset --hard'
blk subshell                   '(git push -f)'
blk command_substitution       'echo $(git push -f)'
blk backticks                  'echo `git reset --hard`'
blk env_assignment_prefix      'FOO=1 git push -f'
blk absolute_git_path          '/usr/bin/git push -f'
blk uppercase_git              'GIT push -f'
blk command_wrapper            'command git push -f'
blk env_wrapper                'env X=1 git push -f'
blk if_then                    'if true; then git push -f; fi'
blk brace_group                '{ git reset --hard; }'
blk bash_dash_c                'bash -c "git push -f"'
blk sh_dash_lc                 "sh -lc 'git reset --hard'"
blk eval_string                'eval "git push -f"'
blk backslash_newline_chain    $'echo a && \\\ngit push -f'
ok  chain_benign               'git status && git diff | head -5'
ok  chain_push_then_echo_main  'git push origin feat && echo main'
ok  comment_mentions_main      'git push origin feat # not main'
ok  redirect_stderr            'git push origin feat 2>&1'
blk redirect_then_main         'git push origin main 2>&1'

# ---- text is not a git invocation ------------------------------------------
ok  echo_quoted_force          'echo "git push --force"'
ok  echo_single_quoted_reset   "echo 'git reset --hard'"
ok  grep_for_force             'grep -n "git push -f" notes.md'
ok  heredoc_msg_in_dollar_paren $'git commit -m "$(cat <<\'EOF\'\nfix: stop using git push --force and --no-verify\nEOF\n)"'
ok  heredoc_body_is_data       $'git commit -F - <<\'EOF\'\ngit push --force\ngit reset --hard\nEOF'
ok  multiline_quoted_msg       $'git commit -m "first line\ngit push --force\nlast"'
blk heredoc_then_real_force    $'cat <<EOF\nhi\nEOF\ngit push -f'

# ---- spellings git accepts for the same refspec -----------------------------
# Each of these moves `main` for real on a scratch remote.
blk push_at_on_main            'git push origin @' "$ONMAIN"
ok  push_at_on_feature         'git push origin @' "$PLAIN"
blk push_heads_main            'git push origin heads/main'
blk push_feat_to_heads_main    'git push origin feat:heads/main'
ok  push_heads_feature         'git push origin heads/feat'
blk push_matching_colon        'git push origin :' "$PLAIN"

# ---- restore -S takes no value ----------------------------------------------
blk restore_SW_dot             'git restore -SW .'
blk restore_S_W_dot            'git restore -S -W .'
blk restore_staged_worktree    'git restore --staged --worktree .'
blk restore_source_dot         'git restore -s HEAD~1 .'
ok  restore_S_dot              'git restore -S .'
ok  restore_S_file             'git restore -S file'
blk restore_dot_slash          'git restore ./'
blk checkout_dot_slash         'git checkout ./'
ok  checkout_dot_file          'git checkout ./file'

# ---- "$(...)" inside double quotes ------------------------------------------
# An odd number of " inside the heredoc body used to end the string early and
# turn `git reset --hard` in the prose into a command.
ok  pr_body_odd_quote          $'gh pr create --body "$(cat <<\'EOF\'\nScreen is 27" wide\nsee `git reset --hard` docs\nEOF\n)"'
ok  commit_body_odd_quote      $'git commit -m "$(cat <<\'EOF\'\nit\'s a 5" fix:\ngit push -f is blocked\nEOF\n)"'
blk real_force_after_odd_quote $'gh pr create --body "$(cat <<\'EOF\'\nodd " quote\nEOF\n)" && git push -f'
blk dq_substitution_force      'echo "$(git push -f)"'
ok  dq_substitution_benign     'git commit -m "$(date)"'

# ---- wrappers with option arguments -----------------------------------------
blk nice_n_force               'nice -n 5 git push -f'
blk env_u_force                'env -u X git push -f'
blk sudo_u_reset               'sudo -u root git reset --hard'
blk timeout_force              'timeout 5 git push -f'
blk arch_force                 'arch -arm64 git push -f'
ok  nice_n_make                'nice -n 5 make'
ok  timeout_echo_text          'timeout 5 echo git push -f'

# ---- quoting the word "git" does not hide it --------------------------------
blk quote_split_git            "g''it push -f"
blk dq_split_git               'g"i"t push --force'
blk backslash_git              'G\it reset --hard'

# ---- the block log is not a place to inject or leak -------------------------
: > "$LOG"
run_json "$(mk_json $'git push origin \'x*\nFORGED\tline\e[31m\'' "$PLAIN")" >/dev/null
N=$((N+1))
{ [ "$(wc -l < "$LOG" | tr -d ' ')" = 1 ] && [ "$(tr -cd '\t' < "$LOG" | wc -c | tr -d ' ')" = 2 ] && ! grep -q $'\e' "$LOG"; } \
  || { FAILED="$FAILED log_control_chars"; echo "FAIL log_control_chars: $(cat -v "$LOG")"; }
# same, with the control characters in the command text (the second log field)
: > "$LOG"
run_json "$(mk_json $'git push -f origin $\'a\tb\e[31m\'' "$PLAIN")" >/dev/null
N=$((N+1))
{ [ "$(wc -l < "$LOG" | tr -d ' ')" = 1 ] && [ "$(tr -cd '\t' < "$LOG" | wc -c | tr -d ' ')" = 2 ] && ! grep -q $'\e' "$LOG"; } \
  || { FAILED="$FAILED log_control_chars_cmd"; echo "FAIL log_control_chars_cmd: $(cat -v "$LOG")"; }
: > "$LOG"
run_json "$(mk_json 'git push https://x-access-token:FAKE_TOKEN_123@github.com/o/r.git main' "$PLAIN")" >/dev/null
run_json "$(mk_json 'GH_TOKEN=FAKEVAL456 git push -f' "$PLAIN")" >/dev/null
N=$((N+1))
{ [ "$(wc -l < "$LOG" | tr -d ' ')" = 2 ] && ! grep -q 'FAKE_TOKEN_123\|FAKEVAL456' "$LOG"; } \
  || { FAILED="$FAILED log_secrets"; echo "FAIL log_secrets: $(cat "$LOG")"; }

# ---- git lookups have an overall time budget --------------------------------
# Budget 0 means every lookup is skipped, so `git push` on main (which needs the
# current branch) is let through; without the cap it is blocked (push_implicit_on_main).
N=$((N+1))
rc=$(printf '%s' "$(mk_json 'git push' "$ONMAIN")" | HOME="$FAKEHOME" DEVBRAIN_BASE_OVERRIDE="$OVR" DEVBRAIN_HOOK_BUDGET=0 bash "$HOOK" 2>/dev/null >/dev/null; echo $?)
[ "$rc" = 0 ] || { FAILED="$FAILED lookup_budget"; echo "FAIL lookup_budget: expected exit 0 with budget 0, got $rc"; }

# ---- non-Bash tools and bad input ------------------------------------------
N=$((N+1))
rc=$(run_json '{"tool_name":"Write","tool_input":{"content":"git push -f","file_path":"/tmp/x"}}')
[ "$rc" = 0 ] || { FAILED="$FAILED non_bash_tool"; echo "FAIL non_bash_tool: expected exit 0, got $rc"; }

# Internal parse error: fail OPEN, say so on stderr and in the block log.
: > "$LOG"
N=$((N+1))
rc=$(run_json 'this is git but not json')
[ "$rc" = 0 ] || { FAILED="$FAILED garbage_input_fails_open"; echo "FAIL garbage_input_fails_open: exit $rc"; }
N=$((N+1))
[ -s "$TMP/stderr" ] || { FAILED="$FAILED garbage_input_stderr"; echo "FAIL garbage_input_stderr: nothing on stderr"; }
N=$((N+1))
grep -q 'block-dangerous-git.*ERROR' "$LOG" || { FAILED="$FAILED garbage_input_logged"; echo "FAIL garbage_input_logged: no ERROR line in the block log"; }

# ---- block output: one-line reason on stderr, one log line per block --------
: > "$LOG"
rc=$(run_json "$(mk_json 'git push --force origin x' "$PLAIN")")
N=$((N+1))
[ "$rc" = 2 ] && [ "$(wc -l < "$TMP/stderr" | tr -d ' ')" = 1 ] \
  || { FAILED="$FAILED reason_one_line_stderr"; echo "FAIL reason_one_line_stderr: rc=$rc lines=$(wc -l < "$TMP/stderr")"; }
N=$((N+1))
[ "$(wc -l < "$LOG" | tr -d ' ')" = 1 ] && grep -q 'block-dangerous-git.sh' "$LOG" && grep -q 'git push --force origin x' "$LOG" \
  || { FAILED="$FAILED block_log_line"; echo "FAIL block_log_line: $(cat "$LOG")"; }

# ---- non-git commands return before python starts ---------------------------
# Static: the cheap prefilter line must come before the first python3 invocation (a non-git command never pays for it).
N=$((N+1))
pf=$(grep -n 'case "\$bare" in' "$HOOK" | head -1 | cut -d: -f1)
py=$(grep -n 'python3' "$HOOK" | grep -v '^[0-9]*:[[:space:]]*#' | head -1 | cut -d: -f1)
{ [ -n "$pf" ] && [ -n "$py" ] && [ "$pf" -lt "$py" ]; } \
  || { FAILED="$FAILED prefilter_before_python"; echo "FAIL prefilter_before_python: prefilter line=$pf python line=$py"; }

if [ -n "$FAILED" ]; then
  echo "FAILED ($N cases):$FAILED"
  exit 1
fi
echo "PASS: block-dangerous-git ($N cases)"

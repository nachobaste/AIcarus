# claude/hooks

Versioned copies of Claude Code hooks. Install by copying a hook to `~/.claude/hooks/`
and registering it in `~/.claude/settings.json`.

## block-config-secrets-dump.sh

Closes one failure: a "filtered" print of a section of a bridge config file puts every API
key in that section into the chat transcript. The hook blocks (exit 2, logged to
`~/.claude/hooks/blocked-actions.log`) on Bash, Read and Grep(content):

- Reading a whole protected file: `openclaw.json` (plus `.bak*`), `exec-approvals.json`,
  `devbrain.local.env`, `~/.claude/.credentials*`, `~/.supabase/access-token`, any project
  `.env` or `.env.*` (not `.env.example`, `.env.sample` or `.env.template`), and a whole
  `~/.openclaw` directory.
- Commands that print secrets: `supabase secrets list`, `supabase projects api-keys`,
  `vercel env pull|ls`, `gh auth token`.

Rule: a command segment that names a protected path is blocked unless its verb cannot print
content. Allowed: `ls stat test [ wc file du touch mkdir chmod rm cd shasum`, `grep` with
`-c/-q/-l/-L`, `sed -i` (unless its script has a `w` or `e` command or an `s///w` flag),
`cp` and `mv` INTO the file (moving or copying one OUT is a dump), `git` except
`show|cat-file|blame|grep|diff|log|archive` and `--no-index` (the global options `-c k=v` and `-C dir`
are skipped to find the real subcommand), `python -c` code that never prints or dumps (a script or `-m module` that names a protected path is blocked), and
`devbrain-conf-get`. Everything else (cat, head, jq,
awk, yq, base64, open, node, unknown verbs) is blocked, so a new way to dump fails closed.
The hook fails CLOSED: if python cannot run, crashes, or the hook input is not a JSON object,
the call is blocked. Writing into these files (`>`, `tee`, `cp x file`) is allowed on purpose: the setup flow needs
it and it prints nothing.

Instead, read one value: `bin/devbrain-conf-get <file.json|yaml> agents.defaults.model.primary`.
It refuses any key segment matching `key|token|secret|password|pass|credential|auth|bearer|cookie|private|dsn`
(case-insensitive) and any object or list value.

### Register (add to the `PreToolUse` array of `~/.claude/settings.json`)

```json
{
  "matcher": "Bash|Read|Grep",
  "hooks": [
    { "type": "command", "command": "~/.claude/hooks/block-config-secrets-dump.sh" }
  ]
}
```

Copy: `cp claude/hooks/block-config-secrets-dump.sh ~/.claude/hooks/ && chmod +x ~/.claude/hooks/block-config-secrets-dump.sh`;
put `bin/devbrain-conf-get` on your PATH.

### Limits (a hook sees command text, not intent)

Not detected: indirection (`F=~/.openclaw/openclaw.json; cat $F`, globs like
`~/.open*/open*.json`), symlinks to protected files, relative paths for non-distinctive names,
a script file or heredoc whose body reads the file, writing a protected file into git's object
store and reading it back in a second command (`git hash-object -w` then `git cat-file`), `python -c` code that reads the file with
`open(path).read()` and passes it on without any of the words the hook looks for (`print`,
`dump`, `write`, `stdout`, `pprint`, `echo`; for example through `os.system` or `subprocess`), secrets already in env vars (`env`,
`printenv`), and `bash -c` strings (caught only by the path text). Tests:
`tests/test-block-config-secrets-dump.sh`.

## block-dangerous-git.sh

Closes one failure: an executor's tool list may have no `git push` / `git reset`, but that rule lives in one string per script, `Bash(git commit:*)` accepts `--no-verify`, and nothing looked at git in interactive sessions. This hook blocks (exit 2 with a one-line reason, logged to `blocked-actions.log`) on Bash:

- `--no-verify` on `git commit` / `git push`, `-n` on `git commit` (on `push`, `-n` is `--dry-run` and passes), and `git -c core.hooksPath=... commit|push`.
- `git push` with `--force`, `-f`, `--force-with-lease`, `--force-if-includes`, `--mirror`, `--all`, or a refspec starting with `+`.
- `git push` to `main`, `master`, the repo's default branch (`origin/HEAD`) or the base branch in `config/devbrain-base-branch.override` (matched by repo directory name or by the `origin` URL, so a worktree still counts). `git push` / `git push origin HEAD` with no refspec is judged by the current branch. Every spelling git accepts for the destination counts: `main`, `refs/heads/main`, `heads/main`, `HEAD` and `@` on `main`, a deletion (`:main`), a glob, and a bare `:` (push every matching branch).
- `git reset --hard`, `git clean -f*` (a dry run `-n` passes), `git checkout .` / `git checkout -- .` / `git checkout ./` and `git restore .` (`--staged` alone passes, `-S -W` / `-SW` does not), `git branch -D` (also `-d -f`), `git update-ref -d`.

Everything else passes. The command is split into segments (`; && || | & newline ( ) backtick`) and shell words, so quoted text and heredoc bodies are data: `git commit -m "do not use --no-verify"` passes, and so does `echo "git push --force"`. It looks through `git -C dir` / `git -c k=v`, `VAR=x` prefixes, `command`/`env`/`sudo`/`time`/`nice`/`timeout`/`arch` (including their own options: `nice -n 5 git ...`, `env -u X git ...`, `sudo -u root git ...`), a path or upper-case `git`, `bash -c "..."`, `eval "..."`, a `$(...)` inside a double-quoted string (its commands are checked; a PR body in `"$(cat <<'EOF' ... EOF)"` is data), and abbreviated long options (`--no-veri`). It fails OPEN only if the hook itself breaks (bad JSON, python missing): stderr plus an `ERROR` line in the log, never silently. A command without the letters `git` returns before python starts (quotes and backslashes are dropped first, so `g''it` still reaches it). The `git` lookups (current branch, `origin/HEAD`, remote URL) share a 20 s budget (`DEVBRAIN_HOOK_BUDGET`, seconds); a hung git then costs the extra protections, not the hook: `main` and `master` stay blocked. The log line has no control characters and masks `://user:token@` and `NAME_TOKEN=...` style assignments.

### Register (add to the `PreToolUse` array of `~/.claude/settings.json`)

```json
{
  "matcher": "Bash",
  "hooks": [
    { "type": "command", "command": "~/.claude/hooks/block-dangerous-git.sh" }
  ]
}
```

Copy: `cp claude/hooks/block-dangerous-git.sh ~/.claude/hooks/ && chmod +x ~/.claude/hooks/block-dangerous-git.sh`. The base-branch lookup reads `$DEVBRAIN_BASE_OVERRIDE`, default `~/dev/devbrain/config/devbrain-base-branch.override`. It applies to every session, yours included: if it gets in the way, turn it off in your own session; there is no automatic exception.

### Known bypasses (a second layer, not a sandbox)

Not detected: shell aliases and functions, variable indirection (`G=git; $G push -f`), `xargs git ...`, `find -exec`, backticks inside a double-quoted string, a glob for the word (`/usr/bin/gi?`), `git` aliases from config (`git config alias.p "push -f"; git p`, `git -c alias.x=push x -f`), `GIT_*` environment tricks (`GIT_DIR`, `GIT_CONFIG_*`, `git --config-env=...`), a push whose destination comes from config (`push.default`, `remote.origin.push`) instead of the command line, other destructive forms (`git checkout -f <branch>`, `git switch --discard-changes`, `git update-ref --stdin`), any wrapper not listed above, a script or heredoc fed to an interpreter that runs git internally (`python -c "subprocess..."`, `make`, `npm run`), commands of about 1 MB or more (the hook fails open and logs it), and `bash -c`/`eval` nested more than 3 deep. `git push` run by a script (`bin/devbrain` pushes with `--no-verify` itself) is not a Claude tool call, so the hook never sees it. Tests: `tests/test-block-dangerous-git.sh`.

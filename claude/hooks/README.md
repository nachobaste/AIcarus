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

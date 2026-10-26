#!/bin/bash
# Blocks the dangerous forms of git in every Claude Code session:
#   * --no-verify (and -n on `git commit`) on commit/push, `-c core.hooksPath=`
#   * push --force / -f / --force-with-lease / --mirror / --all / a `+` refspec
#   * push to main, master, the repo's default branch, or the base branch named
#     in config/devbrain-base-branch.override (e.g. develop for one project)
#   * reset --hard, clean -f (not a dry run), checkout/restore of `.`,
#     branch -D, update-ref -d
# Everything else passes untouched.
#
# Why: an executor's tool list may have no `git push`/`git reset`, but that rule
# lives in one string per script, `Bash(git commit:*)` accepts --no-verify, and
# nothing in an interactive session looked at git at all. This is a second layer
# that does not depend on any script's allowlist. It is NOT a sandbox: see
# "Known bypasses" in claude/hooks/README.md.
#
# How: python3 splits the command into segments (; && || | & newline ( ) `) and
# words with the quoting rules of the shell, so text inside quotes or a heredoc
# is data and never a flag. `git -C dir` / `git -c k=v` prefixes, env-var
# prefixes, wrappers (command, env, sudo...), `bash -c "..."` and `eval` are
# looked through. Exit 2 with a one-line reason on stderr blocks; the block is
# appended to ~/.claude/hooks/blocked-actions.log like the other hooks.
#
# Fails OPEN only when the hook itself breaks (bad JSON, python missing): that is
# reported on stderr and in the log. A recognised dangerous form never fails open.
set -uo pipefail
# PATH fallback so python3 and git are found under a minimal invoking PATH.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
input=$(cat)
# Cheap prefilter: a command that never says "git" (any case: APFS does not care)
# returns here without starting python. Quotes and backslashes are dropped first:
# the shell reads g''it, g"i"t and G\it as git.
bare=${input//[\'\"\\]/}
case "$bare" in *[gG][iI][tT]*) ;; *) exit 0 ;; esac

LOGF="$HOME/.claude/hooks/blocked-actions.log"
log_line() {
  mkdir -p "$(dirname "$LOGF")" 2>/dev/null
  printf '%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(basename "$0")" "$1" >> "$LOGF" 2>/dev/null || true
}

# The python lives in a variable and the JSON travels in the environment: a
# heredoc inside `$(...)` breaks bash 3.2 when its body has quotes or backticks.
IFS= read -r -d '' PY <<'PYEOF'
import json, os, re, subprocess, sys, time

OVERRIDE = os.environ.get("DEVBRAIN_BASE_OVERRIDE") or os.path.join(
    os.path.expanduser("~"), "dev/devbrain/config/devbrain-base-branch.override")
WRAPPERS = {"command", "env", "exec", "time", "nohup", "sudo", "builtin", "nice",
            "timeout", "arch",
            "!", "if", "then", "else", "elif", "do", "while", "until", "{"}
# Options of a wrapper that take a value as the NEXT word.
WRAPPER_VALUE_OPTS = {
    "nice": {"-n"}, "env": {"-u", "-C", "-S"}, "timeout": {"-k", "-s"},
    "sudo": {"-u", "-g", "-C", "-h", "-p", "-r", "-t", "-U", "-D", "-R", "-T"}}
SHELLS = {"bash", "sh", "zsh", "dash", "ksh"}


def parse(s, i=0, nested=False):
    """Split a command line into ([[word, ...], ...], end index) the way a shell
    would: quotes and heredoc bodies are data, redirections are dropped. With
    nested=True, stop at the `)` that closes the `$(` the caller just consumed.
    The commands inside a `$(...)` in double quotes come back as segments too."""
    segs, cur, tok, has = [], [], "", False
    heredocs, skip_word, depth = [], False, 0
    n = len(s)

    def endtok():
        nonlocal tok, has, skip_word
        if has:
            if skip_word:
                skip_word = False
            else:
                cur.append(tok)
        tok, has = "", False

    def endseg():
        endtok()
        if cur:
            segs.append(cur[:])
            del cur[:]

    while i < n:
        c = s[i]
        if c == "'":
            j = s.find("'", i + 1)
            j = n if j < 0 else j
            tok += s[i + 1:j]; has = True; i = j + 1
        elif c == '"':
            j = i + 1
            while j < n and s[j] != '"':
                if s[j] == "\\" and j + 1 < n and s[j + 1] in '$`"\\':
                    j += 1
                elif s.startswith("$(", j):
                    sub, k = parse(s, j + 2, True)
                    segs.extend(sub)
                    tok += s[j:k + 1]; j = k + 1
                    continue
                tok += s[j]; j += 1
            has = True; i = j + 1
        elif c == "\\":
            if i + 1 < n and s[i + 1] != "\n":
                tok += s[i + 1]; has = True
            i += 2
        elif c in " \t\r":
            endtok(); i += 1
        elif c == "\n":
            endseg(); i += 1
            while heredocs and i <= n:  # skip the body of every pending heredoc
                delim, tabs = heredocs.pop(0)
                while i < n:
                    j = s.find("\n", i)
                    j = n if j < 0 else j
                    line = s[i:j]
                    i = j + 1
                    if (line.lstrip("\t") if tabs else line) == delim:
                        break
        elif c == "#" and not has:
            j = s.find("\n", i)
            i = n if j < 0 else j
        elif c in "<>" or (c == "&" and s[i + 1:i + 2] == ">"):
            if has and tok.isdigit():  # fd number of the redirection: 2>&1
                tok, has = "", False
            else:
                endtok()
            if s.startswith("<<", i) and not s.startswith("<<<", i):
                i += 2
                tabs = s[i:i + 1] == "-"
                i += 1 if tabs else 0
                while i < n and s[i] in " \t":
                    i += 1
                delim = ""
                while i < n and s[i] not in " \t\n;&|()<>":
                    if s[i] in "'\"":
                        q = s.find(s[i], i + 1)
                        q = n if q < 0 else q
                        delim += s[i + 1:q]; i = q + 1
                    else:
                        delim += s[i]; i += 1
                heredocs.append((delim, tabs))
            else:
                while i < n and s[i] in "<>&|":
                    i += 1
                if not (s[i - 1:i] == "&" and s[i:i + 1].isdigit()) and s[i:i + 1] != "-":
                    skip_word = True  # the next word is a file name
                else:
                    while i < n and (s[i].isdigit() or s[i] == "-"):
                        i += 1
        elif c in ";&|()`":
            if c == "(":
                depth += 1
            elif c == ")":
                if nested and depth == 0:
                    endseg()
                    return segs, i
                depth = max(depth - 1, 0)
            endseg(); i += 1
        else:
            tok += c; has = True; i += 1
    endseg()
    return segs, n


# All lookups share one budget (seconds): a hung git must not outlast the
# harness's own hook timeout. Once spent, lookups return "" and the checks fall
# back to main/master (fails open on the extra protections, never on those two).
DEADLINE = time.monotonic() + float(os.environ.get("DEVBRAIN_HOOK_BUDGET", "20"))


def git(repo, *a):
    left = DEADLINE - time.monotonic()
    if left <= 0:
        return ""
    try:
        r = subprocess.run(["git", "-C", repo] + list(a), capture_output=True,
                           text=True, timeout=min(5, left))
        return r.stdout.strip() if r.returncode == 0 else ""
    except Exception:
        return ""


def protected(repo):
    """Branches a session must never push to for the repo at `repo`."""
    p = {"main", "master"}
    head = git(repo, "symbolic-ref", "--short", "refs/remotes/origin/HEAD")
    if head.startswith("origin/"):
        p.add(head[len("origin/"):])
    names = {os.path.basename(git(repo, "rev-parse", "--show-toplevel") or repo.rstrip("/")).lower()}
    url = git(repo, "remote", "get-url", "origin").rstrip("/")
    if url:
        names.add(re.sub(r"\.git$", "", re.split(r"[/:]", url)[-1]).lower())
    try:
        with open(OVERRIDE) as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    k, v = line.split("=", 1)
                    if k.strip().lower() in names and v.strip():
                        p.add(v.strip())
    except OSError:
        pass
    return p


def scan_opts(args, vshort, vlong):
    """-> (long option names, short option letters, positionals). Values of
    options that take one are skipped, so `-m "-n"` is a message, not a flag."""
    longs, shorts, pos = [], set(), []
    i = 0
    while i < len(args):
        t = args[i]
        if t == "--":
            pos += args[i + 1:]
            break
        if t.startswith("--"):
            name = t[2:].split("=", 1)[0]
            longs.append(name)
            if "=" not in t and name in vlong:
                i += 1
        elif t.startswith("-") and len(t) > 1:
            for k, ch in enumerate(t[1:], 1):
                shorts.add(ch)
                if ch in vshort:
                    if k == len(t) - 1:
                        i += 1
                    break
        else:
            pos.append(t)
        i += 1
    return longs, shorts, pos


def hit(longs, *names):
    """True if any long option is (an abbreviation of) one of `names`: git
    accepts `--no-veri` for `--no-verify`."""
    return any(len(l) >= 2 and any(n.startswith(l) for n in names) for l in longs)


def check_push(repo, args):
    longs, shorts, pos = scan_opts(args, "o", {"repo", "push-option", "receive-pack", "exec"})
    if hit(longs, "no-verify"):
        return "git push --no-verify skips the pre-push hook"
    if "f" in shorts or hit(longs, "force", "force-with-lease", "force-if-includes"):
        return "git push --force / -f / --force-with-lease rewrites the remote branch"
    if hit(longs, "mirror", "all"):
        return "git push --mirror / --all overwrites or pushes every branch, the default one included"
    refspecs = pos[1:] if "repo" not in longs else pos
    prot = protected(repo)
    if not refspecs and not hit(longs, "tags"):
        refspecs = ["HEAD"]
    for spec in refspecs:
        if spec.startswith("+"):
            return "git push with a '+' refspec is a forced push"
        if spec == ":":
            return "git push origin : pushes every matching branch, the default one included"
        dst = spec.rsplit(":", 1)[-1] if ":" in spec else spec
        dst = re.sub(r"^(?:refs/)?heads/", "", dst)  # git also takes `heads/main`
        if dst in ("HEAD", "@", ""):
            dst = git(repo, "symbolic-ref", "--short", "-q", "HEAD")
        if "*" in dst or dst in prot:
            return "git push to '%s': main, master and the default/base branch go only through a PR" % dst
    return None


def check_git(a, cwd):
    i, repo, cfg = 0, cwd, []
    while i < len(a) and a[i].startswith("-"):
        o = a[i]
        if o in ("-C", "-c", "--git-dir", "--work-tree", "--namespace") and i + 1 < len(a):
            if o == "-C":
                repo = os.path.join(repo, os.path.expanduser(a[i + 1]))
            elif o == "-c":
                cfg.append(a[i + 1].lower())
            i += 1
        i += 1
    if i >= len(a):
        return None
    sub, args = a[i].lower(), a[i + 1:]
    if sub in ("commit", "push") and any(c.startswith("core.hookspath") for c in cfg):
        return "git -c core.hooksPath=... skips the hooks, same as --no-verify"
    if sub == "commit":
        longs, shorts, _ = scan_opts(args, "mFCct", {
            "message", "file", "author", "date", "template", "reuse-message",
            "reedit-message", "fixup", "squash", "cleanup", "trailer", "pathspec-from-file"})
        if hit(longs, "no-verify") or "n" in shorts:
            return "git commit --no-verify / -n skips the pre-commit and commit-msg hooks"
    elif sub == "push":
        return check_push(repo, args)
    elif sub == "reset":
        longs, _, _ = scan_opts(args, "", {"pathspec-from-file"})
        if hit(longs, "hard"):
            return "git reset --hard throws away uncommitted work"
    elif sub == "clean":
        longs, shorts, _ = scan_opts(args, "e", {"exclude"})
        if ("f" in shorts or hit(longs, "force")) and not ("n" in shorts or hit(longs, "dry-run")):
            return "git clean -f deletes untracked files for good"
    elif sub == "checkout":
        _, _, pos = scan_opts(args, "bB", {"conflict", "orphan"})
        if "." in map(os.path.normpath, pos):
            return "git checkout . throws away every uncommitted change"
    elif sub == "restore":
        longs, shorts, pos = scan_opts(args, "s", {"source", "pathspec-from-file"})  # -S is --staged: no value
        staged_only = ("S" in shorts or hit(longs, "staged")) and not ("W" in shorts or hit(longs, "worktree"))
        if "." in map(os.path.normpath, pos) and not staged_only:
            return "git restore . throws away every uncommitted change"
    elif sub == "branch":
        longs, shorts, _ = scan_opts(args, "", {"set-upstream-to", "contains", "merged", "no-merged", "sort", "format", "points-at"})
        delete = "d" in shorts or hit(longs, "delete")
        if "D" in shorts or (delete and ("f" in shorts or hit(longs, "force"))):
            return "git branch -D deletes a branch whether or not it was merged"
    elif sub == "update-ref":
        longs, shorts, _ = scan_opts(args, "m", set())
        if "d" in shorts or hit(longs, "delete"):
            return "git update-ref -d deletes a ref behind git's back"
    return None


def scan(cmd, cwd, depth=0):
    if depth > 3:
        return None
    for seg in parse(cmd)[0]:
        i, wrapper = 0, None
        while i < len(seg):
            t = seg[i]
            if t in WRAPPERS:
                wrapper = t
            elif re.match(r"[A-Za-z_][A-Za-z0-9_]*=", t):
                pass
            elif wrapper and t.startswith("-"):
                if t in WRAPPER_VALUE_OPTS.get(wrapper, ()):
                    i += 1  # `nice -n 5 git ...`: the 5 is not the command
            elif wrapper == "timeout" and re.match(r"[0-9.]+[smhd]?$", t):
                pass  # timeout's duration
            else:
                break
            i += 1
        if i >= len(seg):
            continue
        base, rest = os.path.basename(seg[i]).lower(), seg[i + 1:]
        if base == "git":
            r = check_git(rest, cwd)
        elif base in SHELLS:
            r = None
            for k, t in enumerate(rest):
                if t.startswith("-") and not t.startswith("--") and "c" in t and k + 1 < len(rest):
                    r = scan(rest[k + 1], cwd, depth + 1)
                    break
        elif base == "eval":
            r = scan(" ".join(rest), cwd, depth + 1)
        else:
            r = None
            if base in ("cd", "pushd"):
                dirs = [t for t in rest if t != "--" and not t.startswith("-")]
                if dirs:
                    d = os.path.join(cwd, os.path.expanduser(dirs[0]))
                    if os.path.isdir(d):
                        cwd = d
        if r:
            return r
    return None


def main():
    d = json.loads(os.environ["HOOK_INPUT"])
    if d.get("tool_name") != "Bash":
        return 0
    cmd = (d.get("tool_input") or {}).get("command") or ""
    cwd = d.get("cwd") or os.getcwd()
    reason = scan(cmd, cwd)
    if not reason:
        return 0
    # Both lines end up in the block log: no control characters (a forged log
    # line, a terminal escape) and no credentials (`://user:token@`, `TOKEN=...`).
    flat = re.sub(r"://[^/\s@]*@", "://***@", cmd)
    flat = re.sub(r"(?i)\b(\w*(?:token|secret|passw|key)\w*)=\S+", r"\1=***", flat)
    clean = lambda t: re.sub(r"[\x00-\x1f\x7f-\x9f]+", " ", t)
    print(clean(reason))
    print(clean(flat)[:300])
    return 2


try:
    sys.exit(main())
except SystemExit:
    raise
except Exception as e:  # the hook itself broke: caller fails open and logs it
    print("%s: %s" % (type(e).__name__, e), file=sys.stderr)
    sys.exit(3)
PYEOF
out=$(HOOK_INPUT="$input" python3 -I -c "$PY")
rc=$?
case "$rc" in
  0) exit 0 ;;
  2)
    { IFS= read -r reason; IFS= read -r flat; } <<< "$out"
    echo "BLOCKED by block-dangerous-git: $reason (a human does this)." >&2
    log_line "$reason: $flat"
    exit 2
    ;;
  *)
    echo "block-dangerous-git: internal error (rc=$rc), allowing the command. Check ~/.claude/hooks/blocked-actions.log" >&2
    log_line "ERROR rc=$rc hook failed open"
    exit 0
    ;;
esac

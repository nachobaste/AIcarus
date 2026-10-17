#!/bin/bash
# Blocks dumping config/credential files that hold API keys or tokens
# (openclaw.json, devbrain.local.env, project .env*, ...) and CLI commands that
# print secrets (supabase secrets list, ...), via Bash and via the Read/Grep
# tools. The failure it closes: a "filtered" print of one section of a bridge
# config file puts every API key in that section into the chat transcript.
# Safe way to read one value: bin/devbrain-conf-get <file> <dotted.key>.
# Design + limits: claude/hooks/README.md
#
# Rule: if a command segment mentions a protected path, it is blocked unless
# its verb is on a short list of verbs that cannot print file content.
# Test knobs (empty value = that list disabled): DEVBRAIN_SECRET_PATH_RE,
# DEVBRAIN_SECRET_CMD_RE.
set -euo pipefail
# PATH fallback so python3 is found under a minimal invoking PATH (a hook can
# be started with almost nothing on it).
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
input=$(cat)

log_blocked() {
  printf '%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(basename "$0")" "$1" >> "$HOME/.claude/hooks/blocked-actions.log" 2>/dev/null || true
}

# Fails CLOSED: if python cannot run, or crashes, or the input is not JSON, the call is blocked
# (an empty reason used to mean "allowed", so a broken hook silently allowed everything).
reason=$(HOOK_INPUT="$input" python3 - <<'PY' 2>/dev/null
import json, os, re, shlex

try:
    d = json.loads(os.environ["HOOK_INPUT"])
    if not isinstance(d, dict):
        raise ValueError("not an object")
except ValueError:
    print("could not be parsed (malformed hook input)")
    raise SystemExit(0)
tool, ti = d.get("tool_name", ""), d.get("tool_input", {}) or {}

# Protected files (matched as text, never resolved or opened). Basenames that
# are distinctive match even when relative (cd ~/.openclaw && cat openclaw.json).
PATH_RE = os.environ.get("DEVBRAIN_SECRET_PATH_RE", "|".join([
    r"openclaw\.json",                       # also matches .bak*
    r"exec-approvals\.json",
    r"devbrain\.local\.env",
    r"\.claude/\.credentials",
    r"\.supabase/access-token",
    r"(?<![\w.-])\.env(?:\.(?!example\b|sample\b|template\b)[\w.-]+)?(?![\w.-])",
    # whole-directory targets: `grep -r ... ~/.openclaw`, `cat ~/.openclaw/*`
    r"(?:\.openclaw)(?:/\*[\w.*-]*|/)?(?=[\s\"';|&)]|$)",
]))
CMD_RE = os.environ.get("DEVBRAIN_SECRET_CMD_RE", "|".join([
    r"\bsupabase\s+secrets\s+list\b",
    r"\bsupabase\s+projects\s+api-keys\b",
    r"\bvercel\s+env\s+(pull|ls|list)\b",
    r"\bgh\s+auth\s+token\b",
]))
# Verbs that cannot print file content. `git` is allowed except the content
# readers below; grep only with a count/quiet/list flag; sed only with -i.
SAFE = {"ls", "stat", "test", "[", "[[", "wc", "file", "du", "touch", "mkdir",
        "chmod", "chown", "rm", "cd", "shasum", "md5", "md5sum",
        "sha256sum", "devbrain-conf-get", "realpath", "dirname", "basename", "true", ":"}
WRAP = {"sudo", "command", "env", "time", "nice", "nohup", "builtin"}

def tokens(seg):
    try:
        return shlex.split(seg, posix=True)
    except ValueError:
        return seg.split()

def split_segments(cmd):  # split on ; | & newline, outside quotes
    segs, cur, q, i = [], "", None, 0
    while i < len(cmd):
        c = cmd[i]
        if q:
            cur += c
            if c == q: q = None
            elif c == "\\" and q == '"' and i + 1 < len(cmd):
                i += 1; cur += cmd[i]
        elif c in "'\"":
            q = c; cur += c
        elif c == "\\" and i + 1 < len(cmd):
            cur += c + cmd[i + 1]; i += 1
        elif c in ";|&\n":
            segs.append(cur); cur = ""
        else:
            cur += c
        i += 1
    segs.append(cur)
    return [s.strip() for s in segs if s.strip()]

def verdict(seg):
    t = tokens(seg)
    while t and (re.match(r"^\w+=", t[0]) or t[0] in WRAP):
        t = t[1:]
    if not t:
        return False
    verb, args = os.path.basename(t[0]), t[1:]
    if verb in SAFE:
        # cp/mv: a protected SOURCE copied elsewhere is a dump; only blocked for cp below
        return False
    if verb in ("cp", "mv"):
        # writing INTO a protected file is fine; moving or copying one OUT is a dump
        return not (args and re.search(PATH_RE, args[-1]))
    if verb in ("grep", "egrep", "fgrep", "rg"):
        flags = "".join(a[1:] for a in args if a.startswith("-") and not a.startswith("--"))
        long_ok = any(a in ("--count", "--quiet", "--files-with-matches", "--files-without-match") for a in args)
        return not (long_ok or re.search(r"[cqlL]", flags))
    if verb == "sed":
        if not any(re.match(r"^-[a-zA-Z]*i", a) or a.startswith("--in-place") for a in args):
            return True
        # -i prints nothing on its own, but a `w` or `e` command (or the s///w flag) can write
        # the file to stdout or run a command: any script that has one is a dump.
        for a in args:
            if re.match(r"^\s*(?:[\d$,!/]*\s*)?[wWeE]\s*\S", a) or re.search(r"[;{}\n]\s*[wWeE]\s*\S", a) \
               or re.search(r"s(.)(?:\\.|(?!\1).)*\1(?:\\.|(?!\1).)*\1[a-zA-Z0-9]*[we]", a):
                return True
        return False
    if verb == "git":
        # skip the global options (`-c k=v`, `-C dir`, ...) to find the real subcommand: a
        # `git -C ~/.openclaw show HEAD:openclaw.json` or `git -c core.pager=cat diff --no-index
        # /dev/null <file>` is the same dump as without the option
        i, sub = 0, ""
        while i < len(args):
            a = args[i]
            if a in ("-c", "-C", "--git-dir", "--work-tree", "--namespace", "--exec-path"):
                i += 2
            elif a.startswith("-"):
                i += 1
            else:
                sub = a
                break
        return sub in ("show", "cat-file", "blame", "grep", "diff", "log", "archive", "") or "--no-index" in args
    if verb.startswith("python"):
        # Only `python -c <code>` can be judged by what its code says. A script, a module
        # (`-m json.tool <file>`) or a file argument naming a protected path is a dump.
        if "-c" not in args:
            return True
        return bool(re.search(r"print|dump|write|stdout|pprint|echo", seg))
    return True  # cat less more head tail bat awk jq base64 strings open node ... and anything unknown

def bash_reason(cmd):
    if CMD_RE and re.search(CMD_RE, cmd):
        return "prints secrets"
    if not PATH_RE:
        return ""
    for seg in split_segments(cmd):
        if re.search(PATH_RE, seg) and verdict(seg):
            return "dumps a secrets file"
    return ""

r = ""
if tool == "Bash":
    r = bash_reason(ti.get("command", ""))
elif tool == "Read":
    if PATH_RE and re.search(PATH_RE, ti.get("file_path", "")):
        r = "reads a secrets file"
elif tool == "Grep":
    if PATH_RE and re.search(PATH_RE, ti.get("path", "") or "") and ti.get("output_mode", "files_with_matches") == "content":
        r = "greps content of a secrets file"
print(r)
PY
) || reason="could not be evaluated (the hook itself failed)"

if [ -n "$reason" ]; then
  echo "🛑 Blocked: this call $reason (API keys/tokens would land in the chat). Read one value with: devbrain-conf-get <file> <dotted.key> (refuses key/token/secret names). See claude/hooks/README.md." >&2
  tool=$(echo "$input" | python3 -c "import json,sys; d=json.load(sys.stdin); t=d.get('tool_input',{}); print(d.get('tool_name'), t.get('command') or t.get('file_path') or t.get('path'))" 2>/dev/null) || tool="?"
  log_blocked "config secrets dump ($reason): $tool"
  exit 2
fi
exit 0

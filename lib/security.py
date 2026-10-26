#!/usr/bin/env python3
"""security -- the script decides, not the model.

Run by bin/devbrain-security-accept (`python3 -I`). It takes what the read-only security session wrote and
computes the verdict that goes on the PR or the plan:

  * fixed rule (no model): any change to hooks, .claude/settings*.json, launchd plists, and any added or
    removed line with allowedTools / disallowedTools / permission-mode / dangerously-skip-permissions is
    BLOCKS, whatever the model says and even if its output is invalid. A change to agent permissions
    always blocks;
  * model findings: those with confidence below MIN_CONF (or none) are dropped; every `path:line` is
    checked against the worktree; no evidence or an invented category makes it a NOTICE;
  * the verdict is BLOCKS only if a BLOCKS finding with evidence remains;
  * no secret-shaped value reaches the result (it is masked).

Output: the block on stdout. Exit 0 = result computed (and saved, except the `--fixed-rule-only` case
with no findings); 3 = session rejected or nothing to save: no result was written.

ponytail: the fixed rule works on TEXT; a permissions change assembled through a variable does not trip it
and is left to the model. Token masking is a net, not a guarantee (a short secret or one with spaces passes).
"""
import argparse
import hashlib
import os
import re
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import secret_patterns  # noqa: E402

MIN_CONF = 80  # MUT:threshold
CATEGORIES = ("secrets", "injection", "permissions", "personal-data", "dependency",
              "agent-config", "production")
PLAN_PATH = ".devbrain-plan.md"

_AGENT_FILE = [re.compile(p) for p in (
    r"(^|/)\.claude/hooks/", r"(^|/)hooks/", r"(^|/)\.husky/",
    r"(^|/)\.claude/settings[^/]*\.json$", r"\.plist$",
    r"(^|/)openclaw/exec-approvals\.json$", r"(^|/)\.mcp\.json$", r"(^|/)\.claude/agents/",  # MUT:paths
)]
_PERMISSION_LINE = re.compile(r"allowedTools|disallowedTools|permission-mode|dangerously-skip-permissions"
                              r"|allowed-tools|disallowed-tools|--tools")  # MUT:permissions
_FIXED = "BLOCKS :: %s (fixed rule) :: confidence: 100"


def _fixed(path, line, text):
    return "FINDING: agent-config :: %s:%d :: " % (clean(path), line) + _FIXED % text


def fixed_rule_diff(diff):
    """Fixed-rule findings over a unified diff. Only added or removed lines, never context."""
    out, path, first, in_hunk, new, seen = [], None, None, False, 0, set()

    def close():
        if path and any(rx.search(path) for rx in _AGENT_FILE):
            out.append(_fixed(path, first or 1, "change to an agent configuration file"))

    for l in diff.split("\n"):  # no splitlines(): \x0c, \r and U+2028 would cut a changed line in two
        m = re.match(r'^diff --git "a/(.*)" "b/(.*)"$', l) or re.match(r"^diff --git a/(.+) b/(.+)$", l)
        if m:
            close()
            path, first, in_hunk = m.group(2), None, False
            if not any(rx.search(path) for rx in _AGENT_FILE) and any(rx.search(m.group(1)) for rx in _AGENT_FILE):
                path = m.group(1)
            continue
        m = re.match(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@", l)
        if m:
            new, in_hunk = int(m.group(1)), True
            continue
        if not in_hunk or not l:
            continue
        c = l[0]
        if c in "+-":
            if first is None:
                first = new
            m = _PERMISSION_LINE.search(l[1:])
            if m and (path, new, c) not in seen:
                seen.add((path, new, c))
                out.append(_fixed(path, new, "line %s with %s" % ("added" if c == "+" else "removed", m.group(0))))
            if c == "+":
                new += 1
        elif c == " ":
            new += 1
    close()
    return out


def fixed_rule_text(text):
    """Plan mode: a plan line that IS a permissions command (inside a code block, or starting with the
    name), not a sentence that mentions them."""
    out, fence = [], False
    for n, l in enumerate(text.splitlines(), 1):
        if l.lstrip().startswith("```"):
            fence = not fence
            continue
        m = _PERMISSION_LINE.search(l)
        if m and (fence or re.match(r"^(allowedTools|disallowedTools|permission-mode|dangerously-skip-permissions)",
                                    re.sub(r"^[\s>*+`\"'-]+", "", l))):
            out.append(_fixed(PLAN_PATH, n, "the plan adds a line with %s" % m.group(0)))
    return out


_TRIGGERS = re.compile(
    r"allowedTools|disallowedTools|permission-mode|dangerously|allowlist|permission|hook|"
    r"settings[^ \n]*\.json|plist|launchd|secret|token|credential|api[ _-]?key|personal data|"
    r"\bPII\b|egress|network", re.I)


def plan_triggers(text):
    """Plan mode: the plan names permissions, personal data, secrets, network, hooks, settings or plists."""
    return bool(_TRIGGERS.search(text))  # MUT:triggers


def parse(text):
    """(declared, scope, findings) from the model's output, or None if it lacks the format."""
    ls = text.splitlines()
    if not ls or ls[0] not in ("SECURITY: OK", "SECURITY: BLOCKS") or "## Scope" not in ls or "## Findings" not in ls:
        return None
    a, h = ls.index("## Scope"), ls.index("## Findings")
    if h < a:
        return None
    return ls[0].split(": ", 1)[1], "\n".join(ls[a + 1:h]).strip(), [x for x in ls[h + 1:] if x.startswith("FINDING:")]


def evidence(wt, loc):
    m = re.match(r"^(.+):(\d+)$", loc or "")
    if not m or m.group(1).startswith("/") or ".." in m.group(1).split("/"):
        return False
    try:  # a NUL byte or an unreadable file means "no evidence", never a crash that skips the fixed rule
        real, base = os.path.realpath(os.path.join(wt, m.group(1))), os.path.realpath(wt)
        if not real.startswith(base + os.sep) or not os.path.isfile(real):
            return False
        with open(real, "rb") as f:
            n = len(f.read().splitlines())
    except (ValueError, OSError):
        return False
    return 1 <= int(m.group(2)) <= n


def finding(l):
    """(cat, loc, sev, text, confidence|None) or None if the line lacks even the minimum fields."""
    p = [x.strip() for x in l[len("FINDING:"):].split(" :: ")]
    if len(p) < 4:
        return None
    conf = re.match(r"^confidence:\s*(\d{1,3})$", p[-1]) if len(p) >= 5 else None
    text = " :: ".join(p[3:-1] if conf else p[3:])
    return p[0], p[1], p[2], text, int(conf.group(1)) if conf else None


def clean(text):
    """Mask what looks like a secret: known formats and long token-shaped strings."""
    text = secret_patterns.redact(text)

    def mask(m):
        s = m.group(0)
        sep = sum(c in "-_" for c in s)
        return "[HIDDEN]" if re.search(r"\d", s) and re.search(r"[A-Za-z]", s) and sep / len(s) < 0.1 else s
    return re.sub(r"[A-Za-z0-9+/_=-]{32,}", mask, text)


def session_valid(registry, session, plan):
    """One session = one role per plan: the security one could not plan, execute, review or propose."""
    roles = set()
    try:
        with open(registry, encoding="utf-8", errors="replace") as f:
            for l in f:
                c = l.rstrip("\n").split("\t")
                if len(c) >= 3 and c[0] == session and c[1] == plan:
                    roles.add(c[2])
    except OSError:
        pass
    if not roles:
        return "the session is not registered for this plan"
    if roles != {"security"}:
        return "the session already had another role in this plan (%s)" % ", ".join(sorted(roles - {"security"}))
    return None


def save(dest, text):
    os.makedirs(os.path.dirname(dest), mode=0o700, exist_ok=True)
    tmp = dest + ".tmp.%d" % os.getpid()
    with os.fdopen(os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w", encoding="utf-8") as f:
        f.write(text)
    os.replace(tmp, dest)


def _result(dir_, plan, mode):
    return os.path.join(dir_, plan + ("-plan.md" if mode == "plan" else ".md"))


def _sha(path):
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


def state(dir_, plan, mode="pr"):
    """clear | blocks | overridden. An override is valid for the sha256 of THIS result: another
    blocking result needs another override."""
    path = _result(dir_, plan, mode)
    try:
        with open(path, encoding="utf-8") as f:
            if f.readline().rstrip("\n") != "SECURITY: BLOCKS":
                return "clear"
        sha = _sha(path)
    except OSError:
        return "clear"
    try:
        with open(os.path.join(dir_, "overrides.tsv"), encoding="utf-8") as f:
            for l in f:
                c = l.rstrip("\n").split("\t")
                if len(c) >= 4 and c[1] == plan and c[2] == mode and c[3] == sha:  # MUT:sha
                    return "overridden"
    except OSError:
        pass
    return "blocks"


def override(dir_, plan, mode, via, note):
    """Record the override (date, plan, mode, sha256, via, note) and print the sha. The note is required."""
    note = " ".join(note.split())
    if not note:
        print("ERROR: an override needs a note", file=sys.stderr)
        return 2
    if state(dir_, plan, mode) != "blocks":
        print("ERROR: there is no standing security block for #%s" % plan, file=sys.stderr)
        return 3
    sha = _sha(_result(dir_, plan, mode))
    row = "\t".join((time.strftime("%Y-%m-%dT%H:%M:%S"), plan, mode, sha, via or "owner", clean(note))) + "\n"
    fd = os.open(os.path.join(dir_, "overrides.tsv"), os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    with os.fdopen(fd, "a", encoding="utf-8") as f:
        f.write(row)
    print(sha)
    return 0


def main(argv):
    if argv and argv[0] in ("state", "override"):
        ap = argparse.ArgumentParser()
        ap.add_argument("cmd")
        ap.add_argument("--dir", required=True)
        ap.add_argument("--plan", required=True)
        ap.add_argument("--mode", choices=("pr", "plan"), default="pr")
        ap.add_argument("--via", default="")
        ap.add_argument("--note", default="")
        a = ap.parse_args(argv)
        if not re.match(r"^[A-Za-z0-9._-]+$", a.plan):
            return 2
        if a.cmd == "state":
            print(state(a.dir, a.plan, a.mode))
            return 0
        return override(a.dir, a.plan, a.mode, a.via, a.note)
    ap = argparse.ArgumentParser()
    ap.add_argument("--mode", choices=("pr", "plan"), required=True)
    ap.add_argument("--plan", required=True)
    ap.add_argument("--worktree", required=True)
    ap.add_argument("--dir", required=True)
    ap.add_argument("--input", help="pr: the diff; plan: the plan text")
    ap.add_argument("--output", default="-", help="what the session wrote ('-' = nothing)")
    ap.add_argument("--session", default="")
    ap.add_argument("--registry", default="")
    ap.add_argument("--fixed-rule-only", action="store_true")
    a = ap.parse_args(argv)
    if not re.match(r"^[A-Za-z0-9._-]+$", a.plan):
        print("ERROR: --plan is not valid", file=sys.stderr)
        return 2
    dest = os.path.join(a.dir, a.plan + ("-plan.md" if a.mode == "plan" else ".md"))

    text_in = open(a.input, encoding="utf-8", errors="replace", newline="").read() if a.input else ""
    fixed = fixed_rule_diff(text_in) if a.mode == "pr" else fixed_rule_text(text_in)

    if not a.fixed_rule_only:
        reason = session_valid(a.registry, a.session, a.plan)
        if reason:  # session rejected: no result is written  # MUT:rejected
            print("SECURITY: UNAVAILABLE\n## Scope\nSession rejected: %s.\n## Findings\n(none)" % reason)
            return 3

    parsed = None
    if not a.fixed_rule_only and a.output != "-":
        try:
            parsed = parse(open(a.output, encoding="utf-8", errors="replace").read())
        except OSError:
            parsed = None
    declared, scope, raw = parsed if parsed else (None, "", [])

    lines, blocks, dropped = list(fixed), bool(fixed) and True, 0  # MUT:pinned
    for l in raw:
        h = finding(l)
        if not h or h[4] is None or h[4] < MIN_CONF:
            dropped += 1
            continue
        cat, loc, sev, text, conf = h
        sev = sev if sev in ("BLOCKS", "NOTICE") else "NOTICE"
        if cat not in CATEGORIES or not evidence(a.worktree, loc):
            lines.append("FINDING: %s :: %s :: NOTICE (NO EVIDENCE) :: %s :: confidence: %d" % (clean(cat), clean(loc), clean(text), conf))
            continue
        if cat == "agent-config":
            sev = "BLOCKS"
        blocks = blocks or sev == "BLOCKS"
        lines.append("FINDING: %s :: %s :: %s :: %s :: confidence: %d" % (cat, loc, sev, clean(text), conf))

    if a.fixed_rule_only and not fixed:
        print("SECURITY: UNAVAILABLE\n## Scope\nThe session was rejected.\n## Findings\n(none)")
        return 3
    if parsed is None and not fixed:  # the session failed and no fixed rule applies
        previous = ""
        try:
            previous = open(dest, encoding="utf-8").read()
        except OSError:
            pass
        if previous.startswith("SECURITY: BLOCKS\n"):  # never replaces a recorded BLOCKS
            print(previous.rstrip("\n") + "\nNOTE: this run's session failed; the recorded BLOCKS stands.")
            return 0
        verdict = "UNAVAILABLE"
        scope = "The security session failed or returned invalid output: this change had no security review."
    else:
        verdict = "BLOCKS" if blocks else "OK"
        if parsed is None:
            scope = "The session returned invalid output; only the fixed agent-permissions rule was applied."

    body = ["SECURITY: " + verdict, "## Scope", clean(scope) or "(no scope)", "## Findings"]
    body += lines or ["(none)"]
    if declared and declared != verdict:
        body.append("NOTE: the model declared SECURITY: %s; the script computed %s (confidence threshold %d and path:line evidence required)."
                    % (declared, verdict, MIN_CONF))
    if dropped:
        body.append("NOTE: %d finding(s) dropped for confidence below %d or none." % (dropped, MIN_CONF))
    body.append("Run: " + time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()))  # a new run is a new sha256: an old override never covers it
    text = "\n".join(body) + "\n"
    save(dest, text)
    sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

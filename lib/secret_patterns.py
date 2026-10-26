#!/usr/bin/env python3
"""secret_patterns -- what "looks like a secret" for devbrain, in ONE place.

Two readers, no copies:
  * bin/devbrain-drift imports `find_secret` (skill files, sys.path derived from __file__).
  * bin/devbrain runs this file as a script before it pushes a branch:
        python3 -I lib/secret_patterns.py review <base-ref> <blocked|ok>
    (cwd = the repo being pushed). `-I` ignores PYTHONPATH and user site, and nothing here
    reads an environment variable, so no variable can change which patterns load or which
    interpreter loads them.

`review` reads EVERY commit of <base-ref>..HEAD (not the net diff: a secret committed and then
deleted still travels in the history), as text (--text, no textconv, no external diff, so a
.gitattributes `-diff` or `binary` cannot hide a line), plus each commit message, author and
committer. It prints one line per finding, `<path>\t<kind>` or `commit message <sha>\t<kind>`,
and NEVER a value. Exit 0 = clean, 1 = findings, 2 = the review could not run (fail closed:
the caller counts it as a finding).

  blocked: also stops binaries (git's own NUL-in-first-8000-bytes rule, applied to the blob, not
           to an attribute) and data extensions -- nobody reviewed that work.
  ok:      names (.env*, *.env) and patterns only; a reviewer and the owner gate the rest in the PR.

ponytail: the filter only knows FORMATS. `.envrc`, `.npmrc` `_authToken`, a cloud service
account JSON (except its PEM header), base64 blobs, new key formats and personal data in prose
pass. A pushed branch is never deleted and its history persists: the only cure for a leak is to
rotate the key. Blobs are read one `git cat-file` at a time (fine to a few thousand files per
push); switch to `cat-file --batch` if a branch ever carries tens of thousands.
"""
import re
import subprocess
import sys

# A letter or digit before the prefix means it is the tail of some other word, not a key.
_B = r"(?<![A-Za-z0-9])"
_B64 = r"[A-Za-z0-9_-]"

# (kind, regex). A prefix without the full body does NOT match: the minimum lengths are the
# difference between a key and the prose that names one ("sb_secret_", "ghp_abc", "sk-proj-x").
FORMATS = [
    ("anthropic", re.compile(_B + r"sk-ant-[A-Za-z]+[0-9]+-" + _B64 + r"{80,}")),
    ("openai-project", re.compile(_B + r"sk-proj-" + _B64 + r"{40,}")),
    ("generic-sk", re.compile(_B + r"sk-[A-Za-z0-9]{20,}")),
    ("jwt", re.compile(_B + r"eyJ" + _B64 + r"{7,}\." + _B64 + r"{10,}\." + _B64 + r"{20,}")),
    ("supabase-secret", re.compile(_B + r"sb_secret_" + _B64 + r"{20,}")),
    ("supabase-account", re.compile(_B + r"sbp_[0-9a-fA-F]{40}")),
    ("github", re.compile(_B + r"(?:gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{60,})")),
    ("xai", re.compile(_B + r"xai-[A-Za-z0-9]{40,}")),
    ("slack", re.compile(_B + r"xox[bpa]-[A-Za-z0-9-]{24,}")),
    ("npm", re.compile(_B + r"npm_[A-Za-z0-9]{36,}")),
    ("sentry", re.compile(_B + r"sntrys_[A-Za-z0-9+/=_-]{40,}")),
    # Mapbox secret: `sk.` + a JWT-ish payload (eyJ...) + `.` + signature. The anchor is strong on
    # purpose: "task-runner", "risk-based" and "desk.example" must not match.
    ("mapbox", re.compile(_B + r"sk\.eyJ" + _B64 + r"{25,}\." + _B64 + r"{16,}")),
    # Resend: >= 24 chars after `re_` with a digit AND an uppercase letter, so a snake_case
    # identifier like re_run_failed_plans_every_night is prose. `_` also blocks the prefix.
    ("resend", re.compile(r"(?<![A-Za-z0-9_])re_(?=[A-Za-z0-9_]*[0-9])(?=[A-Za-z0-9_]*[A-Z])[A-Za-z0-9_]{24,}")),
    # The AWS secret key (40 chars) is only a secret NEXT TO its name, on the same line: a bare
    # 40-char blob is as likely a sha1.
    ("aws-secret", re.compile(r"(?i)(?:aws_?secret_?(?:access_?)?key|secretaccesskey)[\"']?[ \t]*[:=][ \t]*[\"']?"
                              r"[A-Za-z0-9/+=]{40}(?![A-Za-z0-9/+=])")),
    # An opaque credential needs a digit: `Bearer YOUR_API_KEY_HERE_REPLACE_ME` is a placeholder.
    ("bearer", re.compile(r"(?i:\bBearer)[ \t]+(?=[A-Za-z0-9._~+/=-]*[0-9])[A-Za-z0-9._~+/=-]{24,}")),
    ("token-in-url", re.compile(r"[?&]token=(?=[A-Za-z0-9._~%+/_-]*[0-9])[A-Za-z0-9._~%+/_-]{16,}")),
    ("stripe", re.compile(_B + r"[sr]k_live_[A-Za-z0-9]{24,}")),
    ("telegram-bot", re.compile(_B + r"[0-9]{8,10}:" + _B64 + r"{35}")),
    ("google", re.compile(_B + r"AIza" + _B64 + r"{35}")),
    ("aws", re.compile(r"AKIA[0-9A-Z]{16}")),
    ("private-key", re.compile(r"-----BEGIN[ A-Z]*PRIVATE KEY-----")),
]

# ://user:password@host. Exempt ONLY loopback + the password `postgres` (a local database's
# usual default): a loopback URL with any other password may be a tunnel to a real database.
_URL = re.compile(r"://(?P<user>[^/\s:]+):(?P<pw>[^/\s@]+)@(?P<host>\[[0-9A-Fa-f:]+\]|[^/\s:@?#]+)")
_LOOPBACK = ("127.0.0.1", "localhost", "[::1]")


def find_secret(text):
    """Kind of the first secret-shaped thing in `text`, or None. Never returns the value."""
    for kind, rx in FORMATS:
        if rx.search(text):
            return kind
    for m in _URL.finditer(text):
        if not (m.group("host").lower() in _LOOPBACK and m.group("pw") == "postgres"):
            return "credential-in-url"
    return None


_CRED = re.compile(r"://(?P<cred>[^/\s?#]*)@(?P<host>\[[0-9A-Fa-f:]+\]|[^/\s:@?#]*)")


def redact(text):
    """`text` with every secret-shaped value masked; fails closed (the whole text is dropped) if one survives."""
    for kind, rx in FORMATS:
        text = rx.sub("[secret:%s]" % kind, text)
    text = re.sub(r"(\[secret:[a-z-]+\])[A-Za-z0-9_.:-]{8,}", r"\1", text)   # a key glued to its tail
    text = _CRED.sub(lambda m: "://[secret-url-credential]@" + m.group("host") if ":" in m.group("cred") else m.group(0), text)
    return text if find_secret(text) is None else "[text omitted: secret shape I could not mask]"


# ponytail: `.json`, `.txt` and `.sql` stay OUT of this list. Open question: a blocked plan that
# dumps rows into one of them still travels. A repo that keeps migrations or verify scripts as
# `.sql` would be stopped on every blocked branch by listing it. To add one, add its extension
# here; to tell SQL data from SQL code a content check is needed (INSERT/COPY does not work:
# migrations carry INSERTs too).
_DATA_EXT = (".csv", ".tsv", ".xlsx", ".sqlite", ".db", ".out")
_TEMPLATE_END = (".example", ".sample", ".template")


def _git(*args):
    # --no-replace-objects: a session can `git fetch . +<clean sha>:refs/replace/<secret sha>` and
    # this review would read the clean commit while `git push` sends the real object.
    return subprocess.run(["git", "--no-replace-objects", *args], capture_output=True, check=True).stdout


def _clean(path):  # a file name in a report: printable only
    return "".join(c if c.isprintable() else "?" for c in path)[:200]


def _added_text(sha, path):
    """What commit `sha` added to `path`: the '+' lines of its diff, read as TEXT.

    --text ignores a .gitattributes `-diff` / `binary` (which would print "Binary files differ"
    and hide the line); --no-textconv and --no-ext-diff ignore a configured converter or diff tool.
    """
    d = _git("--literal-pathspecs", "diff-tree", "-p", "--text", "--no-textconv", "--no-ext-diff", "-U0",
             "-r", "-m", "--root", "--no-renames", "--no-commit-id", sha, "--", path).decode("latin-1")
    out, in_hunk = [], False
    for line in d.split("\n"):
        if line.startswith("diff "):
            in_hunk = False
        elif line.startswith("@@"):
            in_hunk = True
        elif in_hunk and line.startswith("+"):
            out.append(line[1:])
    return "\n".join(out)


def review(base, mode):
    findings = []

    def note(where, kind):
        if (where, kind) not in findings:
            findings.append((where, kind))

    for sha in _git("rev-list", "--reverse", base + "..HEAD").decode().split():
        kind = find_secret(_git("show", "-s", "--format=%B", sha).decode("utf-8", "replace"))
        if kind:
            note("commit message " + sha[:7], "pattern " + kind)
        # author and committer (name + email) are text that travels with the push too
        kind = find_secret(_git("show", "-s", "--format=%an %ae %cn %ce", sha).decode("utf-8", "replace"))
        if kind:
            note("commit author " + sha[:7], "pattern " + kind)
        raw = _git("diff-tree", "-r", "-m", "--root", "--no-renames", "--no-abbrev",
                   "--no-commit-id", "--raw", "-z", sha).split(b"\0")
        for i in range(0, len(raw) - 1, 2):
            meta = raw[i].decode().lstrip(":").split()
            if len(meta) < 5 or meta[4][0] == "D" or meta[1] == "160000":
                continue  # deleted files and submodules add nothing
            new = meta[3]
            path = raw[i + 1].decode("utf-8", "replace")
            low = path.rsplit("/", 1)[-1].lower()
            # a secret in the NAME itself: say which commit, never the name
            kind = find_secret(path)
            where = "(file name, commit %s)" % sha[:7] if kind else _clean(path)
            if kind:
                note(where, "pattern " + kind)
            # templates are exempt from the NAME rule, not from the patterns below
            if (low == ".env" or low.startswith(".env.") or low.endswith(".env")) and not low.endswith(_TEMPLATE_END):
                note(where, ".env file name")
            if mode == "blocked":
                if low.endswith(_DATA_EXT):
                    note(where, "data")
                elif b"\0" in _git("cat-file", "blob", new)[:8000]:
                    note(where, "binary")
            kind = find_secret(_added_text(sha, path))
            if kind:
                note(where, "pattern " + kind)
    return findings


def main(argv):
    if len(argv) != 4 or argv[1] != "review" or argv[3] not in ("blocked", "ok"):
        print("(review)\tusage: review <base-ref> <blocked|ok>")
        return 2
    try:
        findings = review(argv[2], argv[3])
    except Exception:  # fail closed, and say nothing that could carry a value
        print("(review)\tcould not run")
        return 2
    for where, kind in findings[:10]:
        print(where + "\t" + kind)
    if len(findings) > 10:
        print("(more)\t%d more findings" % (len(findings) - 10))
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

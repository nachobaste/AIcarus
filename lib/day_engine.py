#!/usr/bin/env python3
"""day_engine — the motor behind the day-shift: a decision on a proposal, this
writes it as a plan or discards it. Shared by bin/devbrain-day (the terminal
interface) and a potential Telegram approval path — one implementation, so the two
paths cannot validate differently.

Every proposal is identified by its TITLE, never by its position in a list. A list
position is a snapshot; the backlog can change between when a title was shown and
when a decision on it is applied (a whole interactive walkthrough, or hours between
a morning digest and a "dale 2" from Telegram). Resolving "which numbered item" to
a title is the CALLER's job, done once, close to wherever the human typed the
number. This engine never guesses which proposal a stale number still points to.

Read-only except for its own stdout: it never writes a file, never touches git. The
caller (lib/day.sh) does that, the same split already used by research_filter and
research_promote.

Usage (backlog text always via stdin):
    day_engine.py list
    day_engine.py show <title>
    day_engine.py render <title> [--option A|B]
    day_engine.py mark <title> dale|no [--reason TEXT]

Environment:
    RESEARCH_ALLOWFILE  devbrain-projects.allow path (render only)
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from research_filter import fold  # noqa: E402

SLUG_MAX = 48


def slugify(text):
    import unicodedata
    stripped = unicodedata.normalize("NFKD", text.lower())
    ascii_only = "".join(c for c in stripped if not unicodedata.combining(c))
    slug = re.sub(r"[^a-z0-9]+", "-", ascii_only).strip("-")
    return slug[:SLUG_MAX].rstrip("-") or "proposal"


def parse_backlog(text):
    """Every '### ' block that carries a '- source:' line — the same marker
    research_promote uses to tell a proposal apart from a raw finding, which shares
    the same '### title' heading. Each block keeps its raw lines (for `show` and for
    splicing in `mark`) and its options in order, each with its own raw lines (for
    `render`, which needs an option's pros/cons verbatim, not just its files)."""
    blocks, cur = [], None
    for raw in text.splitlines():
        line = raw.rstrip()
        if line.startswith("### "):
            if cur:
                blocks.append(cur)
            cur = {"title": line[4:].strip(), "meta": {}, "options": [], "raw": [raw]}
            continue
        if cur is None:
            continue
        cur["raw"].append(raw)
        if line.startswith("#### "):
            cur["options"].append({"name": line[5:].strip(), "files": set(), "raw": [raw]})
            continue
        if cur["options"]:
            opt = cur["options"][-1]
            opt["raw"].append(raw)
            m = re.match(r"^\s*-\s*([^:]+?)\s*:\s*(.*)$", line)
            if m and fold(m.group(1)) == "files":
                opt["files"] = {p.strip().strip("`") for p in m.group(2).split(",") if p.strip()}
            continue
        m = re.match(r"^\s*-\s*([^:]+?)\s*:\s*(.*)$", line)
        if m:
            cur["meta"][fold(m.group(1))] = m.group(2).strip()
    if cur:
        blocks.append(cur)
    return [b for b in blocks if "source" in b["meta"]]


def pending(blocks):
    return [b for b in blocks if "decision" not in b["meta"]]


def find_pending(blocks, title):
    for b in pending(blocks):
        if b["title"] == title:
            return b
    return None


def cmd_list():
    for b in pending(parse_backlog(sys.stdin.read())):
        print(b["title"])
    return 0


def cmd_show(title):
    b = find_pending(parse_backlog(sys.stdin.read()), title)
    if not b:
        print(f"day_engine: no pending proposal with that title: {title!r}", file=sys.stderr)
        return 3
    print("\n".join(b["raw"]).rstrip())
    return 0


def is_self_repo(repo, allowfile):
    """Is `repo` this devbrain installation's own repo (the same directory that
    devbrain-projects.allow lives in), rather than a project it manages? Structural
    check, not a hardcoded name — it works no matter what you called your checkout.
    devbrain-projects.excluded should also list this repo explicitly with a reason,
    but this check protects `render` even if someone forgets that line."""
    if not allowfile:
        return False
    root = os.path.dirname(os.path.abspath(allowfile))
    return repo == os.path.basename(root)


def allowed_repo(repo, allowfile):
    # This devbrain installation's own repo is refused by structural check,
    # independently of the allowlist file — that file is editable by anyone, and
    # this repo holds the security limits an unattended agent runs under.
    if is_self_repo(repo, allowfile):
        return False
    if not allowfile or not os.path.isfile(allowfile):
        return False
    with open(allowfile, encoding="utf-8") as fh:
        listed = {ln.strip() for ln in fh if ln.strip() and not ln.strip().startswith("#")}
    return repo in listed


def cmd_render(title, option_letter):
    b = find_pending(parse_backlog(sys.stdin.read()), title)
    if not b:
        print(f"day_engine: no pending proposal with that title: {title!r}", file=sys.stderr)
        return 4
    repo = b["meta"].get("repo", "")
    allowfile = os.environ.get("RESEARCH_ALLOWFILE", "")
    if not allowed_repo(repo, allowfile):
        print(f"day_engine: repo not enabled for approval: {repo!r} "
              f"(see {allowfile or 'RESEARCH_ALLOWFILE not set'})", file=sys.stderr)
        return 3
    if not b["options"]:
        print(f"day_engine: proposal {title!r} has no options to choose from", file=sys.stderr)
        return 4

    if option_letter:
        idx = ord(option_letter.upper()) - ord("A")
        if idx < 0 or idx >= len(b["options"]):
            print(f"day_engine: invalid option: {option_letter!r}", file=sys.stderr)
            return 2
    else:
        idx = 0  # default: the first/recommended option
    option = b["options"][idx]
    letter = chr(ord("A") + idx)

    files = ", ".join(sorted(option["files"])) or "(no files declared)"
    risks = b["meta"].get("risks", "(none declared by the proposal)")
    verify = b["meta"].get("verify", "(not specified by the proposal)")
    source = b["meta"].get("source", "(no source finding)")
    option_detail = "\n".join(option["raw"]).strip()

    body = f"""{b['title']}

## Context

Proposal from the research shift (`devbrain-research` -> `devbrain-day`), generated from
the finding "{source}". Chosen option: {letter} — {option['name']}.

## What to do

Affected files: {files}

{option_detail}

## How to verify

{verify}

## Risks

{risks}

## Reminder

Generated by `devbrain-day` from an already-approved proposal ("dale").
Not a hand-written plan — if anything does not line up against the real code,
prioritize what you observe in the repo over what the proposal assumed.
"""
    print(f"repo: {repo}")
    print(f"slug: {slugify(b['title'])}")
    print("---")
    print(body)
    return 0


def cmd_mark(title, decision, reason):
    text = sys.stdin.read()
    blocks = parse_backlog(text)
    b = find_pending(blocks, title)
    if not b:
        print(f"day_engine: no pending proposal with that title: {title!r} "
              "(already decided, or does not exist)", file=sys.stderr)
        return 3

    if decision == "dale":
        dec_line = "- decision: approved"
    elif decision == "no":
        if not reason or not reason.strip():
            print("day_engine: discarding a proposal requires --reason (without one, "
                  "research repeats the same mistake all week)", file=sys.stderr)
            return 2
        dec_line = f"- decision: discarded — {reason.strip()}"
    else:
        print(f"day_engine: unknown decision: {decision!r} (dale|no)", file=sys.stderr)
        return 2

    lines = text.splitlines()
    # Locate the block's raw lines within the full text by matching its exact sequence
    # once — a proposal's raw block is unique by construction (parse_backlog built it
    # from a single contiguous run of lines), so this anchors reliably even if two
    # proposals happen to share a title (the source line still disambiguates them,
    # since sys.stdin.read() -> parse -> pending -> find_pending already picked one
    # specific block object, not just a name).
    block_text = "\n".join(b["raw"])
    joined = "\n".join(lines)
    start = joined.find(block_text)
    if start < 0:
        print("day_engine: could not locate the proposal's exact block in the "
              "backlog (was it hand-edited between parsing and now?)", file=sys.stderr)
        return 5
    insertion = start + len(b["raw"][0])  # right after the '### title' line
    new_text = joined[:insertion] + "\n" + dec_line + joined[insertion:]
    print(new_text)
    return 0


def main(argv):
    if len(argv) < 2:
        print("usage: day_engine.py list|show|render|mark ...", file=sys.stderr)
        return 2
    cmd = argv[1]
    rest = argv[2:]

    if cmd == "list":
        return cmd_list()
    if cmd == "show":
        if not rest:
            print("usage: day_engine.py show <title>", file=sys.stderr)
            return 2
        return cmd_show(rest[0])
    if cmd == "render":
        if not rest:
            print("usage: day_engine.py render <title> [--option A|B]", file=sys.stderr)
            return 2
        option = None
        if "--option" in rest:
            i = rest.index("--option")
            option = rest[i + 1] if i + 1 < len(rest) else None
            del rest[i:i + 2]
        return cmd_render(rest[0], option)
    if cmd == "mark":
        if len(rest) < 2:
            print("usage: day_engine.py mark <title> dale|no [--reason TEXT]", file=sys.stderr)
            return 2
        reason = None
        if "--reason" in rest:
            i = rest.index("--reason")
            reason = rest[i + 1] if i + 1 < len(rest) else None
            del rest[i:i + 2]
        return cmd_mark(rest[0], rest[1], reason)

    print(f"day_engine.py: unknown command: {cmd!r}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))

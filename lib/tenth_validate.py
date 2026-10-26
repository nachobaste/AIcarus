#!/usr/bin/env python3
"""lib/tenth_validate.py: validates the tenth man's answer. The script decides, not the model.

Usage: python3 -I lib/tenth_validate.py <repo dir>   (the model's raw answer on stdin)

Valid:   exit 0; stdout is the normalized text: first line `DISSENT: BLOCKS|DOES NOT BLOCK` COMPUTED here,
         a `NOTE:` line when the model declared the other one, objections without evidence rewritten as
         `OBJECTION: <what> :: NO EVIDENCE :: RISK`.
Invalid: exit 2; one line with the reason on stderr (the caller logs it and shows `UNAVAILABLE`).

BLOCKS only if at least one objection has valid evidence AND says MUST FIX. Valid evidence is a
`path:line` that exists inside the repo (a `..` escape does not count) or `SCENARIO: ` plus 50+ characters.
"""
import os
import re
import sys

FIRST_LINES = ("DISSENT: BLOCKS", "DISSENT: DOES NOT BLOCK")
SECTIONS = ["Failure modes", "Gaps in safeguards", "Blind spots", "Plausible worst case",
            "What would make it wrong", "How to revert", "Residual risks"]
LEVELS = ("MUST FIX", "RISK")


def invalid(reason):
    print(reason, file=sys.stderr)
    sys.exit(2)


def evidence_valid(ev, repo):
    try:
        return _evidence_valid(ev.strip(), repo)
    except (ValueError, OSError):   # NUL byte, absurd line number, unreadable file: not valid evidence, never a crash
        return False


def _evidence_valid(ev, repo):
    m = re.match(r"SCENARIO:\s*(.*)$", ev)
    if m:
        return len(m.group(1).strip()) >= 50
    m = re.match(r"([^\s:]+):(\d{1,9})\s*$", ev)
    if not m or int(m.group(2)) < 1:
        return False
    path = os.path.realpath(os.path.join(repo, m.group(1)))
    if not path.startswith(repo + os.sep) or not os.path.isfile(path):
        return False
    with open(path, "rb") as f:
        return sum(1 for _ in f) >= int(m.group(2))


def main():
    repo = os.path.realpath(sys.argv[1])
    lines = sys.stdin.read().splitlines()
    if not any(l.strip() for l in lines):
        invalid("empty output")
    declared = lines[0].rstrip()
    if declared not in FIRST_LINES:
        invalid("invalid first line: %r" % declared[:60])
    body, current = {}, None
    for l in lines[1:]:
        m = re.match(r"##\s+(.+?)\s*$", l)
        if m:
            current = m.group(1)
            body.setdefault(current, [])
        elif current:
            body[current].append(l)
    for s in SECTIONS:
        if not "".join(body.get(s, [])).strip():
            invalid("missing or empty section: ## " + s)
    items = [l for l in body["Residual risks"] if re.match(r"\s*([-*]|\d+\.)\s+\S", l)]
    if len(items) < 3:
        invalid("fewer than 3 residual risks (%d)" % len(items))

    blocks, out = False, []
    for l in lines[1:]:
        m = re.match(r"\s*(?:[-*]\s+)?\**OBJECTION(?::\**|\**:)\s*(.*)$", l)
        if not m:
            out.append(l)
            continue
        parts = m.group(1).split(" :: ")
        if len(parts) == 3 and parts[2].strip() in LEVELS and evidence_valid(parts[1], repo):
            out.append("OBJECTION: %s :: %s :: %s" % (parts[0].strip(), parts[1].strip(), parts[2].strip()))
            blocks = blocks or parts[2].strip() == "MUST FIX"
        else:
            out.append("OBJECTION: %s :: NO EVIDENCE :: RISK" % parts[0].strip())
    computed = "DISSENT: " + ("BLOCKS" if blocks else "DOES NOT BLOCK")
    print(computed)
    if computed != declared:
        print("NOTE: the model declared \"%s\"; the script computed \"%s\" (only an objection with evidence and MUST FIX blocks)."
              % (declared, computed))
    print("\n".join(out))


if __name__ == "__main__":
    main()

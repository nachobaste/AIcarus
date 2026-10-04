#!/usr/bin/env python3
"""Redact person names from text on its way out of the machine.

Reads stdin, writes redacted text to stdout. Exit 2 and empty stdout when the
name list is missing or empty — fail closed, because a gate that silently does
nothing produces output that looks correct.

The name list holds the FULL forms to redact, one per line. It is deliberately
not clever about given names: an earlier version absorbed any run of
capitalised words before a surname, which collapsed "El Presidente Ejecutivo
<name>" into a single placeholder and destroyed legitimate content. Explicit
entries beat inference.
"""
import os
import re
import sys

PLACEHOLDER = "[puesto]"
NAMES_FILE = os.environ.get(
    "CLASSIFY_NAMES_FILE",
    os.path.expanduser("~/.config/devbrain/secrets/redact-names.txt"))


def load_patterns(path):
    try:
        with open(path, encoding="utf-8") as fh:
            raw = [ln.strip() for ln in fh]
    except OSError:
        return None
    return [ln for ln in raw if ln and not ln.startswith("#")]


def build_regex(patterns):
    parts = []
    for pat in patterns:
        # (6) Escape metacharacters so a "." or "[" in the list is a literal.
        escaped = re.escape(pat)
        # (4)(5) Any run of whitespace in the pattern matches any run of
        # whitespace in the text, including a newline — a name wrapped across
        # two lines or separated by a tab must still match.
        flexible = re.sub(r"(?:\\[ ])+", r"\\s+", escaped)
        # (8) Anchor on word boundaries with lookarounds, so a short entry does
        # not shred unrelated prose. Without this, "Ana" turned "bananas" into
        # "b[puesto]nas" and "Panama" into "P[puesto]ma". Lookarounds beat \b
        # here because a pattern may legitimately begin or end with punctuation.
        parts.append(rf"(?<!\w){flexible}(?!\w)")
    # (1) IGNORECASE: ALL-CAPS signature blocks are routine in institutional
    # documents, and this corpus also has ALL-CAPS project names.
    return re.compile("|".join(parts), re.IGNORECASE)


def main():
    # `--text` is accepted for compatibility with existing callers; plain text
    # is the only mode.
    patterns = load_patterns(NAMES_FILE)
    if not patterns:
        print(f"notion-redact: {NAMES_FILE} is missing or has no patterns — "
              "refusing to emit unredacted content", file=sys.stderr)
        return 2
    sys.stdout.write(build_regex(patterns).sub(PLACEHOLDER, sys.stdin.read()))
    return 0


if __name__ == "__main__":
    sys.exit(main())

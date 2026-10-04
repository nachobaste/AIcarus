#!/usr/bin/env python3
"""research_promote — raw backlog in, 2-3 decidable proposals out.

The operator's definition of "done" (interview 2026-08-08): *few and deep* — at
most 2-3 proposals per cycle, each already investigated, with the files it would touch,
at least two options with pros and cons, and effort in nights. They should be able to
decide in about five minutes. The point is to spend less of their time, not to produce
more text.

Two jobs, both deliberately out of the prompt and into code:

  select    which findings earn the expensive deep pass. The criteria are below, in
            the open, so they can be argued with and changed. A ranking hidden in a
            prompt is a ranking nobody can audit.
  validate  whether what came back is actually decidable. The failure mode is a
            second "option" that touches the same files as the first — filler
            dressed as a choice, and the easiest thing to produce when a model is
            told to give two options.

Read-only. Writes nothing; the caller decides what to do with stdout.

Usage:
    ... | research_promote.py select      # backlog  -> the findings to deepen
    ... | research_promote.py validate    # proposals -> the ones that are decidable

Environment:
    RESEARCH_PROMOTE_MAX      how many to promote per cycle (default 3)
    RESEARCH_REPO_ROOT        repo that a proposal's file paths must resolve against
    DEVBRAIN_DIGEST_STALE_DAYS  days a pending proposal can wait before the digest
                              flags it (default 3). Shared with bin/devbrain-digest's
                              Bloqueadas section, set by the same caller, so one
                              number controls staleness for both.
"""
import datetime
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from research_filter import fold, parse_blocks, parse_findings, render  # noqa: E402

# --- the selection criteria, in the open -------------------------------------
# Order matters and reflects the plan: first what unblocks other work, then what
# carries the hardest evidence, then what is smallest. Change these numbers and the
# ranking changes — that is the point of having them here instead of in a prompt.
#
# "Unblocks other work" is not machine-detectable, so it is not guessed: it counts
# only when the finding SAYS so. A finding that does not claim to block anything is
# not treated as if it might.
BLOCKS_MARKERS = ("blocks", "prevents", "stuck", "without this", "until this is resolved",
                   "cannot proceed", "depends on")
WEIGHT_BLOCKS = 100     # a declared blocker outranks everything else
WEIGHT_PER_FILE = 10    # distinct files cited, capped
MAX_FILES_COUNTED = 5
WEIGHT_SIZE = 10        # smaller is better, never negative


def files_in(evidence):
    """Distinct file paths in an evidence field, line numbers and backticks off."""
    out = set()
    for cite in evidence.split(","):
        cite = cite.strip().strip("`").strip()
        if not cite:
            continue
        out.add(cite.rsplit(":", 1)[0] if re.search(r":\d+$", cite) else cite)
    return out


def nights_in(size):
    m = re.search(r"\d+(?:[.,]\d+)?", size or "")
    return float(m.group(0).replace(",", ".")) if m else 1.0


def score(f):
    why = (f.get("why") or "").lower()
    s = WEIGHT_BLOCKS if any(m in why for m in BLOCKS_MARKERS) else 0
    s += WEIGHT_PER_FILE * min(len(files_in(f.get("evidence", ""))), MAX_FILES_COUNTED)
    s += max(0.0, WEIGHT_SIZE - nights_in(f.get("size", "")))
    return s


def already_promoted(text):
    """Titles that a proposal already claims as its source.

    Without this the same proposal reaches the operator every night until they act on it,
    which trains him to ignore the section.
    """
    return {b["meta"]["source"] for b in parse_blocks(text) if "source" in b["meta"]}


def do_select():
    text = sys.stdin.read()
    done = already_promoted(text)
    try:
        cap = int(os.environ.get("RESEARCH_PROMOTE_MAX", "3"))
    except ValueError:
        cap = 3

    candidates = [f for f in parse_findings(text)
                  if f.get("title") and f["title"] not in done
                  and all(f.get(k) for k in ("repo", "evidence", "why", "size"))]

    # Sorted by score, ties broken by position in the backlog — never by chance, so
    # the same backlog always yields the same picks.
    ordered = sorted(enumerate(candidates), key=lambda p: (-score(p[1]), p[0]))
    chosen = [f for _, f in ordered[:cap]]

    for f in chosen:
        print(render(f))

    if not chosen:
        print("nothing to promote", file=sys.stderr)
    else:
        print(f"promoted: {len(chosen)} of {len(candidates)} candidates", file=sys.stderr)
    return 0


# --- validation ---------------------------------------------------------------
def do_validate(source=None):
    root = os.environ.get("RESEARCH_REPO_ROOT", "")
    kept, dropped = [], {"insufficient-options": 0, "identical-options": 0,
                         "no-anchor": 0}

    for p in parse_blocks(sys.stdin.read()):
        options = [o for o in p["options"] if o["files"]]
        if len(options) < 2:
            dropped["insufficient-options"] += 1
            continue
        # Two options over the same files are one option written twice. The operator
        # cannot choose between them, so the proposal is not decidable.
        if len({frozenset(o["files"]) for o in options}) < 2:
            dropped["identical-options"] += 1
            continue
        # A proposal names what it would TOUCH, which legitimately includes files it
        # would create — the finding "there is no package.json" can only be answered by
        # a proposal that names one. So a missing path is annotated, not fatal.
        # What IS fatal is a proposal where nothing resolves: that is either about a
        # different repo or invented whole, and either way it is not decidable here.
        all_files = set().union(*(o["files"] for o in options))
        existing = {a for a in all_files if os.path.isfile(os.path.join(root, a))}
        # Anchoring means "in THIS repo". An absolute path defeats os.path.join, so
        # /etc/hosts used to resolve and pass as an anchor. Options that reach into
        # another repo stay allowed — they are often the honest answer — but they
        # cannot be the only thing holding the proposal up.
        real_root = os.path.realpath(root) if root else ""
        anchored = {a for a in existing
                  if real_root and (os.path.realpath(os.path.join(root, a)) + os.sep)
                  .startswith(real_root + os.sep)}
        if not anchored:
            dropped["no-anchor"] += 1
            continue
        p["new_files"] = all_files - existing
        kept.append(p)

    for p in kept:
        print(f"### {p['title']}")
        if source:
            # Written here, never taken from the model. A misattributed proposal would
            # mark the wrong finding as promoted and the real one would return nightly.
            print(f"- source: {source}")
        body = [ln for ln in p["raw"][1:] if fold(ln.strip().lstrip("- ").split(":", 1)[0]) != "source"]
        text = "\n".join(body).strip()
        # Mark what does not exist yet, so the operator reads "this creates a file" instead of
        # assuming every path named is already there.
        for new_file in sorted(p.get("new_files", ()), key=len, reverse=True):
            text = text.replace(new_file, f"{new_file} (new)")
        print(text + "\n")

    detail = ", ".join(f"{k}: {v}" for k, v in dropped.items() if v)
    print(f"proposals: {len(kept)} dropped: {sum(dropped.values())}"
          + (f" ({detail})" if detail else ""), file=sys.stderr)
    return 0



# --- digest: what reaches the operator's phone at 6am --------------------------
# The number in front of each proposal is load-bearing: plan 250 lets the operator
# reply "dale 2" from Telegram. It must stay exact and stable, so this NEVER goes through
# the AI summarizer that writes the rest of the digest — a model asked to
# "summarize" would feel free to reword or drop it.
DIGEST_LINE_CAP = 140

# The "## Proposals — YYYY-MM-DD" heading is written once, by do_validate's caller,
# the moment a finding is promoted (see wiki/projects/mejoras-propuestas.md) — a
# real date, not a proxy. Every '### ' proposal block until the next such heading
# was promoted on that date, so age here is exact, unlike Bloqueadas (see
# queue_file_age_days in lib/queue.sh, whose mtime-based age IS a proxy).
DEFAULT_STALE_DAYS = 3


def _one_line(text, cap=DIGEST_LINE_CAP):
    flat = " ".join((text or "").split())
    return flat if len(flat) <= cap else flat[: cap - 1].rstrip() + "…"


def _stale_days():
    try:
        return int(os.environ.get("DEVBRAIN_DIGEST_STALE_DAYS", str(DEFAULT_STALE_DAYS)))
    except ValueError:
        return DEFAULT_STALE_DAYS


def _days_waiting(date_iso):
    """Days between a '## Proposals — YYYY-MM-DD' heading and today, or None if
    the heading is missing/malformed (hand-edited backlog) — degrades honestly,
    same principle as the rest of do_digest, instead of guessing an age."""
    if not date_iso:
        return None
    try:
        date = datetime.date.fromisoformat(date_iso)
    except ValueError:
        return None
    return (datetime.date.today() - date).days


def _proposal_blocks(text):
    """Every promoted proposal (a block with '- source:'), with the date of its
    '## Proposals — YYYY-MM-DD' heading."""
    return [{"title": b["title"], "source": b["meta"]["source"],
             "effort": b["meta"].get("effort") or "(not estimated)",
             "decided": b["meta"].get("decision"), "date": b["date"]}
            for b in parse_blocks(text) if "source" in b["meta"]]


def _why_by_title(text):
    return {f["title"]: f.get("why", "") for f in parse_findings(text)}


def do_digest():
    text = sys.stdin.read()
    why_by = _why_by_title(text)
    pending = [p for p in _proposal_blocks(text) if not p["decided"]]

    try:
        cap = int(os.environ.get("RESEARCH_DIGEST_MAX", "5"))
    except ValueError:
        cap = 5

    threshold = _stale_days()
    for i, p in enumerate(pending[:cap], start=1):
        why = why_by.get(p["source"], "(source finding not found)")
        print(f"{i}. {p['title']}")
        print(f"   {_one_line(why)}")
        # Age is appended to the Effort line, not a line of its own: the digest
        # format is a load-bearing 3-lines-per-proposal contract (see
        # tests/test-research-promote.sh) that plan 250's "dale N" reply depends
        # on staying stable — a 4th line would change nothing about the numbering,
        # but there is no reason to risk it.
        line = f"Effort: {p['effort']}"
        days = _days_waiting(p.get("date"))
        if days is not None and days >= 0:
            word = "day" if days == 1 else "days"
            line += f" — waiting {days} {word}"
            if days >= threshold:
                line = "⚠️ " + line
        print(f"   {line}")

    rest = len(pending) - cap
    if rest > 0:
        print(f"… and {rest} more, see mejoras-propuestas.md")
    return 0


def main(argv):
    mode = argv[1] if len(argv) > 1 else ""
    if mode == "select":
        return do_select()
    if mode == "digest":
        return do_digest()
    if mode == "validate":
        source = None
        if "--source" in argv:
            i = argv.index("--source")
            source = argv[i + 1] if i + 1 < len(argv) else None
        return do_validate(source)
    print("usage: research_promote.py select|validate", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))

#!/usr/bin/env python3
"""research_filter — the gate between what the model said and what the backlog keeps.

devbrain-research asks a model to report gaps in a repo. The failure mode that
matters is not a missed finding, it is a fabricated one: the operator approves
work from this backlog, so a plausible finding pointing at a file that does not
exist costs more than no research at all.

So a finding survives only if it carries a citation that resolves to a real
file AND a real line inside the repo. Everything else is dropped, and the
count of drops goes to stderr — never silently.

Read-only. Never writes; the caller decides what to do with stdout.

Usage:
    ... | research_filter.py            # findings on stdout, summary on stderr

Environment:
    RESEARCH_REPO_ROOT   repo the citations are resolved against (single-repo runs)
    RESEARCH_REPO_ROOTS  newline-separated `name=path` pairs, for multi-repo runs.
                         Takes precedence over RESEARCH_REPO_ROOT. Newline, not
                         colon: a path may not contain a newline, but nothing
                         stops it containing a colon.
    RESEARCH_MIN_REPOS   distinct repos a finding must cite (default 1). The
                         `conexiones` scope sets 2: a "connection" that only cites
                         one repo is not a connection, it is an internal gap that
                         wandered into the wrong bucket.
    RESEARCH_EXISTING    backlog file, for dedup by title (optional)
    RESEARCH_MAX         cap on findings kept per run (default 5)
"""
import os
import re
import sys
import unicodedata

FIELDS = ("repo", "evidencia", "porque", "tamano")
CITATION = re.compile(r"^(?P<path>.+):(?P<line>\d+)$")


def fold(name):
    """'tamaño' and 'tamano' are the same field.

    The prompt asks for unaccented keys; a model writing Spanish will produce
    the accented spelling and be right to. Demanding the misspelling would make
    the filter reject perfectly good findings as incomplete.
    """
    stripped = unicodedata.normalize("NFKD", name.strip().lower())
    return "".join(c for c in stripped if not unicodedata.combining(c))


def parse_findings(text):
    """Pull '### title' blocks out of the model's output, ignoring its prose."""
    findings, current = [], None
    for raw in text.splitlines():
        line = raw.rstrip()
        if line.startswith("### "):
            if current:
                findings.append(current)
            current = {"titulo": line[4:].strip()}
            continue
        if current is None:
            continue
        m = re.match(r"^\s*-\s*([^:]+?)\s*:\s*(.*)$", line)
        if m:
            key = fold(m.group(1))
            if key in FIELDS:
                current[key] = m.group(2).strip()
    if current:
        findings.append(current)
    return findings


def citation_resolves(citation, root):
    """True only if the path is inside root, exists, and has that many lines.

    Backticks are stripped first: models write paths in code formatting, and
    rejecting `src/real.js:3` over a markdown character would read as
    fabrication in the summary while the finding was perfectly good.
    """
    m = CITATION.match(citation.strip().strip("`").strip())
    if not m:
        return False
    path = os.path.realpath(os.path.join(root, m.group("path").strip()))
    root = os.path.realpath(root)
    # A citation that escapes the repo is not evidence about the repo.
    if path != root and not path.startswith(root + os.sep):
        return False
    if not os.path.isfile(path):
        return False
    line = int(m.group("line"))
    if line < 1:
        return False
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return sum(1 for _ in fh) >= line
    except OSError:
        return False


def resolve_in(citation, roots):
    """Name of the first repo the citation resolves in, or None.

    A citation may be written relative to any of the repos in a multi-repo run,
    so each is tried. Returning the NAME rather than a bool is what lets the
    caller count distinct repos and enforce RESEARCH_MIN_REPOS.
    """
    for name, root in roots:
        if citation_resolves(citation, root):
            return name
    return None


def parse_roots():
    """[(name, path)] from the environment, multi-repo form winning."""
    raw = os.environ.get("RESEARCH_REPO_ROOTS", "")
    if raw.strip():
        roots = []
        for entry in raw.splitlines():
            entry = entry.strip()
            if not entry or "=" not in entry:
                continue
            name, _, path = entry.partition("=")
            roots.append((name.strip(), path.strip()))
        return roots
    single = os.environ.get("RESEARCH_REPO_ROOT", "")
    return [(os.path.basename(single.rstrip("/")), single)] if single else []


def existing_titles(path):
    if not path or not os.path.isfile(path):
        return set()
    with open(path, encoding="utf-8", errors="replace") as fh:
        return {ln[4:].strip() for ln in fh if ln.startswith("### ")}


def render(f):
    return (f"### {f['titulo']}\n"
            f"- repo: {f['repo']}\n"
            f"- evidencia: {f['evidencia']}\n"
            f"- porque: {f['porque']}\n"
            f"- tamano: {f['tamano']}\n")


def main():
    roots = parse_roots()
    missing = [p for _, p in roots if not os.path.isdir(p)]
    if not roots or missing:
        print("research_filter: repo root no existe: "
              + (", ".join(missing) or "(ninguno configurado)"), file=sys.stderr)
        return 2
    try:
        min_repos = max(1, int(os.environ.get("RESEARCH_MIN_REPOS", "1")))
    except ValueError:
        min_repos = 1
    known = existing_titles(os.environ.get("RESEARCH_EXISTING", ""))
    try:
        cap = int(os.environ.get("RESEARCH_MAX", "5"))
    except ValueError:
        cap = 5

    kept, dropped = [], {"cita-no-resuelve": 0, "duplicado": 0, "incompleto": 0,
                         "una-sola-repo": 0}
    truncated = 0
    seen = set()

    for f in parse_findings(sys.stdin.read()):
        if any(not f.get(k) for k in FIELDS):
            dropped["incompleto"] += 1
            continue
        if f["titulo"] in known or f["titulo"] in seen:
            dropped["duplicado"] += 1
            continue
        cites = [c for c in f["evidencia"].split(",") if c.strip()]
        # Every citation must hold. One real plus one invented is still a
        # finding that is partly fabricated.
        where = [resolve_in(c, roots) for c in cites]
        if not cites or any(w is None for w in where):
            dropped["cita-no-resuelve"] += 1
            continue
        # A connection has to be evidenced in more than one repo, or it is not a
        # connection. Only enforced when the caller asks for it.
        if len(set(where)) < min_repos:
            dropped["una-sola-repo"] += 1
            continue
        if len(kept) >= cap:
            # Counted, not swallowed: a truncating tool that reports zero
            # discards reads as "covered everything" when it did not.
            truncated += 1
            continue
        seen.add(f["titulo"])
        kept.append(f)

    for f in kept:
        print(render(f))

    if truncated:
        dropped["truncado"] = truncated
    detail = ", ".join(f"{k}: {v}" for k, v in dropped.items() if v)
    total = sum(dropped.values())
    print(f"hallazgos: {len(kept)} descartados: {total}"
          + (f" ({detail})" if detail else ""), file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())

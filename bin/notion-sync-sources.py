#!/usr/bin/env python3
"""Parse the internal process-area markdown wiki into Notion-shaped rows.

NOTE: the Notion integration this script feeds (bin/notion-sync and friends)
is OPTIONAL -- a nice-to-have dashboard mirror, not core to devbrain. Nothing
else in this system depends on it running; skip it entirely if you have no
Notion workspace to sync into.

Pure function of the filesystem: no network, no Notion knowledge, no import
from lib/notion_api.py or any of the other Task 1-3 modules. This script only
reads markdown files and emits JSON; typing those values into Notion property
shapes happens in a later task.

Usage: notion-sync-sources.py <subcommand>

Subcommands are added one per source kind (areas today; projects, tasks,
goals, events, resources later). Each subcommand has a default directory
under ~/dev/projects/ and an env var that overrides it, so tests can point at
a fixture directory instead of the real wiki. The default paths below are
placeholders for a repo layout that does not exist in this starter kit --
point the env vars at your own wiki before running this for real.

Exit codes: 0 success · 1 a source file is malformed, ambiguous, or missing ·
2 usage (no subcommand, or an unknown one).
"""
import datetime
import json
import os
import re
import sys
from pathlib import Path

# One entry per subcommand: (default source path, override env var). "Path"
# is a directory for the glob-a-folder subcommands (areas, tasks, resources)
# and a single file for the ones that read the BHAG doc (projects, goals,
# events) -- same seam, the value just means "where main() reads from".
BHAG_FILE_DEFAULT = os.path.expanduser(
    "~/dev/wiki/projects/bhag-2026-08-agosto.md")

SOURCES = {
    # NOTION_SYNC_AREAS_DIR is the real override -- always set it. The
    # fallback below is a placeholder path (no such repo ships with this
    # starter kit) so a misconfigured run fails with a clear "no .md files
    # found" instead of silently reading nothing meaningful.
    "areas": (
        os.environ.get("NOTION_SYNC_SOURCE_DIR",
                        os.path.expanduser("~/dev/projects/your-process-docs-repo/procesos")),
        "NOTION_SYNC_AREAS_DIR",
    ),
    "projects": (BHAG_FILE_DEFAULT, "NOTION_SYNC_BHAG_FILE"),
    "goals": (BHAG_FILE_DEFAULT, "NOTION_SYNC_BHAG_FILE"),
    "events": (BHAG_FILE_DEFAULT, "NOTION_SYNC_BHAG_FILE"),
    "tasks": (os.path.expanduser("~/dev/queue"), "NOTION_SYNC_QUEUE_DIR"),
    "resources": (
        os.path.expanduser("~/dev/wiki/services"),
        "NOTION_SYNC_SERVICES_DIR",
    ),
    "meetings": (
        os.path.expanduser("~/.openclaw/state/minutas-snapshot.json"),
        "NOTION_SYNC_MINUTAS_SNAPSHOT",
    ),
}

# Not a subcommand's own source (no "status" subcommand exists), so it is
# not in SOURCES above -- but it is read by projects() to compute each
# devbrain epic's traffic light, and needs the exact same fixture-friendly
# seam every other source directory already has.
STATUS_DIR_DEFAULT = os.path.expanduser("~/dev/wiki/status")
STATUS_DIR_ENV = "NOTION_SYNC_STATUS_DIR"

# "Today", for the same reason: a rule that compares a committed date or an
# evidence date against the real wall clock produces a test that passes now
# and fails later. Every threshold/date-passed test fixes this via the env
# var; production code (main()) never sets it, so real runs use the real
# date.
TODAY_ENV = "NOTION_SYNC_TODAY"

# Rule 2/3's boundary: evidence exactly this many days old or newer is
# still green; older (or absent) is yellow. A single named constant so the
# mutation test (7 -> 8) has one place to change.
EVIDENCE_STALE_DAYS = 7

# "owner/repo" for the link resources() builds to each service page's source
# on GitHub. No real username is hardcoded here -- the fallback below is a
# clearly-fake placeholder, never used for auth or any real API call, and
# resources() only ever reads it to build a display URL string. Set this to
# your own wiki's "owner/repo" before running for real.
GITHUB_WIKI_REPO = os.environ.get(
    "NOTION_SYNC_WIKI_GITHUB_REPO", "your-github-username/dev-wiki")

# An ATX H1: "# " followed by at least one non-space character, CommonMark's
# own requirement of a space after the hash. Captured group is the heading
# text with trailing whitespace excluded; leading whitespace inside the text
# (after "# ") is excluded by \s+ already being consumed as the separator.
HEADING_RE = re.compile(r"^#[ \t]+(\S.*)?$")

# The parenthesised suffix: a "(...)" hard up against the end of the heading,
# with no nested parentheses, so "Gestión de Proyectos (GP)" splits into the
# name and "GP", while "Foo (GP) extra" -- code not at the end -- does not
# match and is treated as no code at all.
CODE_SUFFIX_RE = re.compile(r"\(([^()]+)\)\s*$")

# The code feeds sync_key, the identity a later task uses to decide
# update-versus-create. A code outside this charset (a stray space, a
# lowercase letter) would still produce SOME sync_key -- just a malformed
# one that isn't obviously wrong until the next sync run creates a
# duplicate row instead of matching the existing one. Reject it here,
# loudly, instead of letting it become a silent idempotency bug two tasks
# from now.
VALID_CODE_RE = re.compile(r"^[A-Z][A-Z0-9-]*$")


class SourceError(Exception):
    """A fatal, reportable defect in the source tree.

    Every raise site names the offending file. main() prints str(exc) to
    stderr and exits 1 without ever having written to stdout, so a bad sheet
    never becomes a partial dashboard.
    """


def _first_heading(path):
    """Return the first '# ' heading in path, verbatim and stripped.

    None means the file has no such heading (including being empty).
    Reading a file fails in exactly two ways at this layer: the OS won't let
    us open/read it (OSError), or the bytes are not valid UTF-8
    (UnicodeDecodeError). Both are converted here so callers only ever see
    SourceError, never a raw traceback.
    """
    try:
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                m = HEADING_RE.match(line.rstrip("\n"))
                if m and m.group(1) is not None:
                    return m.group(1).strip()
    except OSError as exc:
        raise SourceError(f"{path}: cannot read file ({exc})") from exc
    except UnicodeDecodeError as exc:
        raise SourceError(f"{path}: not valid UTF-8 ({exc})") from exc
    return None


def _parse_area_sheet(path):
    """Return (name, code) for one process sheet, or raise SourceError."""
    heading = _first_heading(path)
    if heading is None:
        raise SourceError(f"{path}: no '# ' heading found")
    m = CODE_SUFFIX_RE.search(heading)
    if not m or not m.group(1).strip():
        raise SourceError(
            f"{path}: heading {heading!r} has no parenthesised (CODE) "
            "suffix")
    code = m.group(1).strip()
    if not VALID_CODE_RE.fullmatch(code):
        raise SourceError(
            f"{path}: heading {heading!r} has code {code!r}, which is not "
            "uppercase letters/digits/hyphens starting with a letter "
            "([A-Z][A-Z0-9-]*)")
    return heading, code


def areas(source_dir):
    """Parse every *.md in source_dir into one Areas row per sheet."""
    paths = sorted(Path(source_dir).glob("*.md"))
    if not paths:
        raise SourceError(f"{source_dir}: no .md files found")
    rows = []
    seen_keys = {}
    for path in paths:
        name, code = _parse_area_sheet(path)
        sync_key = f"area:process:{code.lower()}"
        if sync_key in seen_keys:
            raise SourceError(
                f"{path}: sync_key {sync_key!r} duplicates "
                f"{seen_keys[sync_key]} (code {code!r} is not unique)")
        seen_keys[sync_key] = path
        rows.append({
            "sync_key": sync_key,
            "base": "Areas",
            "source": os.path.abspath(path),
            "props": {"Name": name, "Código": code.upper()},
        })
    return rows


# An H2 epic heading in the BHAG doc: "## Épico 3 — Project Name: ...". The
# em dash is literal (U+2014), not a hyphen -- the file uses it consistently
# as the separator between the number and the name.
EPIC_HEADING_RE = re.compile(r"^##[ \t]+Épico[ \t]+(\d+)[ \t]+—[ \t]+(.*)$")

# "**Se demuestra:** <whatever follows>" -- the per-epic line events() reads.
SE_DEMUESTRA_RE = re.compile(r"^\*\*Se demuestra:\*\*[ \t]*(.*)$")

# A GFM checklist item: "- [x] text" or "- [ ] text" (case-insensitive x).
# This is the denominator for Avance -- see _epic_checklist_progress below.
CHECKLIST_ITEM_RE = re.compile(r"^-[ \t]+\[([ xX])\][ \t]+\S")

# A genuinely parseable Spanish date at the START of the "Se demuestra" text,
# e.g. "6 de agosto, Foro de Rectores." or "~4 de agosto, ...". Anchored so
# prose that merely mentions a number ("Épico 3", "hábitos 8 y 10") is never
# mistaken for a date -- it has to be "<day> de <month>" right at the top.
EVENT_DATE_RE = re.compile(r"^~?(\d{1,2})[ \t]+de[ \t]+([A-Za-zÁÉÍÓÚáéíóúÑñ]+)")

MESES_ES = {
    "enero": 1, "febrero": 2, "marzo": 3, "abril": 4, "mayo": 5, "junio": 6,
    "julio": 7, "agosto": 8, "septiembre": 9, "octubre": 10,
    "noviembre": 11, "diciembre": 12,
}

# The business's own projects. They live in Notion, not the wiki -- there is
# no file to parse -- so this table IS the source, triaged by hand by the
# operator on a given date. (name, Estado, Archive). Replace this example
# list with your own business's projects, or delete the seed step in
# projects() below entirely if you have nothing that needs hand-triaging.
BUSINESS_PROJECTS_SEED = [
    ("Project Alpha", "Doing", False),
    ("Project Beta", "Doing", False),
    ("Project Gamma", "Doing", False),
    ("Project Delta", "On Hold", False),
    ("Project Epsilon", "Done", True),
    ("Project Zeta", "Done", True),
    ("Project Eta", "Done", True),
    ("Project Theta", "Done", True),
    ("Project Iota", "Done", True),
    ("Company Overall", "Doing", True),
]

# A literal marker, not a path: the seed table above has no file behind it.
# Dated so a later re-triage is traceable to when this list was current.
BUSINESS_PROJECTS_SOURCE = "business-projects:manual-triage-example"


def _slugify(name):
    """Lowercase, non-alnum runs collapsed to '-', no leading/trailing '-'."""
    return re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")


def _read_text(path):
    """Return the full text of path, converting read/decode failures to
    SourceError the same way _first_heading does."""
    try:
        with open(path, encoding="utf-8") as fh:
            return fh.read()
    except OSError as exc:
        raise SourceError(f"{path}: cannot read file ({exc})") from exc
    except UnicodeDecodeError as exc:
        raise SourceError(f"{path}: not valid UTF-8 ({exc})") from exc


def _today():
    """"Today", overridable via NOTION_SYNC_TODAY (YYYY-MM-DD) so every
    date-threshold rule in projects() can be pinned to a fixed date in
    tests. Unset in production: main() never sets this, so a real run
    always uses the real date."""
    raw = os.environ.get(TODAY_ENV)
    if raw is None or raw.strip() == "":
        return datetime.date.today()
    try:
        return datetime.date.fromisoformat(raw.strip())
    except ValueError as exc:
        raise SourceError(
            f"{TODAY_ENV}={raw!r} is not a valid ISO date (YYYY-MM-DD)"
        ) from exc


# "- **Bloqueado por:** <text...>", the per-repo status file's blocker
# field. Anchored to a bullet ("- **") like every other field in that fixed
# format (see wiki/status/TEMPLATE.md), so this never matches "**Bloqueado
# por:**" appearing mid-prose in an unrelated section.
BLOQUEADO_START_RE = re.compile(r"^-\s*\*\*Bloqueado por:\*\*\s*(.*)$")

# Any bullet-field heading ("- **Siguiente paso:**", "- **Lecciones
# recientes:**", ...) -- where a captured "Bloqueado por:" field's
# continuation lines stop, since the field can span multiple wrapped lines
# with no delimiter of its own.
BULLET_FIELD_RE = re.compile(r"^-\s*\*\*")

# Any ISO date appearing anywhere in a status file -- evidence of when the
# file was last meaningfully touched. Not anchored to a particular bullet:
# dates show up in prose ("(2026-07-22)"), in PR links, in rama names ARE
# NOT dates (branch names use "-0722-2318" suffixes, not "2026-07-22"
# shaped), so this is deliberately the strict YYYY-MM-DD shape only.
STATUS_DATE_RE = re.compile(r"\b(\d{4})-(\d{2})-(\d{2})\b")


def _parse_status_file(path):
    """Return (blocked_reason, evidence_dates) for one
    ~/dev/wiki/status/<repo>.md file.

    blocked_reason is None when the "**Bloqueado por:**" field is absent
    entirely (a malformed/incomplete status file -- treated the same as an
    explicit "nada", never a crash) or when its text begins with "nada"
    (case-insensitive) -- the wiki's own convention, see TEMPLATE.md.
    Otherwise it is the field's full text, verbatim, with wrapped
    continuation lines rejoined with a single space, running until the
    next "- **" bullet or end of file. A field present but literally empty
    (no "nada", no real text either) is a malformed status file and raises
    SourceError -- invariant 5 (a blocked epic always has a non-empty
    reason) must be impossible to violate by construction, not merely
    unlikely, so this is where that gets enforced.

    evidence_dates is every well-formed calendar date found anywhere in the
    file, oldest-first-or-not (callers take max()); a date-shaped substring
    that isn't a real calendar day (e.g. a stray "2026-13-40") is skipped,
    never raised -- this is health-check evidence, not identity data.
    """
    text = _read_text(path)
    buf = []
    capturing = False
    for line in text.splitlines():
        stripped = line.strip()
        if capturing:
            if BULLET_FIELD_RE.match(stripped):
                capturing = False
            else:
                buf.append(stripped)
                continue
        m = BLOQUEADO_START_RE.match(stripped)
        if m:
            buf = [m.group(1).strip()]
            capturing = True

    if not buf:
        blocked_reason = None  # no "Bloqueado por:" field at all
    else:
        raw = " ".join(part for part in buf if part).strip()
        if raw == "":
            raise SourceError(
                f"{path}: 'Bloqueado por:' field is present but empty -- "
                "must be either 'nada' or a real reason")
        blocked_reason = None if raw.lower().startswith("nada") else raw

    evidence_dates = []
    for m in STATUS_DATE_RE.finditer(text):
        y, mo, d = int(m.group(1)), int(m.group(2)), int(m.group(3))
        try:
            evidence_dates.append(datetime.date(y, mo, d))
        except ValueError:
            continue  # date-shaped substring, not a real calendar day
    return blocked_reason, evidence_dates


def _committed_date_or_none(raw, year):
    """The date a '**Se demuestra:**' line commits to, or None.

    Deliberately never raises: events() (the subcommand whose one job is
    this parsing) already validates the same text loudly when it runs.
    projects() runs independently and must not let an unrelated malformed
    date (or a missing year) take down the whole dashboard over a field
    that, for 6 of 8 epics today, isn't even a date to begin with -- "we
    don't know when this commits" is exactly the null-better-than-fabricated
    case, not an error.
    """
    if raw is None or year is None:
        return None
    m = EVENT_DATE_RE.match(raw)
    if not m:
        return None
    month = MESES_ES.get(m.group(2).lower())
    if month is None:
        return None
    day = int(m.group(1))
    try:
        return datetime.date(year, month, day)
    except ValueError:
        return None


def _epic_marked_complete(_n):
    """Whether epic _n is recorded as having already happened/shipped, for
    rule 1's second clause ("a committed date that has passed AND the epic
    is not recorded as complete").

    Always False today: none of this parser's sources -- the BHAG doc, the
    per-repo status files -- record demo completion anywhere. That is a
    verified fact about the repo right now, not an assumption: nothing marks
    whether a given epic's demo happened. Kept
    as a real function taking the epic number, rather than inlining `False`
    at the call site, so the day some source DOES record completion, this
    is the one place that has to change -- and so a reader sees this was a
    deliberate call, not a forgotten TODO.
    """
    return False


def _parse_bhag(path):
    """Parse the BHAG doc once for projects(), goals(), and events().

    Returns a dict: title (the file's own '# ' heading), epics (a list of
    (n, name) in file order), se_demuestra (n -> the raw text after
    "**Se demuestra:**" for that epic), year (the calendar year, read from
    the file's own first ISO date rather than hardcoded -- the epic dates
    have no year in the text, but the file's intro note does).

    Raises SourceError if there are no epic headings, if the epic numbers
    are not exactly a contiguous 1..N with no gaps or duplicates (the epic
    count is data, never assumed to be any particular number), or if no
    ISO date is present anywhere to establish the year.
    """
    text = _read_text(path)
    lines = text.splitlines()

    title = None
    for line in lines:
        m = HEADING_RE.match(line)
        if m and m.group(1) is not None:
            title = m.group(1).strip()
            break
    if title is None:
        raise SourceError(f"{path}: no '# ' title heading found")

    epics = []
    se_demuestra = {}
    checklist = {}  # epic number -> [checked, total]
    current = None
    for line in lines:
        m = EPIC_HEADING_RE.match(line)
        if m:
            current = int(m.group(1))
            epics.append((current, m.group(2).strip()))
            continue
        m = SE_DEMUESTRA_RE.match(line.strip())
        if m and current is not None and current not in se_demuestra:
            se_demuestra[current] = m.group(1).strip()
            continue
        m = CHECKLIST_ITEM_RE.match(line.strip())
        if m and current is not None:
            counts = checklist.setdefault(current, [0, 0])
            counts[1] += 1
            if m.group(1) in ("x", "X"):
                counts[0] += 1

    if not epics:
        raise SourceError(f"{path}: no '## Épico N — ...' headings found")
    numbers = [n for n, _ in epics]
    if len(set(numbers)) != len(numbers):
        raise SourceError(
            f"{path}: duplicate epic numbers found: {sorted(numbers)}")
    expected = list(range(1, len(epics) + 1))
    if sorted(numbers) != expected:
        raise SourceError(
            f"{path}: epic numbers {sorted(numbers)} are not contiguous "
            f"from 1 with no gaps (expected {expected})")

    # Year is lazily required: only events() needs it (to complete a day+
    # month into an ISO date), so projects()/goals() fixtures that don't
    # care about dates aren't forced to carry an unrelated ISO date too.
    year_m = re.search(r"\b(20\d{2})-\d{2}-\d{2}\b", text)
    year = int(year_m.group(1)) if year_m else None

    return {
        "title": title,
        "epics": epics,
        "se_demuestra": se_demuestra,
        "checklist": checklist,
        "year": year,
    }


def _epic_avance(checklist, epic_num):
    """Avance percentage for one epic, or None if it has no checklist yet.

    None (absent), never 0 or a guess: an epic whose Incluye: is still prose,
    not itemised, has an UNKNOWN percentage, not a zero percentage -- and a
    percentage that is really "we don't know" is worse than no column at
    all. Only an itemised epic with zero items checked gets a real 0.
    """
    counts = checklist.get(epic_num)
    if not counts or counts[1] == 0:
        return None
    checked, total = counts
    return round(100 * checked / total)


def projects(bhag_path):
    """Business projects (seeded, no file) + devbrain epics (parsed, each
    carrying a traffic-light Semáforo/Bloqueado/Motivo del semáforo -- see
    _epic_semaforo_fields) + one row per repo with an active blocker that
    maps to no epic at all: a real blocker must never silently vanish from
    the board just because the repo-to-epic mapping hasn't caught up with it.

    `Avance` comes ONLY from GFM checklist items (`- [x]` / `- [ ]`) under an
    epic's own `**Incluye:**` list in the BHAG file -- never a number this
    script invents. An epic whose list is still prose, not itemised, gets no
    `Avance` property at all (see _epic_avance): absent, not zero, because
    "we don't know" is not "0%".
    """
    rows = []
    seen = {}

    for name, estado, archive in BUSINESS_PROJECTS_SEED:
        sync_key = f"project:business:{_slugify(name)}"
        if sync_key in seen:
            raise SourceError(
                f"BUSINESS_PROJECTS_SEED: sync_key {sync_key!r} duplicates "
                f"{seen[sync_key]} -- two seed names slugify the same")
        seen[sync_key] = f"seed row {name!r}"
        rows.append({
            "sync_key": sync_key,
            "base": "Projects",
            "source": BUSINESS_PROJECTS_SOURCE,
            "props": {
                "Name": name,
                "Estado": estado,
                "Archive": archive,
                "Tipo": "Business",
            },
        })

    data = _parse_bhag(bhag_path)
    queue_dir = _resolve_source("tasks")
    status_dir = os.environ.get(STATUS_DIR_ENV, STATUS_DIR_DEFAULT)
    today = _today()
    epic_repos = _epic_repos(queue_dir)

    for n, name in data["epics"]:
        sync_key = f"project:devbrain:epic-{n}"
        if sync_key in seen:
            raise SourceError(
                f"{bhag_path}: sync_key {sync_key!r} duplicates "
                f"{seen[sync_key]}")
        seen[sync_key] = f"epic {n}"
        repos = epic_repos.get(n, [])
        committed_date = _committed_date_or_none(
            data["se_demuestra"].get(n), data["year"])
        semaforo, bloqueado, motivo = _epic_semaforo_fields(
            repos, status_dir, today, committed_date,
            _epic_marked_complete(n))
        props = {
            "Name": name, "Tipo": "devbrain",
            "Semáforo": semaforo, "Bloqueado": bloqueado,
        }
        if motivo is not None:
            props["Motivo del semáforo"] = motivo
        avance = _epic_avance(data["checklist"], n)
        if avance is not None:
            props["Avance"] = avance
        rows.append({
            "sync_key": sync_key,
            "base": "Projects",
            "source": os.path.abspath(bhag_path),
            "props": props,
        })

    mapped_repos = {repo for repos in epic_repos.values() for repo in repos}
    for status_path in sorted(Path(status_dir).glob("*.md")):
        repo = status_path.stem
        if repo == "TEMPLATE" or repo in mapped_repos:
            continue
        reason, _dates = _parse_status_file(status_path)
        if reason is None:
            continue  # unmapped but not blocked -- nothing worth a row for
        sync_key = f"project:devbrain-unmapped:{repo}"
        if sync_key in seen:
            raise SourceError(
                f"{status_path}: sync_key {sync_key!r} duplicates "
                f"{seen[sync_key]}")
        seen[sync_key] = f"unmapped blocker {repo}"
        rows.append({
            "sync_key": sync_key,
            "base": "Projects",
            "source": os.path.abspath(status_path),
            "props": {
                "Name": f"Bloqueador sin épico: {repo}",
                "Tipo": "devbrain-unmapped",
                "Semáforo": "🔴",
                "Bloqueado": True,
                "Motivo del semáforo": reason,
            },
        })
    return rows


# The business's own BHAG lives only in a Drive doc (equity figures, real
# person names -- this repo has a GitHub remote, so it never gets checked
# in here). This is a literal marker, same pattern as BUSINESS_PROJECTS_SOURCE:
# there is no file this parser can read, on purpose.
BUSINESS_BHAG_SOURCE = "drive:business-bhag"


def goals(bhag_path):
    """Two BHAGs (system + business) plus one goal row per devbrain epic."""
    data = _parse_bhag(bhag_path)
    rows = [
        {
            "sync_key": "goal:devbrain:bhag",
            "base": "Goals",
            "source": os.path.abspath(bhag_path),
            "props": {"Name": data["title"], "Estado": "ratificado"},
        },
        {
            # No figures, no person's name: the owners haven't ratified this
            # BHAG, so a dashboard row marks it a draft rather than implying
            # otherwise -- and since its real source is Drive-only, this row
            # can never carry the equity numbers or names that document
            # holds.
            "sync_key": "goal:business:bhag",
            "base": "Goals",
            "source": BUSINESS_BHAG_SOURCE,
            "props": {"Name": "BHAG de la empresa", "Estado": "borrador"},
        },
    ]
    seen = {r["sync_key"]: "fixed goal row" for r in rows}
    for n, name in data["epics"]:
        sync_key = f"goal:devbrain:epic-{n}"
        if sync_key in seen:
            raise SourceError(
                f"{bhag_path}: sync_key {sync_key!r} duplicates "
                f"{seen[sync_key]}")
        seen[sync_key] = f"epic {n}"
        rows.append({
            "sync_key": sync_key,
            "base": "Goals",
            "source": os.path.abspath(bhag_path),
            "props": {"Name": name, "Nivel": "meta anual"},
        })
    return rows


def events(bhag_path):
    """One row per epic whose '**Se demuestra:**' line is a real date.

    Never guesses: most of today's lines say things like "sin fecha fija
    todavía" or "indirectamente" -- those epics emit no row at all, on
    purpose. The count of date-vs-non-date lines is never assumed; it is
    read fresh from the file every run. A fabricated commitment date is
    worse than an absent one.
    """
    data = _parse_bhag(bhag_path)
    rows = []
    seen = {}
    for n, name in data["epics"]:
        raw = data["se_demuestra"].get(n)
        if raw is None:
            raise SourceError(
                f"{bhag_path}: Épico {n} has no '**Se demuestra:**' line")
        m = EVENT_DATE_RE.match(raw)
        if not m:
            continue  # not genuinely a date -- no row, never a guess
        month = MESES_ES.get(m.group(2).lower())
        if month is None:
            continue  # "<N> de <not-a-month>" -- a false-positive match, skip
        if data["year"] is None:
            raise SourceError(
                f"{bhag_path}: Épico {n} has a parseable date ({raw!r}) "
                "but the file has no ISO date anywhere to establish the "
                "year")
        day = int(m.group(1))
        try:
            datetime.date(data["year"], month, day)
        except ValueError as exc:
            raise SourceError(
                f"{bhag_path}: Épico {n} '**Se demuestra:**' text {raw!r} "
                f"looks like a date but is not a valid calendar date "
                f"({exc})") from exc
        iso = f"{data['year']:04d}-{month:02d}-{day:02d}"
        slug = f"epic-{n}"
        sync_key = f"event:{iso}:{slug}"
        if sync_key in seen:
            raise SourceError(
                f"{bhag_path}: sync_key {sync_key!r} duplicates "
                f"{seen[sync_key]}")
        seen[sync_key] = f"epic {n}"
        rows.append({
            "sync_key": sync_key,
            "base": "Events",
            "source": os.path.abspath(bhag_path),
            "props": {"Fecha": iso, "Name": f"Épico {n} — {name}"},
        })
    return rows


# Repo -> devbrain epic, for queue files that don't say epic: themselves.
#
# This mapping is business-specific taxonomy (which of YOUR repos belongs to
# which of YOUR roadmap epics) and has no generic default worth hardcoding
# here. Instead it is loaded, if present, from an OPTIONAL external JSON
# config file -- gitignored, absent by default -- so this feature degrades
# gracefully rather than requiring configuration: with no config file, no
# repo has an entry, and _resolve_epic() simply omits the Epic property for
# such rows (see _resolve_epic) instead of raising. A per-file 'epic:'
# frontmatter override still works either way, config file or not.
# Repo-root-relative, same convention as bin/notion-api's own lib/ lookup
# (realpath, not abspath, so a symlink on PATH still resolves correctly) --
# and matching where the repo's .gitignore already expects this optional
# file to live (see .gitignore's "notion-repo-epics.json" entry).
REPO_EPIC_CONFIG_FILE = os.environ.get(
    "NOTION_SYNC_REPO_EPIC_FILE",
    os.path.join(os.path.dirname(os.path.realpath(__file__)),
                 "..", "notion-repo-epics.json"))


def _load_repo_epic_map():
    """{repo: epic_number} from REPO_EPIC_CONFIG_FILE, or {} when the file is
    missing, unreadable, not valid JSON, or not a JSON object -- any of
    those just means "no mapping configured", never a crash. Non-integer
    values are skipped individually rather than failing the whole file, on
    the theory that a typo in one entry shouldn't take down every other
    repo's mapping."""
    try:
        with open(REPO_EPIC_CONFIG_FILE, encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, json.JSONDecodeError):
        return {}
    if not isinstance(data, dict):
        return {}
    mapping = {}
    for repo, epic in data.items():
        try:
            mapping[str(repo)] = int(epic)
        except (TypeError, ValueError):
            continue
    return mapping


REPO_EPIC = _load_repo_epic_map()

# A single 'key: value' line inside a frontmatter block.
FRONTMATTER_LINE_RE = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*):[ \t]?(.*)$")

# Any ATX heading, any level ("#" through "######"), for skipping past a
# heading in the body to find the first line of actual prose. Deliberately
# broader than HEADING_RE (which is H1-only, for wiki files) -- plan bodies
# use "## Tarea solicitada" / "## Contexto" freely and none of that is the
# title.
BODY_HEADING_RE = re.compile(r"^#{1,6}[ \t]")


def _parse_frontmatter(path):
    """Return (fm, body_lines) for one queue file.

    fm mirrors lib/queue.sh's fm_get: the dict of single-line 'key: value'
    frontmatter keys between the first two '---' lines. Multi-line values
    (folded scalars, lists) are out of scope -- none of the keys this
    parser reads (repo, status, prioridad, epic, pr) ever use them in this
    queue. body_lines is everything after the closing '---', for Name to
    scan.
    """
    try:
        with open(path, encoding="utf-8") as fh:
            lines = fh.read().splitlines()
    except OSError as exc:
        raise SourceError(f"{path}: cannot read file ({exc})") from exc
    except UnicodeDecodeError as exc:
        raise SourceError(f"{path}: not valid UTF-8 ({exc})") from exc
    if not lines or lines[0] != "---":
        raise SourceError(
            f"{path}: no frontmatter block (file must start with '---')")
    fm = {}
    closed = False
    body_start = None
    for i, line in enumerate(lines[1:], start=1):
        if line == "---":
            closed = True
            body_start = i + 1
            break
        m = FRONTMATTER_LINE_RE.match(line)
        if m:
            fm[m.group(1)] = m.group(2)
    if not closed:
        raise SourceError(
            f"{path}: frontmatter block never closes (no second '---')")
    return fm, lines[body_start:]


def _first_prose_line(path, body_lines):
    """Return the first non-empty, non-heading line of body_lines, verbatim
    (only the newline and outer whitespace stripped -- never truncated),
    or raise SourceError naming path if the body has no such line.

    This is the ONLY field in the whole parser sourced from body prose
    rather than a heading, a filename, or a frontmatter key -- the
    redaction gate (a separate layer, not duplicated here) runs over rows
    downstream precisely because prose, unlike a heading or a frontmatter
    key, is where a person's name could appear.
    """
    for line in body_lines:
        stripped = line.strip()
        if not stripped:
            continue
        if BODY_HEADING_RE.match(line):
            continue
        return stripped
    raise SourceError(
        f"{path}: no non-empty, non-heading line found in the body to use "
        "as Name -- every plan file needs real prose for its title, and "
        "fabricating one (e.g. from sync_key) is exactly what this field "
        "replaces")


def _resolve_epic(path, repo, fm):
    """Resolve props["Epic"] for one queue file, or None if it has none.

    Order: (1) the file's own 'epic:' key, if present -- this is what makes
    a repo that maps to more than one epic resolvable per-file. (2) the
    (optional) REPO_EPIC mapping, loaded from an external config file if one
    is configured -- see _load_repo_epic_map. (3) anything else gets no Epic
    property at all: absent, not a fabricated number, and NOT a hard error --
    REPO_EPIC is an optional feature, most users of this starter kit will
    never configure it, so a repo with no entry anywhere must be a normal,
    working state, never a parse failure.
    """
    raw = fm.get("epic")
    if raw is not None and raw.strip() != "":
        try:
            return int(raw.strip())
        except ValueError as exc:
            raise SourceError(
                f"{path}: epic {raw!r} is not an integer") from exc
    return REPO_EPIC.get(repo)


def _epic_repos(queue_dir):
    """Epic number -> sorted list of repos, for projects()'s traffic light.

    The one-to-many inverse of _resolve_epic/REPO_EPIC -- deliberately NOT
    a second hardcoded table (that could drift from the one tasks() already
    uses). It calls the exact same resolution every queue file already goes
    through: a repo with NO entry in the (optional) REPO_EPIC mapping still
    contributes an edge here whenever its queue files carry their own
    'epic:' override -- so this reproduces the real per-file overrides from
    the actual queue data, not from a second table naming them.

    Raises SourceError the same way tasks() does for an empty/misconfigured
    queue_dir -- a typo'd env var silently producing "no repos for any
    epic" would make every epic evaluate as if none of its repos had ever
    been touched, exactly the kind of silent-looks-fine failure the rest of
    this parser refuses to produce.
    """
    paths = sorted(Path(queue_dir).glob("*.plan.md"))
    if not paths:
        raise SourceError(f"{queue_dir}: no *.plan.md files found")
    mapping = {}
    for path in paths:
        fm, _ = _parse_frontmatter(path)
        repo = fm.get("repo")
        if not repo:
            raise SourceError(f"{path}: frontmatter has no 'repo:' key")
        epic = _resolve_epic(path, repo, fm)
        if epic is not None:
            mapping.setdefault(epic, set()).add(repo)
    return {n: sorted(repos) for n, repos in mapping.items()}


def _epic_semaforo_fields(repos, status_dir, today, committed_date, complete):
    """(Semáforo, Bloqueado, Motivo-del-semáforo-or-None) for one epic.

    Implements the brief's rules in order, first match wins:
      1. red   -- any mapped repo has an active blocker, OR the committed
                  date has passed and the epic isn't recorded complete.
      2. yellow-- no blocker, and the newest evidence is >7 days old, or
                  there is no evidence at all.
      3. green -- no blocker, and the newest evidence is <=7 days old.

    `Bloqueado` tracks ONLY a real, active repo blocker (rule 1's first
    clause) -- an epic that is red purely because its date passed is
    Bloqueado=False, matching the brief's own framing that such an epic
    "has no blocker".

    `Motivo del semáforo` -- renamed from an earlier `Motivo del bloqueo`
    once the original wording ("absent when not blocked") turned out to be
    logically incompatible with the epic-7 case: yellow, unblocked, no
    status file, and still required to explain itself. The field is now
    "why the light is what it is": present for every 🔴 or 🟡, absent only
    for 🟢 (green needs no explanation). `Bloqueado` keeps its narrow scope
    regardless -- a yellow epic can carry a reason without claiming to be
    blocked.
    """
    blocked = []
    evidence_dates = []
    missing_files = []
    dateless_files = []
    for repo in repos:
        path = os.path.join(status_dir, f"{repo}.md")
        if not os.path.exists(path):
            missing_files.append(repo)
            continue
        reason, dates = _parse_status_file(path)
        if reason is not None:
            blocked.append((repo, reason))
        if dates:
            evidence_dates.extend(dates)
        else:
            dateless_files.append(repo)

    newest = max(evidence_dates) if evidence_dates else None
    date_passed = (committed_date is not None and committed_date < today
                   and not complete)
    bloqueado = len(blocked) > 0

    if bloqueado or date_passed:
        semaforo = "🔴"
    elif newest is None:
        semaforo = "🟡"
    elif (today - newest).days > EVIDENCE_STALE_DAYS:
        semaforo = "🟡"
    else:
        semaforo = "🟢"

    if semaforo == "🟢":
        # Green needs no explanation -- the one case where the field is
        # absent, regardless of what produced the green.
        motivo = None
    elif bloqueado:
        motivo = "; ".join(f"{repo}: {reason}" for repo, reason in blocked)
    elif date_passed:
        motivo = (f"Fecha comprometida ({committed_date.isoformat()}) ya "
                  "pasó y no se registra como completada.")
    elif newest is None:
        if not repos:
            detail = "no hay repos mapeados a este épico"
        elif missing_files and dateless_files:
            detail = ("sin archivo de status: " + ", ".join(missing_files)
                       + "; sin fecha reconocible: "
                       + ", ".join(dateless_files))
        elif missing_files:
            detail = ("no existe archivo de status para "
                       + ", ".join(missing_files))
        else:
            detail = ("ningún archivo de status tiene una fecha "
                       "reconocible (" + ", ".join(dateless_files) + ")")
        motivo = f"Sin evidencia: {detail}."
    else:
        # Merely stale: evidence exists, it's just older than the
        # threshold -- named explicitly so it never gets confused with the
        # "no evidence at all" case above, which is also yellow.
        days_old = (today - newest).days
        motivo = (f"Evidencia más reciente: {newest.isoformat()} "
                  f"(hace {days_old} días, más de {EVIDENCE_STALE_DAYS}).")

    return semaforo, bloqueado, motivo


def tasks(queue_dir):
    """One row per ~/dev/queue/*.plan.md file."""
    paths = sorted(Path(queue_dir).glob("*.plan.md"))
    if not paths:
        raise SourceError(f"{queue_dir}: no *.plan.md files found")
    rows = []
    seen = {}
    for path in paths:
        fm, body_lines = _parse_frontmatter(path)
        repo = fm.get("repo")
        status = fm.get("status")
        prioridad_raw = fm.get("prioridad")
        if not repo:
            raise SourceError(f"{path}: frontmatter has no 'repo:' key")
        if not status:
            raise SourceError(f"{path}: frontmatter has no 'status:' key")
        if prioridad_raw is None or prioridad_raw.strip() == "":
            raise SourceError(f"{path}: frontmatter has no 'prioridad:' key")
        try:
            prioridad = int(prioridad_raw.strip())
        except ValueError as exc:
            raise SourceError(
                f"{path}: prioridad {prioridad_raw!r} is not an integer"
            ) from exc

        name = _first_prose_line(path, body_lines)

        epic = _resolve_epic(path, repo, fm)

        pr_raw = fm.get("pr")
        pr = pr_raw.strip() if pr_raw is not None and pr_raw.strip() else None

        stem = path.name[:-len(".plan.md")]
        sync_key = f"task:queue:{stem}"
        if sync_key in seen:
            raise SourceError(
                f"{path}: sync_key {sync_key!r} duplicates {seen[sync_key]}")
        seen[sync_key] = path

        props = {
            "Name": name, "Repo": repo, "Estado": status,
            "Prioridad": prioridad, "Tipo": "tarea",
        }
        if epic is not None:
            props["Epic"] = epic
        if pr is not None:
            props["PR"] = pr
        rows.append({
            "sync_key": sync_key,
            "base": "Tasks",
            "source": os.path.abspath(path),
            "props": props,
        })
    return rows


def _first_paragraph(path):
    """First real paragraph of body text -- skips the H1, any heading, and
    blank lines, then collects the run of text lines up to the next blank
    line or heading. None if the file has no body paragraph at all (a
    heading-only file, or empty) -- resources() must not emit an empty
    Description string for that case, only omit the key.
    """
    try:
        with open(path, encoding="utf-8") as fh:
            lines = fh.read().splitlines()
    except OSError as exc:
        raise SourceError(f"{path}: cannot read file ({exc})") from exc
    except UnicodeDecodeError as exc:
        raise SourceError(f"{path}: not valid UTF-8 ({exc})") from exc
    para = []
    for line in lines:
        stripped = line.strip()
        if not stripped or BODY_HEADING_RE.match(line):
            if para:
                break
            continue
        para.append(stripped)
    return " ".join(para) if para else None


def resources(services_dir):
    """One row per ~/dev/wiki/services/*.md file.

    Unlike areas(), a page with no '# ' heading is not an error here -- it
    falls back to the filename, since a service page's whole point is to
    exist and be findable even before someone writes a proper title.
    """
    paths = sorted(Path(services_dir).glob("*.md"))
    if not paths:
        raise SourceError(f"{services_dir}: no .md files found")
    rows = []
    seen = {}
    for path in paths:
        heading = _first_heading(path)  # None means "no heading", not fatal
        stem = path.stem
        name = heading if heading is not None else stem
        sync_key = f"resource:service:{stem}"
        if sync_key in seen:
            raise SourceError(
                f"{path}: sync_key {sync_key!r} duplicates {seen[sync_key]}")
        seen[sync_key] = path
        props = {
            "Name": name,
            "Categoría": "servicio",
            "Tags": [stem],
            # Every row here is documentation this machine wrote about its own
            # services -- Type and Area are fixed facts about that, not a
            # per-file guess.
            "Type": "Wiki interno",
            "Area": "Infraestructura Técnica (IT)",
            "URL": f"https://github.com/{GITHUB_WIKI_REPO}/blob/main/services/{path.name}",
        }
        description = _first_paragraph(path)
        if description is not None:
            props["Description"] = description
        rows.append({
            "sync_key": sync_key,
            "base": "Resources",
            "source": os.path.abspath(path),
            "props": props,
        })
    return rows


TEMPLATE_LABELS = {"portfolio_review": "Portfolio Review", "generica": "Genérica"}


def meetings(snapshot_path):
    """One row per meeting in the devbrain-minutas-sync snapshot -- a local
    JSON file, never a live Calendar/Drive call, so this script stays a
    pure function of the filesystem exactly as its own module docstring
    promises.

    A missing snapshot is NOT an error: it means the subsystem is off
    (NOTION_SYNC_MINUTAS_ENABLED unset) or has not run yet today, both
    legitimate states -- unlike areas()/resources(), whose source
    directories are expected to always exist in a working checkout.
    """
    if not os.path.isfile(snapshot_path):
        return []
    try:
        with open(snapshot_path, encoding="utf-8") as fh:
            entries = json.load(fh)
    except (OSError, json.JSONDecodeError) as exc:
        raise SourceError(f"{snapshot_path}: cannot read snapshot ({exc})") from exc

    rows = []
    seen = {}
    for entry in entries:
        event_id = entry.get("event_id")
        if not event_id:
            raise SourceError(f"{snapshot_path}: an entry has no event_id")
        sync_key = f"meeting:{event_id}"
        if sync_key in seen:
            raise SourceError(
                f"{snapshot_path}: sync_key {sync_key!r} duplicates "
                f"{seen[sync_key]!r} -- the snapshot has the same event twice")
        seen[sync_key] = entry.get("title")
        template_raw = entry.get("template")
        props = {
            "Name": entry.get("title", "(sin título)"),
            "Estado": entry.get("estado", "Sin minuta"),
            "Plantilla": TEMPLATE_LABELS.get(template_raw, template_raw),
        }
        start = entry.get("start")
        if start:
            props["Fecha"] = start[:10]
        if entry.get("drive_url"):
            props["URL"] = entry["drive_url"]
        rows.append({
            "sync_key": sync_key,
            "base": "Meetings",
            "source": os.path.abspath(snapshot_path),
            "props": props,
        })
    return rows


HANDLERS = {
    "areas": areas, "projects": projects, "goals": goals, "events": events,
    "tasks": tasks, "resources": resources, "meetings": meetings,
}


def _resolve_source(subcommand):
    default, env_var = SOURCES[subcommand]
    return os.environ.get(env_var, default)


def all_rows():
    """Every subcommand's rows, concatenated, with one extra invariant no
    single subcommand can check by itself: sync_key must be unique across
    the WHOLE combined output, not merely within each subcommand's own
    rows. Each handler already dedupes its own keys; a collision here means
    two different bases minted the identical sync_key string. That matters
    because a later task uses sync_key as the sole identity for deciding
    update-versus-create -- a cross-base collision would silently overwrite
    one base's row with another's on every sync, and a naive idempotency
    test (row count stays stable across repeated runs) would report that
    as passing.
    """
    rows = []
    seen = {}
    for name in sorted(HANDLERS):
        for row in HANDLERS[name](_resolve_source(name)):
            key = row["sync_key"]
            if key in seen:
                raise SourceError(
                    f"sync_key {key!r} collides across subcommands: "
                    f"{seen[key]!r} and {name!r} both produced it")
            seen[key] = name
            rows.append(row)
    return rows


def main(argv):
    names = sorted(HANDLERS) + ["all"]
    if len(argv) != 2 or argv[1] not in names:
        print(f"usage: {os.path.basename(argv[0])} <{', '.join(names)}>",
              file=sys.stderr)
        return 2
    subcommand = argv[1]
    try:
        if subcommand == "all":
            rows = all_rows()
        else:
            rows = HANDLERS[subcommand](_resolve_source(subcommand))
    except SourceError as exc:
        print(f"notion-sync-sources: {exc}", file=sys.stderr)
        return 1
    print(json.dumps(rows, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

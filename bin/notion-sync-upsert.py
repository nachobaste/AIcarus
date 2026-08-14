#!/usr/bin/env python3
"""notion-sync-upsert.py — the whole upsert loop in one process.

Bash (bin/notion-sync) does flags, secrets, classification and redaction.
This script's only job is HTTP and JSON: type each row's plain-JSON `props`
into Notion property shapes, decide create-vs-update per row, and never touch
a page's body.

Usage:
  notion-sync-upsert.py sync      --ids '<JSON object: base -> database id>' \
                                   [--dry-run] [--now YYYY-MM-DD]
      Rows (a JSON array, already classified and redacted) are read from
      stdin. One JSON summary object per base is printed to stdout as that
      base finishes: {"base":, "database_id":, "rows":, "creates":,
      "updates":, "archived":}.

  notion-sync-upsert.py bootstrap --ids '<JSON object: base -> database id>' \
                                   [--dry-run]
      Adds the four control properties (Sync Key, Fuente, Última
      sincronización, Archive) to each named database's schema, PLUS every
      content property the given rows actually carry for that base (typed by
      the same name-based mapping as `sync`), except `Name` -- already each
      base's title property, never recreated. Rows (a JSON array, same shape
      as `sync`'s) are read from stdin; an empty array means "control
      properties only" for a base with no rows in this call. Safe to re-run:
      Notion accepts re-defining a property with the same type as a no-op.
      Never touches rows themselves. Prints one JSON line per base:
      {"base":, "database_id":, "status": "ok", "properties": [name, ...]}.

      The property set is DERIVED from the rows, not from a hardcoded table:
      the first real sync died on row one with "Código is not a property
      that exists" because an earlier version of this brief listed only the
      four control properties. Deriving from the rows means a field a later
      task adds to the source parser is automatically included here too.

Idempotency, the load-bearing property: for each base this script queries
the WHOLE database once (paginated), maps existing pages by their "Sync Key"
property, and only ever POSTs a page whose sync_key is not already in that
map. A second consecutive run over unchanged input therefore issues zero
`POST /v1/pages` and exactly one `PATCH /v1/pages/<id>` per row — see
tests/test-notion-sync.sh.

Never deletes: any page in the map whose sync_key is NOT among the rows
given this run gets `Archive` set true (unless already true), never removed.
A page carrying no "Sync Key" at all (manually added, or template junk) is
invisible to this script — never read, never touched.

Never touches the page body: every write is a `properties`-only payload;
this script never calls a block-children endpoint and never sets
"children" on a page.

A row with no `Name` is a hard error, not a fabricated title: every row is
validated BEFORE any base is touched (a read or a write), so this failure
issues zero requests no matter where in the row list the bad row sits.

Exit codes (mirrors bin/notion-api's and bin/notion-ids.py's convention,
since this is a sibling CLI over the same client library):
  0  success
  1  a Notion API error (persistent non-2xx), the workspace's own data is in
     a state this script cannot reconcile (e.g. two pages share a Sync Key
     already), or a row's data violates the parser's contract (no `Name`) —
     all raised as a plain SystemExit(message), which Python reports on
     stderr at exit code 1 with no traceback, same pattern as
     bin/notion-ids.py's repeated-cursor guard.
  2  transport failure — the request never reached an HTTP status.
  3  configuration error — no token, or rows reference a base with no id
     supplied.
  4  usage — bad arguments, or stdin/--ids is not the JSON shape expected.
"""
import json
import os
import sys
from datetime import datetime, timezone

sys.path.insert(0, os.path.join(
    os.path.dirname(os.path.realpath(__file__)), "..", "lib"))

from notion_api import (NotionConfigError, NotionError,  # noqa: E402
                        NotionTransportError, call)

USAGE = ("usage: notion-sync-upsert.py {sync|bootstrap} --ids JSON "
         "[--dry-run] [--now YYYY-MM-DD]\n"
         "  sync mode reads a JSON array of rows from stdin.")

# Notion property mapping (Task 6 brief): map by field NAME, never by
# guessing from the value's Python type.
SELECT_FIELDS = {"Estado", "Tipo", "Nivel", "Categoría", "Semáforo", "Type", "Plantilla"}
DATE_FIELDS = {"Fecha"}
MULTI_SELECT_FIELDS = {"Tags"}
CHECKBOX_FIELDS = {"Archive", "Bloqueado"}
NUMBER_FIELDS = {"Prioridad", "Epic", "Avance"}
URL_FIELDS = {"PR", "URL"}
RELATION_FIELDS = {"Area"}
TITLE_FIELD = "Name"

# Plan 300 (2026-08-08 interview): a resources() row emits these so the FIRST
# sync fills them in, but a human editing one by hand in Notion afterwards
# must never be clobbered by the next run. Scoped to exactly these four names
# -- verified by grep against notion-sync-sources.py that no OTHER base's
# rows use any of them today, so this is a no-op for Areas/Projects/Goals/
# Tasks/Events, not a behaviour change.
#
# Keyed by BASE, not a single flat set of field names: a name like "Estado"
# means something different, and needs a different policy, on every base
# that has it. Meetings' "Estado" is set to "Redactada" by the on-demand
# devbrain-minuta command writing straight to Notion, and must survive the
# next scheduled sync's meetings() recompute (which only ever knows
# "Encontrada"/"Sin minuta") -- but Tasks' and Projects' own "Estado" must
# keep re-syncing from their real source on every run, so protecting
# "Estado" globally would silently break those two bases.
PROTECTED_IF_FILLED = {
    "Resources": {"Description", "Type", "Area", "URL"},
    "Meetings": {"Estado"},
}

# The four properties this sync owns on every row, regardless of base.
CONTROL_PROPERTY_SCHEMA = {
    "Sync Key": {"rich_text": {}},
    "Fuente": {"rich_text": {}},
    "Última sincronización": {"date": {}},
    "Archive": {"checkbox": {}},
}

MAX_QUERY_PAGES = 20  # mirrors bin/notion-ids.py's MAX_SEARCH_PAGES bound


def _title(value):
    return {"title": [{"text": {"content": str(value)}}]}


def _select(value):
    return {"select": {"name": str(value)}}


def _date(value):
    return {"date": {"start": str(value)}}


def _multi_select(values):
    return {"multi_select": [{"name": str(v)} for v in values]}


def _checkbox(value):
    return {"checkbox": bool(value)}


def _number(value):
    return {"number": value}


def _rich_text(value):
    return {"rich_text": [{"text": {"content": str(value)}}]}


def _url(value):
    return {"url": str(value)}


def _relation(page_id):
    return {"relation": [{"id": page_id}] if page_id else []}


def build_properties(row, now_iso, area_ids=None, existing_props=None):
    """The full `properties` payload for one row: its own fields, typed by
    name, plus the four control properties this sync owns.

    `area_ids` maps an Area's Name to its Notion page id, for resolving a
    relation field's value (a plain string in the row) to the shape Notion's
    API expects. `existing_props` is the CURRENT value of this exact page's
    protected fields (None for a brand-new page) -- a protected field already
    holding something is left out of this payload entirely, so a PATCH never
    touches it and a manual edit in Notion survives the next sync. Which
    fields are protected depends on `row["base"]` (PROTECTED_IF_FILLED is
    keyed by base): the same field NAME can mean something different on a
    different base, so protection is looked up per row, never globally.

    A row with no `Name` is a hard error naming its `sync_key`, not
    something to paper over: every Notion database needs a title, so a
    missing one means the parser's own contract (bin/notion-sync-sources.py)
    was violated. An earlier version of this fell back to `sync_key` as the
    title instead -- which kept this script unblocked but would have quietly
    written 28 rows titled things like `task:queue:110-...` and hidden the
    parser's real gap behind readable-enough output. Raised as a plain
    SystemExit, same pattern as the duplicate-Sync-Key guard below: Python
    reports it on stderr at exit 1 with no traceback.

    `PR` maps to Notion's `url` type. When a row has no PR (most queue
    plans don't), the key is simply absent from `row["props"]` -- never
    present-and-empty -- because this loop only ever emits a property for a
    key it actually finds, and Notion's url type rejects an empty string.
    """
    if TITLE_FIELD not in row["props"]:
        raise SystemExit(
            f"notion-sync-upsert: row {row['sync_key']!r} has no Name -- "
            "every Notion page needs a title, and fabricating one from the "
            "sync_key would hide a real gap in the parser's output")
    area_ids = area_ids or {}
    existing_props = existing_props or {}
    protected = PROTECTED_IF_FILLED.get(row["base"], set())
    props = {}
    for key, value in row["props"].items():
        if key == "Archive":
            continue  # handled below, once, as a control property
        # A protected field the page already has stays untouched -- never
        # even entering this payload, so a PATCH cannot overwrite a manual
        # edit. A brand-new page has no existing_props, so it is always
        # filled the first time regardless of this check. Scoped to THIS
        # row's base: "Estado" is protected on Meetings but must keep
        # re-syncing on Tasks/Projects, so the lookup is never global.
        if key in protected and existing_props.get(key):
            continue
        if key == TITLE_FIELD:
            props[key] = _title(value)
        elif key in SELECT_FIELDS:
            props[key] = _select(value)
        elif key in DATE_FIELDS:
            props[key] = _date(value)
        elif key in MULTI_SELECT_FIELDS:
            props[key] = _multi_select(value)
        elif key in CHECKBOX_FIELDS:
            props[key] = _checkbox(value)
        elif key in NUMBER_FIELDS:
            props[key] = _number(value)
        elif key in URL_FIELDS:
            props[key] = _url(value)
        elif key in RELATION_FIELDS:
            if value not in area_ids:
                raise SystemExit(
                    f"notion-sync-upsert: row {row['sync_key']!r} references "
                    f"Area {value!r}, which does not exist in the Areas "
                    "database -- refusing to write an empty or guessed "
                    "relation")
            props[key] = _relation(area_ids[value])
        else:
            props[key] = _rich_text(value)
    props["Sync Key"] = _rich_text(row["sync_key"])
    props["Fuente"] = _rich_text(row["source"])
    props["Última sincronización"] = _date(now_iso)
    props["Archive"] = _checkbox(row["props"].get("Archive", False))
    return props


def _sync_key_of(page):
    """A page's "Sync Key" rich_text property, concatenated and stripped of
    None runs the same defensive way bin/notion-ids.py reads a title."""
    runs = (page.get("properties", {}).get("Sync Key", {}).get("rich_text")
            or [])
    return "".join((r.get("plain_text") or "") for r in runs)


def _archive_of(page):
    return bool(page.get("properties", {}).get("Archive", {}).get("checkbox"))


def _title_of(page, key="Name"):
    runs = (page.get("properties", {}).get(key, {}).get("title") or [])
    return "".join((r.get("plain_text") or "") for r in runs)


def _all_protected_names():
    """Every field name protected on ANY base -- the union of PROTECTED_IF_
    FILLED's values, not just one base's set. list_existing() queries a
    single base's database but stores its result once per page; reading the
    union here (instead of threading a base name through list_existing just
    for this) keeps that function about pagination, not policy. Reading a
    field's current value that happens not to be protected FOR THIS page's
    base is harmless -- build_properties only ever consults it through
    PROTECTED_IF_FILLED.get(row["base"], set()), so an extra entry here is
    simply never looked at for a base that doesn't protect that name."""
    names = set()
    for names_for_base in PROTECTED_IF_FILLED.values():
        names |= names_for_base
    return names


def _read_typed_prop(props, key):
    """`key`'s current value from an already-fetched page's `properties`,
    read by the SAME name-based type mapping build_properties writes with --
    one source of truth for "what shape is this field", same principle as
    _schema_shape_for. Returns a value whose truthiness alone answers
    "already has something, or empty": a joined string, a select's name (or
    ""), a bool for multi_select/checkbox/relation, a number (or None), or a
    url (or "") -- exactly what build_properties' existing_props.get(key)
    check needs, nothing more.
    """
    value = props.get(key, {})
    if key in SELECT_FIELDS:
        return (value.get("select") or {}).get("name") or ""
    if key in DATE_FIELDS:
        return (value.get("date") or {}).get("start") or ""
    if key in MULTI_SELECT_FIELDS:
        return bool(value.get("multi_select") or [])
    if key in CHECKBOX_FIELDS:
        return bool(value.get("checkbox"))
    if key in NUMBER_FIELDS:
        return value.get("number")
    if key in URL_FIELDS:
        return value.get("url") or ""
    if key in RELATION_FIELDS:
        return bool(value.get("relation") or [])
    # Default: rich_text, matching how _rich_text() writes and how
    # _sync_key_of()/_title_of() already read the same shape elsewhere.
    return "".join((r.get("plain_text") or "") for r in (value.get("rich_text") or []))


def _protected_props_of(page):
    """Current values of every PROTECTED_IF_FILLED field (across all bases)
    on an existing page, so build_properties can tell "empty, fill it" from
    "already has something, leave it alone." Reads by exact type, matching
    how each is WRITTEN -- a page fetched from a real Notion query already
    has this shape, no extra request needed. Which of these keys actually
    matters for THIS page's base is decided later, in build_properties, via
    PROTECTED_IF_FILLED.get(row["base"], set()) -- this function only reads,
    never filters by base."""
    props = page.get("properties", {})
    return {name: _read_typed_prop(props, name) for name in _all_protected_names()}


def list_existing(base_id):
    """Every page in base_id's database that carries a non-empty Sync Key,
    as {sync_key: {"page_id":, "archived": bool}}.

    Pages with no Sync Key (manually added, or leftover template junk) are
    silently excluded from the map -- never read further, never written to.
    Paginated with the same bounded, repeated-cursor-proof loop as
    bin/notion-ids.py's own database search, for the same reason: a server
    that repeats a cursor with has_more true must not hang this script
    forever, which is this whole system's worst failure mode.
    """
    existing = {}
    cursor = None
    seen_cursors = set()
    pages_fetched = 0
    while True:
        body = {"start_cursor": cursor} if cursor else {}
        resp = call("POST", f"databases/{base_id}/query", body, dry=False)
        for page in resp.get("results", []):
            key = _sync_key_of(page)
            if not key:
                continue
            if key in existing:
                raise SystemExit(
                    f"notion-sync-upsert: database {base_id} has two pages "
                    f"with Sync Key {key!r} ({existing[key]['page_id']!r} "
                    f"and {page['id']!r}); refusing to guess which is "
                    "current")
            existing[key] = {"page_id": page["id"], "archived": _archive_of(page),
                              "props": _protected_props_of(page)}
        if not resp.get("has_more"):
            return existing
        cursor = resp.get("next_cursor")
        if not cursor or cursor in seen_cursors:
            raise SystemExit(
                f"notion-sync-upsert: database {base_id} query repeated or "
                f"produced an empty cursor ({cursor!r}); refusing to loop")
        seen_cursors.add(cursor)
        pages_fetched += 1
        if pages_fetched >= MAX_QUERY_PAGES:
            raise SystemExit(
                f"notion-sync-upsert: database {base_id} query exceeded "
                f"{MAX_QUERY_PAGES} pages; refusing to continue")


def list_area_ids(areas_base_id):
    """{Area Name: page_id} for every page in the Areas database, by TITLE --
    not Sync Key. An Area created by hand for this exact purpose (plan 300)
    has no Sync Key, so the Sync-Key-keyed list_existing() would silently
    skip it; the relation resolver needs it findable anyway.
    """
    names = {}
    cursor = None
    seen_cursors = set()
    pages_fetched = 0
    while True:
        body = {"start_cursor": cursor} if cursor else {}
        resp = call("POST", f"databases/{areas_base_id}/query", body, dry=False)
        for page in resp.get("results", []):
            name = _title_of(page)
            if name:
                names[name] = page["id"]
        if not resp.get("has_more"):
            return names
        cursor = resp.get("next_cursor")
        if not cursor or cursor in seen_cursors:
            raise SystemExit(
                f"notion-sync-upsert: Areas database {areas_base_id} query "
                f"repeated or produced an empty cursor ({cursor!r}); "
                "refusing to loop")
        seen_cursors.add(cursor)
        pages_fetched += 1
        if pages_fetched >= MAX_QUERY_PAGES:
            raise SystemExit(
                f"notion-sync-upsert: Areas database {areas_base_id} query "
                f"exceeded {MAX_QUERY_PAGES} pages; refusing to continue")


def _write_page(method, path, body, dry_run, base_name, sync_key):
    """call(), with the base and row named on failure.

    Notion's own error text already names the offending PROPERTY (e.g.
    "Código is not a property that exists.") -- this adds the base and
    sync_key, the two things Notion's message cannot know, so a bootstrap
    gap is diagnosable from stderr alone, the way it needed to be during the
    first real sync.
    """
    try:
        return call(method, path, body, dry=dry_run)
    except NotionError as exc:
        raise NotionError(
            exc.status,
            f"[base={base_name} sync_key={sync_key}] {exc.body}",
            malformed=exc.malformed) from None


def process_base(base_name, base_id, rows, now_iso, dry_run, area_ids=None):
    existing = list_existing(base_id)
    seen_keys = set()
    creates = updates = archived = 0
    for row in rows:
        key = row["sync_key"]
        seen_keys.add(key)
        existing_props = existing[key]["props"] if key in existing else None
        properties = build_properties(row, now_iso, area_ids=area_ids,
                                       existing_props=existing_props)
        if key in existing:
            page_id = existing[key]["page_id"]
            _write_page("PATCH", f"pages/{page_id}", {"properties": properties},
                        dry_run, base_name, key)
            updates += 1
        else:
            _write_page("POST", "pages",
                        {"parent": {"database_id": base_id}, "properties": properties},
                        dry_run, base_name, key)
            creates += 1
    # Never delete: anything the map knows about but this run did not see
    # gets archived, unless it already was.
    for key, info in existing.items():
        if key in seen_keys or info["archived"]:
            continue
        _write_page("PATCH", f"pages/{info['page_id']}",
                    {"properties": {"Archive": _checkbox(True),
                                     "Última sincronización": _date(now_iso)}},
                    dry_run, base_name, key)
        archived += 1
    return {"base": base_name, "database_id": base_id, "rows": len(rows),
            "creates": creates, "updates": updates, "archived": archived}


def run_sync(ids, rows, now_iso, dry_run, sync_bases=None):
    # None (no caller opted in) means "every base in ids", the original
    # behaviour. A caller CAN pass fewer bases than ids has -- exactly the
    # Resources+Areas-for-lookup-only case above -- but never more (checked
    # in main() before this is called).
    sync_bases = list(ids.keys()) if sync_bases is None else sync_bases
    # Validate EVERY row before any base is touched -- a network call (read
    # or write) for base 1 must not happen only to discover base 3's row 5
    # has no Name. This is what makes "zero writes attempted" true for this
    # failure regardless of where in the row list the bad row sits, the same
    # shape as the classify/redact gate aborting before any base is touched.
    for row in rows:
        if TITLE_FIELD not in row["props"]:
            raise SystemExit(
                f"notion-sync-upsert: row {row['sync_key']!r} has no Name "
                "-- every Notion page needs a title, and fabricating one "
                "from the sync_key would hide a real gap in the parser's "
                "output")
    # Resolved ONCE for the whole run, not per base or per row: the same
    # cost profile as list_existing's one query per base. Computed whenever
    # an Areas database id is known, regardless of whether any row in THIS
    # run actually references Area -- simpler than threading a "does anyone
    # need this" check through run_sync, and one extra read is cheap. This
    # IS a network call before the Name check's "zero writes" guarantee is
    # fully established -- unavoidable, resolving a relation needs to know
    # what exists -- but it is a read, and every row's relation is validated
    # against it below before any base is WRITTEN to, same shape as the Name
    # check just above: base 3 row 5 referencing a nonexistent Area must not
    # be discovered only after base 1 already has new pages in it.
    area_ids = list_area_ids(ids["Areas"]) if "Areas" in ids else {}
    for row in rows:
        for rel_key in RELATION_FIELDS:
            if rel_key in row["props"] and row["props"][rel_key] not in area_ids:
                raise SystemExit(
                    f"notion-sync-upsert: row {row['sync_key']!r} references "
                    f"{rel_key} {row['props'][rel_key]!r}, which does not "
                    "exist in the Areas database -- refusing to write an "
                    "empty or guessed relation")
    by_base = {}
    for row in rows:
        by_base.setdefault(row["base"], []).append(row)
    unknown = sorted(set(by_base) - set(ids))
    if unknown:
        raise NotionConfigError(
            f"rows reference base(s) {unknown} with no database id supplied")
    # A row for a base outside sync_bases would otherwise vanish silently --
    # never processed, never reported, never archived -- the exact shape of
    # bug this whole system has been burned by before. bin/notion-sync's own
    # row filter already prevents this in practice, but a caller passing
    # rows and sync_bases that disagree gets a loud error, not silent data
    # loss.
    orphaned = sorted(set(by_base) - set(sync_bases))
    if orphaned:
        raise NotionConfigError(
            f"rows reference base(s) {orphaned}, which have an id in --ids "
            "but are not in --sync-bases -- refusing to silently drop them")
    for base in sync_bases:
        base_id = ids[base]
        summary = process_base(base, base_id, by_base.get(base, []), now_iso,
                                dry_run, area_ids=area_ids)
        print(json.dumps(summary, ensure_ascii=False))


def _schema_shape_for(key):
    """The Notion property-DEFINITION shape (not a value) for field `key`,
    using the exact same name-based mapping as build_properties -- one
    source of truth for "what type is this field", shared between writing a
    row and defining the column that row is written into."""
    if key in SELECT_FIELDS:
        return {"select": {}}
    if key in DATE_FIELDS:
        return {"date": {}}
    if key in MULTI_SELECT_FIELDS:
        return {"multi_select": {}}
    if key in CHECKBOX_FIELDS:
        return {"checkbox": {}}
    if key in NUMBER_FIELDS:
        return {"number": {}}
    if key in URL_FIELDS:
        return {"url": {}}
    return {"rich_text": {}}


def derive_content_schema(rows_for_base):
    """Every property name appearing in any row's `props`, EXCEPT `Name`
    (already the title property on all six bases -- verified directly, and
    redefining a title property's type is not something to attempt) and
    `Archive` (a control property, defined separately so it is never
    missing even for a base with zero rows in this call). Order is
    irrelevant: this becomes a `properties` dict, keyed by name.
    """
    schema = {}
    for row in rows_for_base:
        for key in row["props"]:
            if key in (TITLE_FIELD, "Archive"):
                continue
            schema[key] = _schema_shape_for(key)
    return schema


def run_bootstrap(ids, rows, dry_run):
    by_base = {}
    for row in rows:
        by_base.setdefault(row["base"], []).append(row)
    for base, base_id in ids.items():
        properties = dict(CONTROL_PROPERTY_SCHEMA)
        properties.update(derive_content_schema(by_base.get(base, [])))
        call("PATCH", f"databases/{base_id}",
             {"properties": properties}, dry=dry_run)
        print(json.dumps({"base": base, "database_id": base_id,
                           "status": "ok",
                           "properties": sorted(properties)},
                          ensure_ascii=False))


def parse_args(argv):
    if len(argv) < 2 or argv[1] not in ("sync", "bootstrap"):
        return None
    mode = argv[1]
    ids_json = None
    dry_run = False
    now = None
    sync_bases_json = None
    i = 2
    while i < len(argv):
        arg = argv[i]
        if arg == "--ids":
            i += 1
            if i >= len(argv):
                return None
            ids_json = argv[i]
        elif arg == "--dry-run":
            dry_run = True
        elif arg == "--now":
            i += 1
            if i >= len(argv):
                return None
            now = argv[i]
        elif arg == "--sync-bases":
            i += 1
            if i >= len(argv):
                return None
            sync_bases_json = argv[i]
        else:
            return None
        i += 1
    if ids_json is None:
        return None
    return mode, ids_json, dry_run, now, sync_bases_json


def main(argv):
    parsed = parse_args(argv)
    if parsed is None:
        print(USAGE, file=sys.stderr)
        return 4
    mode, ids_raw, dry_run, now_arg, sync_bases_raw = parsed

    try:
        ids = json.loads(ids_raw)
    except json.JSONDecodeError as exc:
        print(f"notion-sync-upsert: --ids is not valid JSON: {exc}",
              file=sys.stderr)
        return 4
    if not isinstance(ids, dict) or not ids:
        print("notion-sync-upsert: --ids must be a non-empty JSON object",
              file=sys.stderr)
        return 4

    # --sync-bases is the set of bases this run actually PROCESSES (creates/
    # updates/archives). Optional and separate from --ids on purpose: --ids
    # may carry MORE bases than this run touches -- Resources' Area relation
    # (plan 300) needs Areas' id for lookups without Areas itself being
    # "requested", which would archive every existing Areas page for a run
    # that never meant to touch Areas at all. Defaulting to every key in
    # --ids preserves old behaviour for any caller that omits this flag.
    sync_bases = None
    if sync_bases_raw is not None:
        try:
            sync_bases = json.loads(sync_bases_raw)
        except json.JSONDecodeError as exc:
            print(f"notion-sync-upsert: --sync-bases is not valid JSON: {exc}",
                  file=sys.stderr)
            return 4
        if not isinstance(sync_bases, list) or not all(isinstance(b, str) for b in sync_bases):
            print("notion-sync-upsert: --sync-bases must be a JSON array of strings",
                  file=sys.stderr)
            return 4
        unknown = sorted(set(sync_bases) - set(ids))
        if unknown:
            print(f"notion-sync-upsert: --sync-bases names base(s) {unknown} "
                  "with no id in --ids", file=sys.stderr)
            return 4

    now_iso = now_arg or datetime.now(timezone.utc).strftime("%Y-%m-%d")

    # Both modes read the same shape from stdin now: bootstrap needs the
    # rows to derive its content-property set from, not just the four
    # control properties.
    raw = sys.stdin.read()
    try:
        rows = json.loads(raw)
    except json.JSONDecodeError as exc:
        print(f"notion-sync-upsert: stdin is not valid JSON: {exc}",
              file=sys.stderr)
        return 4
    if not isinstance(rows, list):
        print("notion-sync-upsert: stdin must be a JSON array of rows",
              file=sys.stderr)
        return 4

    try:
        if mode == "bootstrap":
            run_bootstrap(ids, rows, dry_run)
        else:
            run_sync(ids, rows, now_iso, dry_run, sync_bases=sync_bases)
    except NotionConfigError as exc:
        print(f"notion-sync-upsert: {exc}", file=sys.stderr)
        return 3
    except NotionTransportError as exc:
        print(f"notion-sync-upsert: {exc}", file=sys.stderr)
        return 2
    except NotionError as exc:
        print(f"notion-sync-upsert: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

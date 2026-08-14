#!/usr/bin/env python3
"""Resolve the six Notion database ids by title and cache them.

Only this script writes the cache. Every other consumer reads the file, so a
database that is not shared with the integration surfaces here as one clear
error instead of a 404 halfway through a sync.

Exit codes: 0 success · 1 API error · 2 transport failure · 3 configuration
error (no token) · 4 usage, a corrupt cache, or an unknown base.
"""
import argparse
import json
import os
import sys

sys.path.insert(0, os.path.join(
    os.path.dirname(os.path.realpath(__file__)), "..", "lib"))

from notion_api import (NotionConfigError, NotionError,  # noqa: E402
                        NotionTransportError, call)

BASES = ["Areas", "Projects", "Goals", "Tasks", "Events", "Resources", "Meetings"]
MAX_SEARCH_PAGES = 20


class Usage(Exception):
    """A caller or on-disk-state problem: exit 4, not an API failure."""
IDS_FILE = os.environ.get(
    "NOTION_IDS_FILE",
    os.path.expanduser("~/.config/devbrain/notion-ids.json"))


def _title_of(row):
    """A database title arrives as a list of rich-text runs, not one string."""
    # `or ""` and not just a default: a run whose plain_text is present but
    # null would otherwise reach str.join and raise a raw traceback, which this
    # script treats as a defect rather than an error report.
    return "".join((t.get("plain_text") or "")
                   for t in (row.get("title") or [])).strip()


def _search_all(name):
    """Every search page, not just the first.

    Without pagination a database ranked past page 1 would be reported as "not
    visible" — telling the operator to connect something that is already
    connected, which is worse than an incomplete message.
    """
    cursor, seen, pages = None, set(), 0
    while True:
        payload = {"query": name,
                   "filter": {"value": "database", "property": "object"}}
        if cursor:
            payload["start_cursor"] = cursor
        page = call("POST", "search", payload)
        for row in page.get("results", []):
            yield row
        if not page.get("has_more"):
            return
        cursor = page.get("next_cursor")
        if not cursor:
            return
        # Two independent stops. A server that repeats a cursor with
        # has_more: true would otherwise loop forever — reproduced, and it hangs
        # an unattended job with no output. Adding pagination without a bound is
        # how a fix for a wrong answer becomes a fix for a hang.
        if cursor in seen:
            raise SystemExit(
                f"notion-ids: search for {name!r} repeated cursor {cursor!r}; "
                f"refusing to loop")
        seen.add(cursor)
        pages += 1
        if pages >= MAX_SEARCH_PAGES:
            raise SystemExit(
                f"notion-ids: search for {name!r} exceeded "
                f"{MAX_SEARCH_PAGES} pages; refusing to continue")


def _find(name):
    matches = []
    for row in _search_all(name):
        # Trust the filter but verify: relying on pages not carrying a `title`
        # key is accidental safety, not defensive code.
        if row.get("object") != "database":
            continue
        if _title_of(row).casefold() == name.casefold():
            matches.append(row["id"])
    if not matches:
        raise SystemExit(
            f"notion-ids: no database titled {name!r} is visible. Connect it to "
            f"the devbrain-sync integration in Notion, then retry.")
    if len(matches) > 1:
        # Notion's relevance order is undocumented and not stable, so picking
        # the first would cache a different database on a different day.
        raise SystemExit(
            f"notion-ids: {len(matches)} databases are titled {name!r}. Rename "
            f"or archive the duplicates so the choice is unambiguous.")
    return matches[0]


def resolve():
    found = {name: _find(name) for name in BASES}
    tmp = IDS_FILE + ".tmp"
    # Create with mode 600 ATOMICALLY. `open(tmp, "w")` creates at the umask
    # (0644) and writes the ids before a later chmod tightens it, leaving a
    # window — and a permanent exposure if the process dies in between. This is
    # the same defect this plan already fixed once in the HTTP client's header
    # config file; it is easy to write twice.
    # os.open must be INSIDE the try. Outside it, an unwritable directory raised
    # a raw PermissionError traceback — and this script treats a traceback as a
    # defect, not an error report. Both write-phase failures were reproduced:
    # PermissionError from os.open, and IsADirectoryError from os.replace when the
    # target path is a directory.
    try:
        # makedirs belongs INSIDE the try too. Outside it, creating a missing
        # subdirectory under an unwritable parent raised a raw PermissionError at
        # exit 1 — the same defect as os.open had, one level up. 0o700 matches the
        # care taken with the file itself.
        os.makedirs(os.path.dirname(IDS_FILE) or ".", mode=0o700, exist_ok=True)
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as fh:
                json.dump(found, fh, indent=1, ensure_ascii=False)
            os.replace(tmp, IDS_FILE)   # same directory, so a real atomic rename
        except BaseException:
            # Never leave a half-written cache of ids behind on failure.
            try:
                os.unlink(tmp)
            except OSError:
                pass
            raise
    except OSError as exc:
        raise Usage(f"cannot write {IDS_FILE}: {exc.strerror}. "
                    f"Check the directory exists and is writable.")
    print(f"notion-ids: resolved {len(found)} bases into {IDS_FILE}")


def get(name):
    if not os.path.exists(IDS_FILE):
        raise Usage(f"{IDS_FILE} is missing. Run `notion-ids.py --resolve` first.")
    try:
        with open(IDS_FILE, encoding="utf-8") as fh:
            cache = json.load(fh)
    except OSError as exc:
        raise Usage(f"cannot read {IDS_FILE}: {exc.strerror}. "
                    f"Check its permissions, or run `notion-ids.py --resolve`.")
    except UnicodeDecodeError:
        # UnicodeDecodeError is a ValueError, NOT an OSError, so it escaped both
        # get()'s OSError clause and the main() backstop. Reading a file fails in
        # exactly three ways — at the OS layer, at the decode, or at the parse —
        # so all three are enumerated here rather than guessed at one at a time.
        raise Usage(f"{IDS_FILE} is not valid UTF-8. "
                    f"Run `notion-ids.py --resolve` to regenerate it.")
    except json.JSONDecodeError as exc:
        raise Usage(f"{IDS_FILE} is not valid JSON ({exc}). "
                    f"Run `notion-ids.py --resolve` to regenerate it.")
    if not isinstance(cache, dict):
        raise Usage(f"{IDS_FILE} does not contain a JSON object "
                    f"(found {type(cache).__name__}). Run `notion-ids.py --resolve`.")
    value = cache.get(name)
    if not value:
        raise Usage(f"no cached id for base {name!r}. "
                    f"Known: {', '.join(sorted(cache)) or '(none)'}")
    print(value)


def main():
    ap = argparse.ArgumentParser()
    group = ap.add_mutually_exclusive_group(required=True)
    group.add_argument("--resolve", action="store_true")
    group.add_argument("--get", metavar="BASE")
    args = ap.parse_args()
    # Distinct codes, because the docstring promised them and every path
    # previously exited 1. A bash orchestrator needs to tell "fix the secrets
    # file once" (3) from "the network was down, retry later" (2).
    try:
        if args.resolve:
            resolve()
        else:
            get(args.get)
    except NotionConfigError as exc:
        print(f"notion-ids: {exc}", file=sys.stderr)
        return 3
    except NotionTransportError as exc:
        print(f"notion-ids: {exc}", file=sys.stderr)
        return 2
    except NotionError as exc:
        print(f"notion-ids: API error: {exc}", file=sys.stderr)
        return 1
    except Usage as exc:
        print(f"notion-ids: {exc}", file=sys.stderr)
        return 4
    except (OSError, UnicodeDecodeError) as exc:
        # Backstop for the two ways the environment can fail underneath us: the
        # filesystem, and a file that is not valid UTF-8. Four rounds on this file
        # were spent moving individual calls inside a try, each fix crossing the
        # next boundary, which is why this catches classes rather than call sites.
        #
        # Deliberately NOT caught here: KeyboardInterrupt and genuine programming
        # errors. The invariant is "an expected failure mode must not surface as a
        # traceback", not "nothing may ever traceback". A KeyboardInterrupt is
        # the operator interrupting, and swallowing it would be wrong; a TypeError is a
        # bug and should be loud. The inline `except BaseException` in resolve()
        # still removes the .tmp on interrupt before re-raising, which is the part
        # that matters.
        print(f"notion-ids: cannot use {IDS_FILE}: {exc}", file=sys.stderr)
        return 4
    return 0


if __name__ == "__main__":
    sys.exit(main())

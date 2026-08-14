"""Notion REST client. Knows nothing about the wiki.

The token is read from the environment and passed only in a request header, so
it never reaches a process argv (a curl-based predecessor put it in curl's
command line, where `ps` exposed it) and never touches disk.

Integer arithmetic here cannot overflow, which is what defeated an earlier
bash version's Retry-After clamp: a 19+ digit value made `[ -gt ]` error out, the
clamp was skipped, and the backoff collapsed into a same-second retry storm.
"""
import json
import os
import sys
import time
import urllib.error
import urllib.request

# urllib follows 3xx on GET but raises HTTPError for them on other methods.
# Notion does not redirect its API, so that default is left alone deliberately.
API_DEFAULT = "https://api.notion.com/v1"
VERSION = "2022-06-28"
MAX_ATTEMPTS = 5  # TOTAL attempts, i.e. the first try plus 4 retries
RETRY_CAP_SECONDS = 60
DEFAULT_RETRY_SECONDS = 2


class NotionError(Exception):
    """A response that cannot be used.

    Usually a non-2xx status. It can also be a 2xx whose body is not JSON, in
    which case `status` is that 2xx code and `malformed` is True — a caller
    branching on `status` alone would otherwise read a success code off an
    object named "error".
    """

    def __init__(self, status, body, malformed=False):
        kind = "malformed body" if malformed else "HTTP"
        super().__init__(f"{kind} {status}: {body[:400]}")
        self.status = status
        self.body = body
        self.malformed = malformed


class NotionTransportError(Exception):
    """The request was attempted but never reached an HTTP status."""


class NotionConfigError(Exception):
    """The request was never attempted because configuration is missing.

    Distinct from NotionTransportError on purpose: an unattended job must be
    able to tell "fix the secrets file once" from "the network was down, retry
    next week". The CLI maps this to its own exit code.
    """


_announced_base = False


def _base():
    """The API base. Announce an override ONCE per process, not per call.

    Called once per request; a ~99-row sync would otherwise print the same
    notice 99 times.
    """
    global _announced_base
    base = os.environ.get("NOTION_BASE", API_DEFAULT)
    if base != API_DEFAULT and not _announced_base:
        print(f"notion_api: NOTION_BASE overridden to {base}", file=sys.stderr)
        _announced_base = True
    return base


_announced_cap = False


def _retry_cap():
    """The clamp, overridable DOWNWARD only, and never silently.

    The override exists so the test suite need not pay 60s of wall clock. An
    inherited value must not be able to raise the cap: that would reintroduce
    the unbounded-sleep class this clamp exists to prevent, with no trace in the
    log. So it may only shrink, and it announces itself once.
    """
    global _announced_cap
    raw = os.environ.get("NOTION_RETRY_CAP_SECONDS", "")
    if not (raw.isdigit() and int(raw) > 0):
        return RETRY_CAP_SECONDS
    cap = min(int(raw), RETRY_CAP_SECONDS)
    if not _announced_cap:
        print(f"notion_api: retry cap overridden to {cap}s "
              f"(default {RETRY_CAP_SECONDS}s)", file=sys.stderr)
        _announced_cap = True
    return cap


def _retry_after(headers):
    """Seconds to wait, clamped. Retry-After is a header, not a body field."""
    raw = headers.get("Retry-After")
    if raw is None:
        return DEFAULT_RETRY_SECONDS
    raw = raw.strip()
    if not raw.isdigit():
        # RFC 7231 also permits an HTTP-date. Notion documents integer seconds,
        # so fall back — but say so instead of falling back silently. Truncate:
        # the value is server-controlled and logs should not be floodable.
        print(f"notion_api: unparsable Retry-After ({raw[:40]!r}), "
              f"using {DEFAULT_RETRY_SECONDS}s", file=sys.stderr)
        return DEFAULT_RETRY_SECONDS
    seconds = int(raw)
    cap = _retry_cap()
    if seconds > cap:
        print(f"notion_api: Retry-After {seconds}s exceeds the {cap}s cap, "
              "clamping", file=sys.stderr)
        return cap
    return seconds


def call(method, path, body=None, dry=False):
    if dry:
        print(f"DRY-RUN {method} {path}", file=sys.stderr)
        return {"dry_run": True}

    token = os.environ.get("NOTION_TOKEN")
    if not token:
        raise NotionConfigError(
            "NOTION_TOKEN is not set (expected from "
            "~/.config/devbrain/secrets/notion.env)")

    data = json.dumps(body).encode() if body is not None else None
    url = f"{_base()}/{path}"

    for attempt in range(1, MAX_ATTEMPTS + 1):
        req = urllib.request.Request(url, data=data, method=method)
        req.add_header("Authorization", f"Bearer {token}")
        req.add_header("Notion-Version", VERSION)
        if data is not None:
            req.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                # An empty 2xx body is legal and must not crash: json.load on
                # empty input raises JSONDecodeError, which is neither HTTPError
                # nor URLError and would escape as a raw traceback instead of one
                # of the documented exit codes.
                raw = resp.read()
                if not raw:
                    return {}
                try:
                    return json.loads(raw)
                except json.JSONDecodeError:
                    raise NotionError(
                        resp.status,
                        f"2xx with a non-JSON body: {raw[:200]!r}",
                        malformed=True) from None
        except urllib.error.HTTPError as exc:
            payload = exc.read().decode(errors="replace")
            if exc.code == 429 and attempt < MAX_ATTEMPTS:
                time.sleep(_retry_after(exc.headers))
                continue
            raise NotionError(exc.code, payload) from None
        except urllib.error.URLError as exc:
            raise NotionTransportError(
                f"{method} {path} failed at the transport layer: "
                f"{exc.reason}") from None
    # Unreachable: every iteration returns, continues, or raises. The final
    # attempt's 429 is raised inside the loop, carrying the real payload.
    raise AssertionError("notion_api: retry loop fell through")

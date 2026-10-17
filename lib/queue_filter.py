"""Filter for text that agents write into the queue.

Called by `queue_filter_text` (lib/queue.sh) with `python3 -I`. Reads bytes on stdin. Exits 0
and prints ONE line (the normalized text), or exits 4 and prints only the reason: format,
length, key or personal data. A rejection never returns the text or a fragment of it. Any
other failure exits 6 without printing anything of the text.

In order: strict UTF-8, NFKC, flattening (LF, CR and tab become a space), guillemets to straight
quotes, invisible and control characters (every C* or Z* category except the ASCII space; the
ZWJ only inside an emoji sequence; variation selectors only one, glued to a visible non-ASCII
character; and a few invisibles that are neither C* nor Z*), the <<< and >>> markers, length,
key and personal data.

Personal data is a HEURISTIC, not a detector: it stops what looks like a phone number or an
email and lets ordinary prose through (dates, lists of plan numbers, UUIDs, amounts). See
STRIP_OK and _personal_data. It treats any run of 8 or more digits that is not a date, an
amount or an IP address as a phone number, wherever in the world; loosen STRIP_OK if your own
plans carry long identifiers.
"""
import re
import sys
import unicodedata

MAX_LENGTH = 500

# --- keys -----------------------------------------------------------------------------------
_B64 = r"[A-Za-z0-9_-]"
RE_PREFIX = re.compile(
    r"\b(?:sk-ant-|sk-|sk_live_|AIza|xai-|sbp_|ghp_|gho_|github_pat_|glpat-|xoxb-|xoxp-|AKIA)"
    + _B64 + r"{16,}"
)
RE_RESEND = re.compile(r"re_(" + _B64 + r"{24,})")  # also needs a digit and an uppercase letter
RE_OTHER_KEYS = re.compile(
    r"-----BEGIN"
    r"|Bearer [A-Za-z0-9._~+/=-]{16,}"
    r"|://[^\s/:@]+:[^\s/@]+@"
    r"|[?&](?:token|access_token|key|api_key)="
    r"|eyJ[A-Za-z0-9_-]+\.eyJ[A-Za-z0-9_-]+"
)
RE_LONG = re.compile(r"[A-Za-z0-9+=_-]{32,}")  # a long mixed string: the generic key

# --- personal data --------------------------------------------------------------------------
RE_EMAIL = re.compile(r"[^\s@]+@[^\s@]+\.[^\s@]+")
RE_PLUS = re.compile(r"\+(?:[ ().-]*[0-9]){8,}")
RE_PAREN = re.compile(r"\([0-9]{1,4}\)(?:[ ().-]*[0-9]){8,}")
# a run of digits joined only by - . ( ), with no letter or digit glued to either side
RE_STRIP = re.compile(r"(?<![A-Za-z0-9])[0-9](?:[0-9().-]*[0-9])?(?![A-Za-z0-9])")
# what is NOT a phone number even with 8 or more digits
_MONTH = r"(?:0[1-9]|1[0-2])"
_DAY = r"(?:0[1-9]|[12][0-9]|3[01])"
# a UUID (8-4-4-4-12 hex) can have an all-digit group: it is not looked at as a phone number
RE_UUID = re.compile(
    r"(?<![A-Za-z0-9])[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}(?![A-Za-z0-9])"
)
STRIP_OK = (
    re.compile(r"(?:19|20)[0-9]{2}" + _MONTH + _DAY),                # YYYYMMDD
    re.compile(r"(?:19|20)[0-9]{2}\." + _MONTH + r"\." + _DAY),      # YYYY.MM.DD
    re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}"),            # YYYY-MM-DD
    re.compile(r"[0-9]{2}-[0-9]{2}-[0-9]{4}"),            # DD-MM-YYYY
    re.compile(r"[0-9]{2}\.[0-9]{2}\.[0-9]{4}"),          # DD.MM.YYYY
    re.compile(r"[0-9]{1,3}(?:\.[0-9]{3})+"),             # thousands with a dot
    re.compile(r"[0-9]{1,3}\.[0-9]+"),                    # decimal
    re.compile(r"[0-9]{1,3}(?:\.[0-9]{1,3}){3}"),         # four-group IP address
    re.compile(r"[12][0-9]{3}(?:-[12][0-9]{3}){1,2}"),    # a range or list of plan numbers or years
)


# invisibles that are NOT category C* or Z* and that hide text (hangul filler, CGJ, empty braille...)
_INVISIBLES = frozenset(map(chr, (0x034F, 0x115F, 0x1160, 0x17B4, 0x17B5, 0x2800, 0x3164, 0xFFA0)))


def _is_selector(c):
    """Variation selector (FE00-FE0F, E0100-E01EF) or Mongolian free variation selector (180B-180D, 180F)."""
    o = ord(c)
    return 0xFE00 <= o <= 0xFE0F or 0xE0100 <= o <= 0xE01EF or 0x180B <= o <= 0x180D or o == 0x180F


def _emoji(c):
    return unicodedata.category(c) in ("So", "Sk")


def _format(s):
    """True if `s` has an invisible or control character."""
    for i, c in enumerate(s):
        if c == " ":
            continue
        if c in _INVISIBLES:
            return True
        if _is_selector(c):
            # at most one per base character, and the base is a visible non-ASCII character
            b = s[i - 1] if i else "\0"
            if b < "\x80" or _is_selector(b) or unicodedata.category(b)[0] in "CZ":
                return True
            continue
        if unicodedata.category(c)[0] in "CZ":
            # the ZWJ only joins emoji: <emoji> ZWJ <emoji>, or <emoji> FE0F ZWJ <emoji>
            if (
                c == "‍"
                and 0 < i < len(s) - 1
                and (_emoji(s[i - 1]) or (s[i - 1] == "️" and i > 1 and _emoji(s[i - 2])))
                and unicodedata.category(s[i + 1]) == "So"
            ):
                continue
            return True
    return False


def _key(s):
    if RE_PREFIX.search(s) or RE_OTHER_KEYS.search(s):
        return True
    for m in RE_RESEND.finditer(s):
        if re.search(r"[0-9]", m.group(1)) and re.search(r"[A-Z]", m.group(1)):
            return True
    for m in RE_LONG.finditer(s):
        t = m.group(0)
        if "--" in t or s.startswith(".plan", m.end()):  # queue file names
            continue
        if re.search(r"[a-z]", t) and re.search(r"[A-Z]", t) and re.search(r"[0-9]", t):
            return True
    return False


def _personal_data(s):
    if RE_EMAIL.search(s) or RE_PLUS.search(s) or RE_PAREN.search(s):
        return True
    for m in RE_STRIP.finditer(RE_UUID.sub(" ", s)):
        t = m.group(0)
        n = re.sub(r"[^0-9]", "", t)
        if len(n) < 8 or any(r.fullmatch(t) for r in STRIP_OK):
            continue
        return True
    return False


def filter_text(raw):
    """bytes -> (0, line) if it passes; (4, reason) if not."""
    try:
        s = raw.decode("utf-8")  # strict
    except UnicodeDecodeError:
        return 4, "format"
    s = unicodedata.normalize("NFKC", s)
    s = s.replace("\n", " ").replace("\r", " ").replace("\t", " ")
    s = s.replace("«", '"').replace("»", '"')
    if not s.strip() or _format(s) or "<<<" in s or ">>>" in s:
        return 4, "format"
    if len(s) > MAX_LENGTH:
        return 4, "length"
    if _key(s):
        return 4, "key"
    if _personal_data(s):
        return 4, "personal data"
    return 0, s


def main():
    try:
        rc, out = filter_text(sys.stdin.buffer.read())
        sys.stdout.buffer.write(out.encode("utf-8") + b"\n")
        sys.stdout.buffer.flush()
        return rc
    except BaseException:  # never a traceback: it could carry the text
        sys.stderr.write("error: the text filter failed\n")
        return 6


if __name__ == "__main__":
    sys.exit(main())

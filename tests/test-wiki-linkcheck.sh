#!/bin/bash
# tests/test-wiki-linkcheck.sh — outgoing-link checker, both directions.
#
# The point of this suite is NOT just "does it find broken links". A checker
# that flags everything finds them too. Every detection assertion below is
# paired with a silence assertion on a case that must NOT be flagged, because
# the first real run of this tool reported 9 problems of which 5 were correct
# text — documented examples living inside inline code spans. Fixing those
# would have corrupted the line in SCHEMA.md that defines the link convention.
set -uo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$DIR/bin/wiki-linkcheck"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1"; exit 1; }

# ---- a vault with one of every case ---------------------------------------
mkdir -p "$TMP/vault/sub"
cat > "$TMP/vault/real.md" <<'EOF'
# Real Page

## Una Sección Con Acentos
body
EOF

cat > "$TMP/vault/sub/page.md" <<'EOF'
good relative: [real](../real.md)
good anchor: [sec](../real.md#una-sección-con-acentos)
good wikilink: [[real]]
external, not ours: [ext](https://example.com/ghost.md)
inline example: `[x](../ghost.md)` and `[[ghost-page]]`
bsd regex classes: `[[:<:]]foo[[:>:]]`
bad file: [gone](../nope.md)
bad anchor: [bad](../real.md#no-existe)
bad wikilink: [[does-not-exist]]
EOF
printf 'fenced, must be ignored:\n```\n[fake](../nothing.md)\n[[fake-page]]\n```\n' \
  >> "$TMP/vault/sub/page.md"

OUT="$TMP/out"; "$BIN" "$TMP/vault" > "$OUT" 2>&1; RC=$?

# ---- it must fire on all three real breaks --------------------------------
grep -q "nope.md" "$OUT"         || fail "missing file not detected"
grep -q "no-existe" "$OUT"       || fail "bad anchor not detected"
grep -q "does-not-exist" "$OUT"  || fail "unresolved wikilink not detected"
echo "OK: detects missing file, bad anchor, unresolved wikilink"

# ---- and stay silent on everything correct --------------------------------
# Each of these was a real false positive, or would have been one.
grep -q "ghost.md"    "$OUT" && fail "flagged a link inside inline code"
grep -q "ghost-page"  "$OUT" && fail "flagged a wikilink inside inline code"
grep -q ":<:"         "$OUT" && fail "flagged BSD regex class [[:<:]] as a wikilink"
grep -q "nothing.md"  "$OUT" && fail "flagged a link inside a fenced block"
grep -q "fake-page"   "$OUT" && fail "flagged a wikilink inside a fenced block"
grep -q "example.com" "$OUT" && fail "flagged an external URL"
echo "OK: silent on inline code, fenced blocks and external URLs"

# The good links must not appear at all — count is the honest check, since
# "unresolved: 3" proves nothing if a fourth line sneaks in below it.
[ "$(grep -c $'\t' "$OUT")" -eq 3 ] || fail "expected exactly 3 findings, got $(grep -c $'\t' "$OUT")"
grep -q "unresolved: 3" "$OUT" || fail "summary line disagrees with findings"
echo "OK: exactly 3 findings, summary agrees"

[ "$RC" -eq 1 ] || fail "exit code should be 1 when links are unresolved, got $RC"
echo "OK: exit 1 on unresolved links"

# ---- a clean vault must actually come back clean ---------------------------
# Without this, a checker that always reports problems would pass everything above.
mkdir -p "$TMP/clean"
cp "$TMP/vault/real.md" "$TMP/clean/real.md"
printf 'only good links: [real](real.md) and [[real]]\n' > "$TMP/clean/ok.md"
"$BIN" "$TMP/clean" > "$TMP/out2" 2>&1; RC2=$?
[ "$RC2" -eq 0 ] || fail "clean vault should exit 0, got $RC2 ($(cat "$TMP/out2"))"
grep -q "unresolved: 0" "$TMP/out2" || fail "clean vault should report 0 unresolved"
echo "OK: a clean vault reports clean and exits 0"

# ---- --quiet keeps the verdict, drops the noise ---------------------------
"$BIN" --quiet "$TMP/vault" > "$TMP/out3" 2>&1; RC3=$?
[ "$RC3" -eq 1 ] || fail "--quiet must keep exit code 1, got $RC3"
[ ! -s "$TMP/out3" ] || fail "--quiet must print nothing, got: $(cat "$TMP/out3")"
echo "OK: --quiet keeps the exit code and prints nothing"

# ---- a missing vault is an error, not a false 'clean' ----------------------
"$BIN" "$TMP/does-not-exist" >/dev/null 2>"$TMP/err"; RC4=$?
[ "$RC4" -eq 2 ] || fail "missing vault should exit 2, got $RC4"
grep -qi traceback "$TMP/err" && fail "missing vault crashed instead of erroring cleanly"
echo "OK: a missing vault exits 2 cleanly, no traceback"

# ---- the two silent failures ----------------------------------------------
# Neither of these is reported by the checks above: a destination with a space
# is not parsed as a link at all, and bare brackets render as literal text. Both
# were found by hand on 2026-08-08. A broken link that is reported as neither
# broken nor present is the worst kind, so each assertion here is paired with a
# legal form that must stay silent.
mkdir -p "$TMP/silent"
cp "$TMP/vault/real.md" "$TMP/silent/real.md"
cat > "$TMP/silent/page.md" <<'EOF'
BAD space in destination: [x](../real page.md)
BAD bare brackets: [una-pagina-cualquiera]
LEGAL angle brackets: [x](<real.md>)
LEGAL title after destination: [x](real.md "un título")
LEGAL short bracket, no hyphen: [1] and [sic] and [x]
LEGAL reference link: [texto][mi-ref]
LEGAL shortcut to a defined ref: [mi-ref]
LEGAL wikilink, not bare brackets: [[real]]
## [2026-08-05] ingest | the log heading format SCHEMA.md requires
## [2026-07-18] lint | a second one, different date

[mi-ref]: https://example.com
EOF

"$BIN" "$TMP/silent" > "$TMP/out4" 2>&1
grep -q "destination has a space" "$TMP/out4" \
  || fail "did not detect a destination containing a space"
grep -q "brackets with no destination" "$TMP/out4" \
  || fail "did not detect bare brackets"
echo "OK: detects a spaced destination and bare brackets"

# Each of these would be a false positive that makes the check noise.
grep -q "<real.md>" "$TMP/out4"   && fail "flagged a legal <angle bracket> destination"
grep -q 'un título' "$TMP/out4"   && fail "flagged a legal quoted title"
grep -q '\[1\]'     "$TMP/out4"   && fail "flagged [1] as a link"
grep -q '\[sic\]'   "$TMP/out4"   && fail "flagged [sic] as a link"
grep -q 'mi-ref'    "$TMP/out4"   && fail "flagged a reference link or its definition"
# The one that mattered: without a letter requirement this matched every date
# heading in log.md — 72 false positives against 1 real finding on the real
# wiki, while this suite stayed green.
grep -q '2026-08-05' "$TMP/out4" && fail "flagged a [YYYY-MM-DD] log heading"
grep -q '2026-07-18' "$TMP/out4" && fail "flagged a [YYYY-MM-DD] log heading"
[ "$(grep -c $'\t' "$TMP/out4")" -eq 2 ] \
  || fail "expected exactly 2 findings here, got $(grep -c $'\t' "$TMP/out4"): $(cat "$TMP/out4")"
echo "OK: silent on angle brackets, titles, [1]/[sic], reference links and wikilinks"

echo "PASS: wiki-linkcheck"

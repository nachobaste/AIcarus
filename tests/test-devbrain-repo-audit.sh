#!/bin/bash
# tests/test-devbrain-repo-audit.sh — repos invisible to the digest (never
# cloned) or unclassified (in neither .allow nor .excluded) get flagged, and
# ONLY those. Same discipline as test-devbrain-stacked-pr-check.sh: a fake `gh`
# standing in for the GitHub API (never hits the network), every detection
# assertion paired with a silence assertion so a checker that always prints
# something (or nothing) would not pass this file.
set -uo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$DIR/bin/devbrain-repo-audit"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1"; exit 1; }

# ---- fake `gh`: one canned `repo list` response, regardless of owner arg ---
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<FAKEGH
#!/bin/bash
cat "$TMP/repos.json"
FAKEGH
chmod +x "$TMP/bin/gh"

mkdir -p "$TMP/projects"
export REPO_AUDIT_GH="$TMP/bin/gh"
export REPO_AUDIT_PROJECTS_DIR="$TMP/projects"
export REPO_AUDIT_ALLOWFILE="$TMP/allow"
export REPO_AUDIT_EXCLUDEFILE="$TMP/excluded"
# Required, no hardcoded default (a real username baked in would silently audit
# the wrong account's repos on anyone else's machine) — the fake `gh` above
# ignores the owner argument anyway, so any non-empty value exercises the path.
export REPO_AUDIT_OWNER="testowner"

# repos.json covers, one of each:
#   archived-repo    — archived, must be skipped entirely (no findings)
#   forked-repo      — fork, must be skipped entirely
#   healthy-repo     — cloned + allowed, no findings
#   uncloned-allowed — allowed but not cloned -> repo-not-cloned only
#   unclassified-cloned — cloned, neither .allow nor .excluded -> repo-unclassified only
#   blind-spot       — neither cloned nor classified -> BOTH findings
#   excluded-repo    — in .excluded, not cloned, not in .allow -> no findings at all
cat > "$TMP/repos.json" <<'JSON'
[
  {"name": "archived-repo", "isArchived": true, "isFork": false, "pushedAt": "2026-01-01T00:00:00Z"},
  {"name": "forked-repo", "isArchived": false, "isFork": true, "pushedAt": "2026-01-01T00:00:00Z"},
  {"name": "healthy-repo", "isArchived": false, "isFork": false, "pushedAt": "2026-08-10T00:00:00Z"},
  {"name": "uncloned-allowed", "isArchived": false, "isFork": false, "pushedAt": "2026-08-11T00:00:00Z"},
  {"name": "unclassified-cloned", "isArchived": false, "isFork": false, "pushedAt": "2026-08-12T00:00:00Z"},
  {"name": "blind-spot", "isArchived": false, "isFork": false, "pushedAt": "2026-08-12T04:03:00Z"},
  {"name": "excluded-repo", "isArchived": false, "isFork": false, "pushedAt": "2026-07-01T00:00:00Z"}
]
JSON

mkdir -p "$TMP/projects/healthy-repo/.git"
mkdir -p "$TMP/projects/unclassified-cloned/.git"
# uncloned-allowed, blind-spot, excluded-repo: deliberately no local dir at all.

cat > "$TMP/allow" <<'EOF'
healthy-repo
uncloned-allowed
EOF

cat > "$TMP/excluded" <<'EOF'
excluded-repo  # test fixture, deliberately excluded
EOF

OUT="$("$BIN")"
RC=$?

[ "$RC" = 1 ] || fail "expected exit 1 (findings present), got $RC"

assert_line() { # assert_line <expected-tsv-prefix>
  printf '%s\n' "$OUT" | grep -qF "$1" || fail "missing line: $1 -- full output:
$OUT"
}
assert_no_match() { # assert_no_match <repo-name>
  printf '%s\n' "$OUT" | grep -q "	$1	" && fail "unexpected finding for $1 -- full output:
$OUT"
}

# ---- silence assertions: these three must never appear ----
assert_no_match "archived-repo"
assert_no_match "forked-repo"
assert_no_match "excluded-repo"
printf '%s\n' "$OUT" | grep -q "healthy-repo" && fail "healthy-repo (cloned + allowed) should be silent -- full output:
$OUT"

# ---- detection assertions ----
assert_line "repo-not-cloned	uncloned-allowed	2026-08-11T00:00:00Z"
assert_line "repo-unclassified	unclassified-cloned	2026-08-12T00:00:00Z"
assert_line "repo-not-cloned	blind-spot	2026-08-12T04:03:00Z"
assert_line "repo-unclassified	blind-spot	2026-08-12T04:03:00Z"

# uncloned-allowed is allowed, so it must NOT also get repo-unclassified
printf '%s\n' "$OUT" | grep -q "repo-unclassified	uncloned-allowed" \
  && fail "uncloned-allowed is in .allow, must not be flagged unclassified"
# unclassified-cloned IS cloned, so it must NOT also get repo-not-cloned
printf '%s\n' "$OUT" | grep -q "repo-not-cloned	unclassified-cloned" \
  && fail "unclassified-cloned has a local clone, must not be flagged not-cloned"

echo "$OUT" | grep -q "^repo-audit: 4$" || fail "expected count line 'repo-audit: 4', got:
$OUT"

# ---- mutation check: does excluding a previously-flagged repo actually ----
# silence it? A checker that always prints the same thing regardless of
# .excluded content would pass every assertion above and still be broken.
cat >> "$TMP/excluded" <<'EOF'
blind-spot  # mutation check: excluding this must silence BOTH its findings
EOF
OUT2="$("$BIN")"
printf '%s\n' "$OUT2" | grep -q "	blind-spot	" \
  && fail "mutation check failed: excluding blind-spot did not silence it -- full output:
$OUT2"
printf '%s\n' "$OUT2" | grep -q "^repo-audit: 2$" \
  || fail "mutation check: expected count to drop to 2 after excluding blind-spot, got:
$OUT2"

# ---- --quiet: no per-repo lines, no count line, same exit code ----
"$BIN" --quiet > "$TMP/quiet-out" 2>/dev/null
RCQ=$?
[ -s "$TMP/quiet-out" ] && fail "--quiet must print nothing, got:
$(cat "$TMP/quiet-out")"
[ "$RCQ" = 1 ] || fail "--quiet must keep the same exit code, got $RCQ"

# ---- error paths ----
REPO_AUDIT_PROJECTS_DIR="$TMP/does-not-exist" "$BIN" >/dev/null 2>&1
[ $? = 2 ] || fail "missing PROJECTS_DIR must exit 2"

cat > "$TMP/bin/gh" <<'FAKEGH'
#!/bin/bash
exit 1
FAKEGH
chmod +x "$TMP/bin/gh"
"$BIN" >/dev/null 2>&1
[ $? = 2 ] || fail "gh failure must exit 2"

echo "PASS"

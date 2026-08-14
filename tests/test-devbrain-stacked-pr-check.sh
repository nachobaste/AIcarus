#!/bin/bash
# tests/test-devbrain-stacked-pr-check.sh — orphaned stacked-PR merges, both directions.
#
# A PR whose branch gets merged into a stale or overridden base can end up never
# reachable from the real default branch — silently orphaned, with the merged PR
# still showing green. So every assertion below is against planted fixtures: real
# local git repos standing in for GitHub remotes (origin
# URLs rewritten via `url.insteadOf` so they parse as github.com/owner/repo but
# actually transport to a local bare repo), and a fake `gh` binary standing in
# for the GitHub API (never hits the network). Same discipline as
# tests/test-devbrain-drift.sh: pair every detection assertion with a silence
# assertion, so a script that always prints nothing would not pass this file.
set -uo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$DIR/bin/devbrain-stacked-pr-check"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1"; exit 1; }

# ---- fake `gh`: canned merged-PR lists keyed by the -R repo argument -------
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'FAKEGH'
#!/bin/bash
# Stand-in for the real `gh` CLI. Reads -R owner/repo and prints a canned
# `gh pr list --json number,headRefName,mergedAt` response for that repo.
# Anything not listed here returns an empty array (no merged PRs found) --
# real `gh` behaves the same way for a repo with nothing matching the search.
REPO=""
while [ $# -gt 0 ]; do
  if [ "$1" = "-R" ]; then REPO="$2"; fi
  shift
done
case "$REPO" in
  testorg/repoa)
    cat "$TMP_FIXTURE_DIR/repoa-prs.json"
    ;;
  testorg/repob)
    cat "$TMP_FIXTURE_DIR/repob-prs.json"
    ;;
  *)
    echo "[]"
    ;;
esac
FAKEGH
chmod +x "$TMP/bin/gh"
export TMP_FIXTURE_DIR="$TMP"

# ---- git fixture helper: a "remote" (bare repo) + a working clone that ------
# looks like it points at github.com/testorg/<name> but actually transports to
# the local bare repo via `url.insteadOf` (scoped to that one clone's config,
# never global).
make_remote_project() {
  local name="$1"
  git init -q --bare "$TMP/remotes/$name.git"
  git init -q -b main "$TMP/projects/$name"
  git -C "$TMP/projects/$name" config user.email "test@example.com"
  git -C "$TMP/projects/$name" config user.name "Test"
  git -C "$TMP/projects/$name" remote add origin "https://github.com/testorg/$name.git"
  git -C "$TMP/projects/$name" config url."$TMP/remotes/$name.git".insteadOf "https://github.com/testorg/$name.git"
}

commit() { # commit <project> <file> <content>
  printf '%s\n' "$3" > "$TMP/projects/$1/$2"
  git -C "$TMP/projects/$1" add "$2"
  git -C "$TMP/projects/$1" commit -q -m "commit $2"
}

push() { git -C "$TMP/projects/$1" push -q origin "${2:-main}"; } # push <project> [ref]

iso_days_ago() { # portable-enough for a test: use python3, already a devbrain dependency
  python3 -c "import sys; from datetime import datetime, timedelta, timezone; print((datetime.now(timezone.utc)-timedelta(days=int(sys.argv[1]))).strftime('%Y-%m-%dT%H:%M:%SZ'))" "$1"
}

# ============================================================================
# repoA: main + four devbrain/* scenarios
# ============================================================================
make_remote_project repoa
commit repoa base.txt "m0"; push repoa

# devbrain/good: branched, merged into main for real -> tip IS an ancestor.
git -C "$TMP/projects/repoa" checkout -q -b devbrain/good
commit repoa good.txt "g1"
git -C "$TMP/projects/repoa" checkout -q main
git -C "$TMP/projects/repoa" merge -q --no-ff devbrain/good -m "merge good"
push repoa main
push repoa devbrain/good

# devbrain/orphan: branched, NEVER merged into main -> tip is NOT an ancestor.
git -C "$TMP/projects/repoa" checkout -q -b devbrain/orphan main
commit repoa orphan.txt "o1"
push repoa devbrain/orphan

# devbrain/old-orphan: same shape as orphan, but its (fake) merge is outside the
# time window -> must be ignored even though it is a genuine orphan.
git -C "$TMP/projects/repoa" checkout -q -b devbrain/old-orphan main
commit repoa old.txt "old1"
push repoa devbrain/old-orphan

# devbrain/deleted: pushed once, then deleted from the remote -> the branch tip
# is unverifiable (no ref to check) and must be skipped, not crash.
git -C "$TMP/projects/repoa" checkout -q -b devbrain/deleted main
commit repoa deleted.txt "d1"
push repoa devbrain/deleted
git -C "$TMP/projects/repoa" push -q origin --delete devbrain/deleted

cat > "$TMP/repoa-prs.json" <<JSON
[
  {"number": 101, "headRefName": "devbrain/good", "mergedAt": "$(iso_days_ago 1)"},
  {"number": 102, "headRefName": "devbrain/orphan", "mergedAt": "$(iso_days_ago 1)"},
  {"number": 103, "headRefName": "devbrain/old-orphan", "mergedAt": "$(iso_days_ago 90)"},
  {"number": 104, "headRefName": "devbrain/deleted", "mergedAt": "$(iso_days_ago 1)"}
]
JSON

# ============================================================================
# repoB: base-branch override must actually be used, not just accepted.
# main and stable DIVERGE on purpose. devbrain/edge is an ancestor of stable
# (the override) but NOT of main -- so this only passes if the override is
# read and honored, not just parsed.
# ============================================================================
make_remote_project repob
commit repob base.txt "m0"; push repob
git -C "$TMP/projects/repob" checkout -q -b stable
commit repob stable.txt "s1"
push repob stable
git -C "$TMP/projects/repob" checkout -q main
commit repob main-only.txt "main-diverges"   # main now has a commit stable lacks
push repob main

git -C "$TMP/projects/repob" checkout -q -b devbrain/edge stable
commit repob edge.txt "e1"
git -C "$TMP/projects/repob" checkout -q stable
git -C "$TMP/projects/repob" merge -q --no-ff devbrain/edge -m "merge edge into stable"
push repob stable
push repob devbrain/edge

cat > "$TMP/repob-prs.json" <<JSON
[
  {"number": 201, "headRefName": "devbrain/edge", "mergedAt": "$(iso_days_ago 1)"}
]
JSON

# ============================================================================
# allow-list and override files
# ============================================================================
cat > "$TMP/allow" <<'EOF'
# comment and blank line must be ignored
repoa

repob
EOF

cat > "$TMP/override" <<'EOF'
# only repob overrides its base branch
repob=stable
EOF

cat > "$TMP/allow-repob-only" <<'EOF'
repob
EOF

run() {
  STACKED_PR_PROJECTS_DIR="$TMP/projects" \
  STACKED_PR_ALLOWFILE="$TMP/allow" \
  STACKED_PR_BASE_OVERRIDE="$TMP/override" \
  STACKED_PR_GH="$TMP/bin/gh" \
  "$BIN" "$@"
}

# ---- the detection ----------------------------------------------------------
OUT="$TMP/out"; run > "$OUT" 2>"$TMP/err"; RC=$?
[ "$RC" -eq 1 ] || fail "expected exit 1 (findings present), got $RC. stderr: $(cat "$TMP/err")"

grep -q $'pr-apilado-huerfano\trepoa\tdevbrain/orphan\t102' "$OUT" \
  || fail "did not detect the real orphan (repoa/devbrain/orphan #102). Got: $(cat "$OUT")"
echo "OK: detects a merged PR whose branch never reached main"

# ---- silence: the clean cases must NOT be reported --------------------------
grep -q "devbrain/good" "$OUT" && fail "false positive: devbrain/good WAS merged into main"
grep -q "devbrain/old-orphan" "$OUT" && fail "false positive: old-orphan is outside the time window"
grep -q "devbrain/deleted" "$OUT" && fail "false positive: devbrain/deleted has no remote ref left to check"
grep -q "devbrain/edge" "$OUT" && fail "false positive: devbrain/edge is an ancestor of the OVERRIDDEN base (stable), override was ignored"
echo "OK: no false positives (clean merge, out-of-window, deleted branch, overridden base)"

# ---- the override was actually exercised, not just accepted -----------------
# Prove it the way the skill demands: break the override handling and confirm
# the suite would have caught it. Simulate "override ignored" by re-running
# with an override file that points repob at 'main' instead of 'stable' -- since
# main and stable diverge on purpose, devbrain/edge must now show up as an
# orphan against main. If it didn't, this whole override test would be inert.
cat > "$TMP/override-broken" <<'EOF'
repob=main
EOF
# repob-only allow-list here: the point of this canary is isolating whether the
# OVERRIDE logic works, not re-detecting repoA's already-proven orphan.
STACKED_PR_PROJECTS_DIR="$TMP/projects" STACKED_PR_ALLOWFILE="$TMP/allow-repob-only" \
STACKED_PR_BASE_OVERRIDE="$TMP/override-broken" STACKED_PR_GH="$TMP/bin/gh" \
"$BIN" > "$TMP/out-broken" 2>&1
grep -q $'pr-apilado-huerfano\trepob\tdevbrain/edge\t201' "$TMP/out-broken" \
  || fail "canary did not fire: pointing repob at 'main' should make devbrain/edge look orphaned -- if it didn't, the real override test above proves nothing"
echo "OK: canary confirms the override test can actually fail (proved against 'main' instead of 'stable')"

# ---- repo isolation: a repob-only run must stay clean of repoA's findings ---
grep -q "repoa" "$TMP/out-broken" && fail "repoB-only run leaked repoA data"
echo "OK: repos are checked independently, no cross-contamination"

# ---- a repo with no local checkout is skipped, not fatal --------------------
cat > "$TMP/allow-missing" <<'EOF'
repoa
repob
no-such-project-on-disk
EOF
STACKED_PR_PROJECTS_DIR="$TMP/projects" STACKED_PR_ALLOWFILE="$TMP/allow-missing" \
STACKED_PR_BASE_OVERRIDE="$TMP/override" STACKED_PR_GH="$TMP/bin/gh" \
"$BIN" > "$TMP/out-missing" 2>"$TMP/err-missing"; RC=$?
[ "$RC" -eq 1 ] || fail "a missing project checkout should not change the exit code, got $RC"
grep -qi traceback "$TMP/err-missing" && fail "missing checkout crashed instead of warning and skipping"
grep -q "no-such-project-on-disk" "$TMP/err-missing" || fail "missing checkout should be named in the warning"
echo "OK: a project with no local checkout is skipped with a warning, not fatal"

# ---- a fully clean set of repos exits 0 and prints nothing but the summary --
cat > "$TMP/repoa-prs.json" <<'JSON'
[]
JSON
cat > "$TMP/repob-prs.json" <<'JSON'
[]
JSON
run > "$OUT" 2>"$TMP/err"; RC=$?
[ "$RC" -eq 0 ] || fail "clean repos should exit 0, got $RC ($(cat "$OUT"))"
grep -q "stacked-pr: 0" "$OUT" || fail "clean repos should report stacked-pr: 0"
echo "OK: clean repos report 0 and exit 0"

# ---- --quiet keeps the exit code and prints nothing -------------------------
cat > "$TMP/repoa-prs.json" <<JSON
[{"number": 102, "headRefName": "devbrain/orphan", "mergedAt": "$(iso_days_ago 1)"}]
JSON
run --quiet > "$TMP/q" 2>"$TMP/err"; RCQ=$?
[ "$RCQ" -eq 1 ] || fail "--quiet must keep exit 1, got $RCQ"
[ ! -s "$TMP/q" ] || fail "--quiet must print nothing, got: $(cat "$TMP/q")"
echo "OK: exit 1 on findings, --quiet keeps the code and prints nothing"

# ---- a missing config path is a hard error, not a false 'clean' ------------
STACKED_PR_PROJECTS_DIR="$TMP/no-such-dir" STACKED_PR_ALLOWFILE="$TMP/allow" \
STACKED_PR_BASE_OVERRIDE="$TMP/override" STACKED_PR_GH="$TMP/bin/gh" \
"$BIN" >/dev/null 2>"$TMP/err2"; RC=$?
[ "$RC" -eq 2 ] || fail "missing PROJECTS_DIR should exit 2, got $RC"
grep -qi traceback "$TMP/err2" && fail "missing PROJECTS_DIR crashed instead of erroring cleanly"
grep -q "STACKED_PR_PROJECTS_DIR" "$TMP/err2" || fail "the error should name which setting is missing"
echo "OK: a missing configured path exits 2 cleanly and names itself"

echo "PASS: devbrain-stacked-pr-check"

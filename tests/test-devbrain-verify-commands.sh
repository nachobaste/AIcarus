#!/bin/bash
# tests/test-devbrain-verify-commands.sh — per-repo verification commands.
#
# The boundary this protects is NOT "no arbitrary execution" — Bash(npm test:*) has
# always been allowed and npm test runs whatever package.json says. The boundary is
# the NETWORK: nothing here may install code onto the machine. Every assertion below
# is paired with a control, because a lookup that always returns nothing would pass
# a naively written version of this file.
#
# Uses an isolated fixture config (via env var overrides), never the repo's own
# shipped-empty devbrain-verify.commands / devbrain-migration-block.list — those
# ship empty/commented-out by design, so a real starter-kit checkout has nothing
# to assert against until a user has configured their own repos.
set -uo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
DB="$DIR/bin/devbrain"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1"; exit 1; }

FILE="$TMP/verify.commands"
cat > "$FILE" <<'EOF'
qaapp=npm run build,npm run lint
companysgc=python3 scripts/build_docs.py
repoc=deno test:*,node --check:*
prodapp=npm run build@frontend,npm run test:run@frontend,npm run lint@frontend
mktapp=npm test@services/support-api
EOF
export DEVBRAIN_VERIFY_COMMANDS_FILE="$FILE"
export DEVBRAIN_MIGRATION_BLOCK_FILE="$TMP/migration-block.list"
export DEVBRAIN_BASE_BRANCH_OVERRIDE_FILE="$TMP/base-branch.override"
printf 'prodapp\n' > "$DEVBRAIN_MIGRATION_BLOCK_FILE"
printf 'prodapp=develop\n' > "$DEVBRAIN_BASE_BRANCH_OVERRIDE_FILE"

# ---- 1. a declared repo gets its commands, as Bash() patterns --------------
OUT="$("$DB" verify-tools qaapp)"
[[ "$OUT" == *"Bash(npm run build)"* ]] || fail "qaapp missing npm run build (got: $OUT)"
[[ "$OUT" == *"Bash(npm run lint)"* ]]  || fail "qaapp missing npm run lint (got: $OUT)"
echo "OK: a declared repo gets its declared commands"

# ---- 2. and NOT another repo's commands ------------------------------------
# Without this, a lookup that ignored the project name and returned every line
# would pass assertion 1.
[[ "$OUT" == *"build_docs"* ]] && fail "qaapp leaked companysgc's command"
[[ "$OUT" == *"deno"* ]] && fail "qaapp leaked repoc's command"
echo "OK: a declared repo gets ONLY its own commands"

# ---- 3. an undeclared repo gets nothing, and does not fail -----------------
# The `|| true` regression: grep exits 1 for any repo absent from the file, and
# under set -e/pipefail that can silently kill an entire run through the
# identically-shaped base-branch lookup. Most repos have no line here.
OUT_NONE="$("$DB" verify-tools webapp)"; RC=$?
[ "$RC" -eq 0 ] || fail "undeclared repo must exit 0, got $RC"
[ -z "$(printf '%s' "$OUT_NONE" | tr -d '[:space:]')" ] \
  || fail "undeclared repo must get no extra tools, got: $OUT_NONE"
echo "OK: an undeclared repo gets nothing and exits 0 (the || true regression)"

# ---- 4. the network boundary, everywhere -----------------------------------
grep -qE '^[^#]*=(.*,)?[[:space:]]*(npm install|pip install|deno cache)' "$FILE" \
  && fail "an install command is declared in devbrain-verify.commands"
grep -q 'Bash(npm install)' "$DB" && fail "npm install allowed in devbrain"
grep -q 'Bash(npm run:\*)' "$DB"  && fail "npm run:* allowed in devbrain"
grep -q 'Bash(node:\*)' "$DB"     && fail "node:* allowed in devbrain"
echo "OK: no install command anywhere; npm run:*/node:* still forbidden"

# ---- 5. no wildcard-over-a-binary in the declarations ----------------------
# `deno:*` or `python3:*` would grant arbitrary code execution and defeat the
# whole point of declaring commands per repo.
if grep -vE '^[[:space:]]*(#|$)' "$FILE" | cut -d= -f2- | tr ',' '\n' \
     | grep -qE '^[[:space:]]*[a-zA-Z0-9_.-]+:\*[[:space:]]*$'; then
  fail "a declaration grants a whole binary (e.g. deno:*); use a narrower pattern"
fi
echo "OK: no declaration grants a whole binary"

# ---- 6. read-only remote inspection is global, in BOTH modes ---------------
[ "$(grep -c 'Bash(git fetch:\*)' "$DB")" -ge 2 ] \
  || fail "git fetch missing from plan and/or execute allowlist"
[ "$(grep -c 'Bash(gh pr list:\*)' "$DB")" -ge 2 ] \
  || fail "gh pr list missing from plan and/or execute allowlist"
echo "OK: git fetch and gh pr list present in both plan and execute"

# ---- 7. the execute allowlist actually calls the lookup --------------------
# Assertions 1-3 prove the function works. This proves it is wired in — without
# it, every check above could pass while sessions got nothing.
grep -q 'verify_tools_for "\$PROJECT"' "$DB" \
  || fail "execute allowlist does not call verify_tools_for"
echo "OK: the execute allowlist calls the lookup"

# ---- 8. control: the lookup can actually report something ------------------
# If this file were empty or unreadable, assertions 2-5 would all pass vacuously.
[ -n "$(printf '%s' "$OUT" | tr -d '[:space:]')" ] \
  || fail "control failed: the lookup returned nothing for a declared repo"
echo "OK: control — the lookup does return patterns when a repo declares them"

# ---- 9. @subdir emits a compound cd-then-command pattern -------------------
# Verified empirically against the real Claude Code Bash allowedTools matcher,
# not simulated: `Bash(cd frontend && npm run build)` as an exact
# pattern let that command run, refused `cd frontend && npm run test` (same
# binary, different script) by asking for approval instead of running silently,
# and a `cd ../x` escape was blocked by the harness's own sandbox boundary
# before the allowedTools string even mattered. This is what makes @subdir safe
# to ship, not just plausible.
OUT_PROD="$("$DB" verify-tools prodapp)"
[[ "$OUT_PROD" == *"Bash(cd frontend && npm run build)"* ]] \
  || fail "prodapp missing the frontend build command (got: $OUT_PROD)"
[[ "$OUT_PROD" == *"Bash(cd frontend && npm run test:run)"* ]] \
  || fail "prodapp missing the frontend test:run command (got: $OUT_PROD)"
echo "OK: @subdir emits a compound 'cd <subdir> && <cmd>' pattern"

# ---- 10. a repo with NO @subdir keeps the plain form (regression) ----------
# qaapp's lines have no @; they must not silently grow a `cd .`.
[[ "$(cat "$FILE")" == *'qaapp=npm run build,npm run lint'* ]] \
  || fail "qaapp's declaration was rewritten; it should be untouched"
[[ "$OUT" != *"Bash(cd . && npm run build)"* ]] \
  || fail "a command with no @subdir grew a spurious 'cd .'"
echo "OK: a command with no @subdir is untouched, exactly as before"

# ---- 11. mktapp: a repo whose ONLY package.json lives under a subdir -----
# Modeled on a real shape: a repo with no package.json at its root at all —
# the only one lives under services/support-api/package.json. Without @subdir,
# no command declared for this repo could ever find anything to run.
OUT_MKT="$("$DB" verify-tools mktapp)"
[[ "$OUT_MKT" == *"Bash(cd services/support-api && npm test)"* ]] \
  || fail "mktapp missing its subdir-scoped test command (got: $OUT_MKT)"
echo "OK: a repo whose only package.json is under a subdir gets a working command"

# ---- 12. a subdir escaping the repo is refused NOISILY, not silently -------
# "Noisily" means: printed where a human or the digest can see it (stderr, into
# the execute log), never silently dropped and never let through as if it were
# fine. And it must not corrupt the allowedTools string for the REST of the
# repo's legitimate commands.
TMP_ERR="$(mktemp)"
printf '\nmaligno=npm run build@../etc,npm run lint\n' >> "$FILE"
OUT_BAD="$("$DB" verify-tools maligno 2>"$TMP_ERR" || true)"
[[ "$OUT_BAD" != *"../etc"* ]] || fail "a path-traversal subdir reached the allowedTools string: $OUT_BAD"
[ -s "$TMP_ERR" ] || fail "an escaping subdir was rejected in total silence — no warning anywhere"
grep -qi "\.\.\|outside the repo\|rejected" "$TMP_ERR" \
  || fail "the rejection warning does not explain what was rejected or why"
[[ "$OUT_BAD" == *"Bash(npm run lint)"* ]] \
  || fail "a bad @subdir entry took down the OTHER, legitimate command on the same line"
echo "OK: a path-traversal subdir is rejected loudly, without breaking sibling commands"

# ---- 13. an absolute subdir path is refused the same way ------------------
printf '\nmaligno2=npm run build@/etc,npm run lint\n' >> "$FILE"
OUT_BAD2="$("$DB" verify-tools maligno2 2>"$TMP_ERR" || true)"
[[ "$OUT_BAD2" != *"/etc"* ]] || fail "an absolute subdir reached the allowedTools string: $OUT_BAD2"
[ -s "$TMP_ERR" ] || fail "an absolute-path subdir was rejected in silence"
echo "OK: an absolute subdir path is refused the same way"
rm -f "$TMP_ERR"

# ---- 14. prodapp's OTHER safeguards are untouched by this fixture -----
# Different mechanism entirely (base-branch override + migration write-block in
# bin/devbrain, both config-driven) — this file only touches verify_tools_for.
# Confirm both still exist, since a careless edit to the same file could clobber
# either.
grep -q '^prodapp=develop$' "$DEVBRAIN_BASE_BRANCH_OVERRIDE_FILE" \
  || fail "prodapp's base-branch override (develop, never main) is missing"
grep -qxF "prodapp" "$DEVBRAIN_MIGRATION_BLOCK_FILE" \
  || fail "prodapp's migration-write block is missing"
echo "OK: prodapp's two pre-existing safeguards are untouched"

echo "PASS: devbrain-verify-commands"

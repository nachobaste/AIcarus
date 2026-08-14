#!/bin/bash
# tests/test-devbrain-guardrails.sh — static + behavioral checks on bin/devbrain
set -uo pipefail
export DEVBRAIN_NO_TG=1
DIR="$(cd "$(dirname "$0")/.." && pwd)"
DB="$DIR/bin/devbrain"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1"; exit 1; }

# Isolated fixture config, via env var overrides — never touches the repo's own
# (shipped-empty) devbrain-projects.allow / .override / .list files.
mkdir -p "$TMP/projects/repoa"
git -C "$TMP/projects/repoa" init -q
printf 'repoa\nprodapp\n' > "$TMP/allow"
printf 'prodapp=develop\n' > "$TMP/base-branch.override"
printf '' > "$TMP/verify.commands"
printf 'prodapp\n' > "$TMP/migration-block.list"
export DEVBRAIN_ALLOWFILE="$TMP/allow"
export DEVBRAIN_BASE_BRANCH_OVERRIDE_FILE="$TMP/base-branch.override"
export DEVBRAIN_VERIFY_COMMANDS_FILE="$TMP/verify.commands"
export DEVBRAIN_MIGRATION_BLOCK_FILE="$TMP/migration-block.list"
export DEVBRAIN_PROJECTS_DIR="$TMP/projects"

# 1. arbitrary-exec tools are gone from the execute allowlist
grep -q 'Bash(node:\*)' "$DB" && { echo "FAIL: node:* still allowed"; exit 1; }
grep -q 'Bash(npm run:\*)' "$DB" && { echo "FAIL: npm run:* still allowed"; exit 1; }
grep -q 'Bash(npm install)' "$DB" && { echo "FAIL: npm install still allowed"; exit 1; }
echo "OK: arbitrary exec removed"
grep -q 'Bash(npm test:\*)' "$DB" && echo "OK: npm test kept" || exit 1

# 2. secret paths denied to Read — templated off $HOME, not a literal machine path
grep -q 'Read(//\${HOME#/}/.openclaw/\*\*)' "$DB" && echo "OK: openclaw denied" || exit 1
grep -q 'Read(//\${HOME#/}/.ssh/\*\*)' "$DB" && echo "OK: ssh denied" || exit 1

# 3. timeout wraps the claude calls
grep -q 'with_timeout 2700 claude' "$DB" && echo "OK: execute timeout" || exit 1
grep -q 'with_timeout 900 claude' "$DB" && echo "OK: plan timeout" || exit 1

# 3c. base-branch override lookup must be set -e safe: grep returns 1 for any repo NOT in
# the override file, and with pipefail that would kill the whole run. Regression from a
# real incident where most of a night's tasks died silently for exactly this reason.
# The line must end with `|| true`.
grep -Eq 'OVERRIDE_BRANCH=.*grep .*cut -d= -f2 \|\| true' "$DB" \
  && echo "OK: override lookup is set -e safe (|| true)" \
  || { echo "FAIL: OVERRIDE_BRANCH lookup can kill set -e on no-match"; exit 1; }

# 3d. clean-tree check must ignore .devbrain/ (its own scratch dir) so committed-then-ignored
# plan/task files don't falsely block execution (broke a real production run once already).
grep -q "git status --porcelain | grep -v '\\\\.devbrain/'" "$DB" \
  && echo "OK: clean-tree check ignores .devbrain/" \
  || { echo "FAIL: clean-tree check does not ignore .devbrain/"; exit 1; }

# 3b. adversarial review stage runs (read-only, plan mode) before the PR, and is fail-open
grep -q 'VERDICT:' "$DB" && echo "OK: verifier stage present" || { echo "FAIL: no review/verifier stage"; exit 1; }
grep -q 'NOT REVIEWED' "$DB" && echo "OK: verifier fail-open (PR still created)" || { echo "FAIL: verifier not fail-open"; exit 1; }
# review must be read-only: plan-mode claude calls appear at least twice (the plan stage
# AND the review stage), i.e. the verifier never runs in an edit-capable mode.
[ "$(grep -c -- '--permission-mode plan' "$DB")" -ge 2 ] && echo "OK: review runs read-only (plan mode)" || { echo "FAIL: review not plan-mode"; exit 1; }

# 4. allowlist replaces denylist (behavioral: unknown project rejected with exit 3)
out=$("$DB" plan definitely-not-a-project "x" 2>&1); rc=$?
[ $rc -eq 3 ] && echo "OK: non-allowlisted project rejected (rc=3)" || { echo "FAIL: rc=$rc out=$out"; exit 1; }
grep -v '^#' "$DEVBRAIN_ALLOWFILE" | grep -qxF "repoa" && echo "OK: fixture allowlist seeds repoa" || exit 1

# 5. a production-tier repo (prodapp, in this fixture) is allowed in ONLY together
# with both required safeguards: PRs target develop not main, and migrations are
# never writable by devbrain there. Both are config-driven (devbrain-base-branch.override
# and devbrain-migration-block.list), never a hardcoded repo name inside bin/devbrain.
grep -q '^prodapp=develop$' "$DEVBRAIN_BASE_BRANCH_OVERRIDE_FILE" \
  && echo "OK: prodapp base-branch override -> develop" \
  || { echo "FAIL: prodapp allowlisted but no develop base-branch override"; exit 1; }
grep -qxF "prodapp" "$DEVBRAIN_MIGRATION_BLOCK_FILE" \
  && echo "OK: prodapp listed in the migration-block file" \
  || { echo "FAIL: prodapp allowlisted but not in the migration-block file"; exit 1; }
grep -q 'MIGRATION_BLOCK_FILE' "$DB" && grep -q 'supabase/migrations' "$DB" \
  && echo "OK: bin/devbrain's migration write-block reads that file (config-driven, no hardcoded repo name)" \
  || { echo "FAIL: bin/devbrain does not implement the config-driven migration write-block"; exit 1; }
# and bin/devbrain must NOT hardcode any specific repo name for this safeguard
grep -qE '\[ "\$PROJECT" = "[A-Za-z0-9_-]+" \]' "$DB" \
  && fail "bin/devbrain hardcodes a specific repo name for the migration block instead of reading the config file"
echo "OK: the migration write-block is config-driven, not hardcoded to a repo name"

# 3e. execute must branch off origin/<base> (fetched), not the local possibly-stale base.
# A stale local clone + an old `pull --ff-only || true` produced conflicting PRs once already.
grep -q 'git fetch -q origin "\$DEFAULT_BRANCH"' "$DB" \
  && grep -q 'checkout -q -b "\$BRANCH" "origin/\$DEFAULT_BRANCH"' "$DB" \
  && echo "OK: branches off origin base (no stale-clone conflicts)" \
  || { echo "FAIL: execute may branch off stale local base"; exit 1; }

echo "ALL OK"

#!/bin/bash
# test-config-path.sh — config files live in config/ (or $DEVBRAIN_CONFIG_DIR), and a
# per-file variable still wins. Covers both helpers (lib/config.sh, lib/config_path.py)
# and real readers (bin/devbrain, bin/devbrain-preflight, bin/devbrain-verify-run).
set -uo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
ok=0; bad=0
ck() { if eval "$2"; then ok=$((ok+1)); echo "  ok   $1"; else bad=$((bad+1)); echo "  BAD  $1"; fi; }
unset DEVBRAIN_CONFIG_DIR DEVBRAIN_VERIFY_COMMANDS_FILE DEVBRAIN_ALLOWFILE DEVBRAIN_MC_DIR

# --- helpers -------------------------------------------------------------------
source "$DIR/lib/config.sh"
R="$T/root"; mkdir -p "$R/config" "$T/other"
py() { python3 -c "import sys; sys.path.insert(0, '$DIR/lib'); from config_path import config_path; print(config_path(sys.argv[1], sys.argv[2]))" "$@"; }
for h in config_path py; do
  ck "$h: default is <root>/config/<name>" '[ "$($h x.conf "$R")" = "$R/config/x.conf" ]'
  ck "$h: DEVBRAIN_CONFIG_DIR wins" '[ "$(DEVBRAIN_CONFIG_DIR="$T/other" $h x.conf "$R")" = "$T/other/x.conf" ]'
done
ck "config_path: root defaults to this repo" '[ "$(config_path x.conf)" = "$DIR/config/x.conf" ]'
ck "py: root defaults to this repo" '[ "$(python3 -c "import sys; sys.path.insert(0, \"$DIR/lib\"); from config_path import config_path; print(config_path(\"x.conf\"))")" = "$DIR/config/x.conf" ]'
ck "no config file left at the repo root" '[ -z "$(cd "$DIR" && ls devbrain-projects.allow devbrain-projects.excluded devbrain-base-branch.override devbrain-verify.commands devbrain-migration-block.list 2>/dev/null)" ]'
ck "the shipped files are in config/" '[ -f "$DIR/config/devbrain-projects.allow" ] && [ -f "$DIR/config/devbrain-verify.commands" ] && [ -f "$DIR/config/models.conf" ]'

# --- bin/devbrain: verify-tools reads config/devbrain-verify.commands --------------
K="$T/kit"; mkdir -p "$K/bin" "$K/lib" "$K/config"
cp "$DIR/bin/devbrain" "$K/bin/"; cp "$DIR"/lib/*.sh "$K/lib/"
printf 'demo=npm test\n' > "$K/config/devbrain-verify.commands"
ck "devbrain: config/devbrain-verify.commands is read" 'grep -q "Bash(npm test)" <<<"$("$K/bin/devbrain" verify-tools demo)"'
printf 'demo=npm run lint\n' > "$T/other/devbrain-verify.commands"
ck "devbrain: DEVBRAIN_CONFIG_DIR is read" 'grep -q "Bash(npm run lint)" <<<"$(DEVBRAIN_CONFIG_DIR="$T/other" "$K/bin/devbrain" verify-tools demo)"'
printf 'demo=make check\n' > "$T/one.commands"
ck "devbrain: DEVBRAIN_VERIFY_COMMANDS_FILE still wins over the dir" \
  'grep -q "Bash(make check)" <<<"$(DEVBRAIN_CONFIG_DIR="$T/other" DEVBRAIN_VERIFY_COMMANDS_FILE="$T/one.commands" "$K/bin/devbrain" verify-tools demo)"'
mkdir -p "$K/projects/demo"; git -C "$K/projects/demo" init -q
printf 'demo\n' > "$K/config/devbrain-projects.allow"
out="$(DEVBRAIN_NO_TG=1 DEVBRAIN_PROJECTS_DIR="$K/projects" "$K/bin/devbrain" plan nope x 2>&1)"; rc=$?
ck "devbrain: config/devbrain-projects.allow is the allowlist (rc=$rc)" '[ $rc = 3 ] && grep -q "$K/config/devbrain-projects.allow" <<<"$out"'

# --- bin/devbrain-preflight: reads config/ next to itself ------------------------
P="$T/pf"; mkdir -p "$P/bin" "$P/lib" "$P/config" "$P/queue" "$P/projects/demo"
cp "$DIR/bin/devbrain-preflight" "$DIR/bin/devbrain-verify-run" "$P/bin/"; cp "$DIR"/lib/*.py "$P/lib/"
git -C "$P/projects/demo" init -q
git -C "$P/projects/demo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
printf 'demo\n' > "$P/config/devbrain-projects.allow"
printf 'demo=npm test\n' > "$P/config/devbrain-verify.commands"
printf -- '---\nrepo: demo\nstatus: approved\nprioridad: 10\ncreado: 2026-01-01\naprobado: 2026-01-01\n---\n\nA task.\n' > "$P/queue/10-demo--task.plan.md"
pf() { DEVBRAIN_QUEUE_DIR="$P/queue" DEVBRAIN_PROJECTS_DIR="$P/projects" DEVBRAIN_PREFLIGHT_NO_FETCH=1 "$P/bin/devbrain-preflight" 2>&1; }
out="$(pf)"; rc=$?
ck "preflight: config/ allowlist and verify commands are read (rc=$rc)" '[ $rc = 0 ]'
printf 'other\n' > "$P/config/devbrain-projects.allow"
out="$(pf)"; rc=$?
ck "preflight: and a repo missing from it is caught (rc=$rc)" '[ $rc = 1 ] && grep -q "not in devbrain-projects.allow" <<<"$out"'

# --- bin/devbrain-verify-run: reads config/devbrain-verify.commands ---------------
mkdir -p "$P/projects/demo/sub"; printf '{"scripts":{"probe":"echo probed"}}\n' > "$P/projects/demo/sub/package.json"
printf 'demo=npm run probe@sub\n' > "$P/config/devbrain-verify.commands"
out="$(DEVBRAIN_PROJECTS_DIR="$P/projects" "$P/bin/devbrain-verify-run" demo npm run probe 2>&1)"; rc=$?
ck "verify-run: a command declared in config/ runs (rc=$rc)" '[ $rc = 0 ] && grep -q probed <<<"$out"'

# --- the installation's own repo is still recognized with config/ ------------------
# Both checks are structural (where devbrain-projects.allow lives), so the move to
# config/ must not turn them off.
I="$T/projects/mykit"; mkdir -p "$I/config"; printf 'mykit\n' > "$I/config/devbrain-projects.allow"
git -C "$I" init -q
ck "day_engine: allowlist in <kit>/config/ still marks <kit> as itself" \
  '[ "$(python3 -c "import sys; sys.path.insert(0, \"$DIR/lib\"); import day_engine; print(day_engine.is_self_repo(\"mykit\", \"$I/config/devbrain-projects.allow\"))")" = True ]'
printf '#!/bin/bash\necho called > "%s/called"\n' "$T" > "$T/fake-claude"; chmod +x "$T/fake-claude"
out="$(HOME="$T" RESEARCH_CLAUDE_BIN="$T/fake-claude" RESEARCH_PROJECTS_DIR="$T/projects" RESEARCH_ALLOWFILE="$I/config/devbrain-projects.allow" \
  RESEARCH_WIKI="$T/wiki" RESEARCH_LOG="$T/research.log" RESEARCH_STATE_DIR="$T/state" "$DIR/bin/devbrain-research" mykit 2>&1)"; rc=$?
ck "research: a project with config/devbrain-projects.allow is refused, no model runs (rc=$rc)" \
  '[ $rc = 3 ] && [ ! -e "$T/called" ] && grep -q "installation itself" <<<"$out"'

echo "test-config-path: $ok ok, $bad bad"
[ "$bad" = 0 ]

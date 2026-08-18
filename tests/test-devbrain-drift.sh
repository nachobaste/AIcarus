#!/bin/bash
# tests/test-devbrain-drift.sh — drift between knowledge stores, both directions.
#
# All three checks return zero against the real machine today. That makes this
# suite the only thing standing between "no drift" and "the checker is broken":
# a command that always prints nothing would pass a naively written test file.
# So every detection assertion below is paired with a silence assertion, and a
# fully clean set of stores must come back exit 0.
set -uo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$DIR/bin/devbrain-drift"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1"; exit 1; }

# ---- a clean set of stores, built first ------------------------------------
mkdir -p "$TMP/snap" "$TMP/live" "$TMP/wiki" "$TMP/mem" "$TMP/skills/ok-skill"
printf '# Soul\nbody\n'   > "$TMP/snap/SOUL.md"
printf '# Soul\nbody\n'   > "$TMP/live/SOUL.md"
printf '# Agents\nbody\n' > "$TMP/snap/AGENTS.md"
printf '# Agents\nbody\n' > "$TMP/live/AGENTS.md"
printf '{"runtime":1}'    > "$TMP/live/openclaw-workspace-state.json"   # must be ignored
mkdir -p "$TMP/live/media" && printf 'x' > "$TMP/live/media/a.bin"      # must be ignored
printf '# Página\n\ncuerpo\n' > "$TMP/wiki/ok.md"
printf -- '- [Uno](uno.md) — hook\n' > "$TMP/mem/MEMORY.md"
printf '# Uno\nsecreto-irrepetible-42\n' > "$TMP/mem/uno.md"

# A clean skill: only name+description, no secrets, no planted names, and its
# absolute paths/URLs are all inside the allowlist — this is what the real
# (and, so far, only) skill in the repo looks like.
cat > "$TMP/skills/ok-skill/SKILL.md" <<'EOF'
---
name: ok-skill
description: a clean fixture skill
---

# Ok Skill

Cites ~/dev/wiki/lessons/verificacion-ciega-probar-el-instrumento.md and
~/dev/devbrain/lib/classify.sh as sources, and links to
https://github.com/testowner/machine-config and https://docs.claude.com/en/docs.
EOF

# Fixture name list for the "no person names" sub-check — an invented surname,
# same style test-classify.sh already uses, never a real person.
printf 'Fakesurname Uno\n' > "$TMP/redact-names.txt"

run() { DRIFT_SNAPSHOT="$TMP/snap" DRIFT_LIVE="$TMP/live" \
        DRIFT_WIKI="$TMP/wiki" DRIFT_MEMORY="$TMP/mem" DRIFT_SKILLS="$TMP/skills" \
        NOTION_REDACT_BIN="$DIR/bin/notion-redact.py" \
        CLASSIFY_NAMES_FILE="$TMP/redact-names.txt" \
        "$BIN" "$@"; }

# ---- silence first: clean stores must be clean -----------------------------
# If this fails, every detection assertion below is meaningless.
OUT="$TMP/clean"; run > "$OUT" 2>&1; RC=$?
[ "$RC" -eq 0 ] || fail "clean stores should exit 0, got $RC ($(cat "$OUT"))"
grep -q "drift: 0" "$OUT" || fail "clean stores should report drift: 0"
echo "OK: clean stores report 0 and exit 0 (runtime files ignored)"

# ---- the memory check must never leak file contents ------------------------
# Planted a unique string inside mem/uno.md; it must never reach stdout.
grep -q "secreto-irrepetible-42" "$OUT" && fail "leaked memory file content"
echo "OK: memory check prints no file content"

# ---- 1. openclaw-snapshot, one condition at a time -------------------------
printf '# Heartbeat\nx\n' > "$TMP/live/HEARTBEAT.md"          # live only
run > "$OUT" 2>&1
grep -q $'falta-en-repo\tHEARTBEAT.md' "$OUT" || fail "did not detect file missing from repo"
rm "$TMP/live/HEARTBEAT.md"

printf '# Ghost\nx\n' > "$TMP/snap/GHOST.md"                  # repo only
run > "$OUT" 2>&1
grep -q $'falta-en-vivo\tGHOST.md' "$OUT" || fail "did not detect file missing from live"
rm "$TMP/snap/GHOST.md"

printf '# Soul\nCAMBIADO\n' > "$TMP/live/SOUL.md"             # same name, differs
run > "$OUT" 2>&1
grep -q $'contenido-distinto\tSOUL.md' "$OUT" || fail "did not detect differing content"
printf '# Soul\nbody\n' > "$TMP/live/SOUL.md"
echo "OK: snapshot detects missing-in-repo, missing-in-live and differing content"

# ---- 2. wiki-format --------------------------------------------------------
printf -- '---\nname: x\n---\n\ncuerpo\n' > "$TMP/wiki/bad-fm.md"
run > "$OUT" 2>&1
grep -q $'frontmatter-yaml\tbad-fm.md' "$OUT" || fail "did not detect YAML frontmatter"
rm "$TMP/wiki/bad-fm.md"

printf 'sin titulo\n' > "$TMP/wiki/bad-h1.md"
run > "$OUT" 2>&1
grep -q $'sin-titulo-h1\tbad-h1.md' "$OUT" || fail "did not detect missing H1"
rm "$TMP/wiki/bad-h1.md"
echo "OK: wiki-format detects frontmatter and missing H1"

# ---- 3. memory-index -------------------------------------------------------
printf '# Dos\nx\n' > "$TMP/mem/dos.md"                       # file, no index line
run > "$OUT" 2>&1
grep -q $'huerfano-sin-indice\tdos.md' "$OUT" || fail "did not detect orphan memory file"
rm "$TMP/mem/dos.md"

printf -- '- [Uno](uno.md) — hook\n- [Fantasma](fantasma.md) — hook\n' > "$TMP/mem/MEMORY.md"
run > "$OUT" 2>&1
grep -q $'indice-apunta-a-inexistente\tfantasma.md' "$OUT" || fail "did not detect dangling index line"
printf -- '- [Uno](uno.md) — hook\n' > "$TMP/mem/MEMORY.md"

printf '# Uno\nsecreto-irrepetible-42\nver [[no-existe]]\n' > "$TMP/mem/uno.md"
run > "$OUT" 2>&1
grep -q 'wikilink-no-resuelve' "$OUT" || fail "did not detect unresolved memory wikilink"
printf '# Uno\nsecreto-irrepetible-42\n' > "$TMP/mem/uno.md"
echo "OK: memory-index detects orphans, dangling index lines and bad wikilinks"

# ---- back to clean, to prove the fixtures were really restored -------------
run > "$OUT" 2>&1; RC=$?
[ "$RC" -eq 0 ] || fail "stores should be clean again, got $RC ($(cat "$OUT"))"
echo "OK: stores restored to clean"

# ---- 4. skill-content, one sub-check at a time ------------------------------
# Allowlist checks (not denylist), same principle as devbrain-projects.allow
# and devbrain-verify.commands. ok-skill/SKILL.md (built above) is the silence
# control for all five; each block plants one violation, confirms the check
# catches it, then removes the plant so later blocks start from clean again.

# (a) frontmatter: only name+description allowed
mkdir -p "$TMP/skills/bad-fm"
printf -- '---\nname: bad-fm\ndescription: d\nextra: nope\n---\n\nbody\n' > "$TMP/skills/bad-fm/SKILL.md"
run > "$OUT" 2>&1
grep -q $'frontmatter-clave-extra\tbad-fm/SKILL.md\textra' "$OUT" || fail "did not detect extra frontmatter key"
rm -rf "$TMP/skills/bad-fm"
run > "$OUT" 2>&1; RC=$?
[ "$RC" -eq 0 ] || fail "frontmatter plant did not clean up, got $RC ($(cat "$OUT"))"
echo "OK: skill-content detects an extra frontmatter key, silent once removed"

# (b) no secrets — and the secret itself must never reach stdout
mkdir -p "$TMP/skills/bad-secret"
printf -- '---\nname: bad-secret\ndescription: d\n---\n\nsk-abcdefghij1234567890\n' > "$TMP/skills/bad-secret/SKILL.md"
run > "$OUT" 2>&1
grep -q $'secreto-posible\tbad-secret/SKILL.md' "$OUT" || fail "did not detect a secret-shaped string"
grep -q 'sk-abcdefghij1234567890' "$OUT" && fail "leaked the secret itself onto stdout"
rm -rf "$TMP/skills/bad-secret"
run > "$OUT" 2>&1; RC=$?
[ "$RC" -eq 0 ] || fail "secret plant did not clean up, got $RC ($(cat "$OUT"))"
echo "OK: skill-content detects a secret-shaped string without ever printing it"

# (c) no person names — reuses bin/notion-redact.py, not a second list
mkdir -p "$TMP/skills/bad-name"
printf -- '---\nname: bad-name\ndescription: d\n---\n\nFirma Fakesurname Uno hoy.\n' > "$TMP/skills/bad-name/SKILL.md"
run > "$OUT" 2>&1
grep -q $'nombre-posible\tbad-name/SKILL.md' "$OUT" || fail "did not detect a redactable name"
rm -rf "$TMP/skills/bad-name"
run > "$OUT" 2>&1; RC=$?
[ "$RC" -eq 0 ] || fail "name plant did not clean up, got $RC ($(cat "$OUT"))"
echo "OK: skill-content detects a person name via notion-redact.py"

# (c-infra) a missing names list must skip the sub-check, not fail the run or
# report a finding — same fail-closed-but-don't-crash contract redact_names()
# documents (exit 2 = missing/empty list, exit 3 = missing redactor).
DRIFT_SNAPSHOT="$TMP/snap" DRIFT_LIVE="$TMP/live" DRIFT_WIKI="$TMP/wiki" \
  DRIFT_MEMORY="$TMP/mem" DRIFT_SKILLS="$TMP/skills" \
  NOTION_REDACT_BIN="$DIR/bin/notion-redact.py" \
  CLASSIFY_NAMES_FILE="$TMP/no-such-names-file.txt" \
  "$BIN" > "$OUT" 2>"$TMP/infra-err"; RC=$?
[ "$RC" -eq 0 ] || fail "missing names list should not fail the run, got $RC ($(cat "$OUT"))"
grep -q "nombre-posible" "$OUT" && fail "missing names list should skip the sub-check, not report a finding"
echo "OK: a missing names list skips the name sub-check instead of failing devbrain-drift"

# (d) absolute paths outside ~/dev/wiki/ and ~/dev/devbrain/
mkdir -p "$TMP/skills/bad-path"
printf -- '---\nname: bad-path\ndescription: d\n---\n\nSee /Users/someuser/dev/projects/secret/notes.txt for details.\n' \
  > "$TMP/skills/bad-path/SKILL.md"
run > "$OUT" 2>&1
grep -q $'ruta-fuera-de-alcance\tbad-path/SKILL.md\t/Users/someuser/dev/projects/secret/notes.txt' "$OUT" \
  || fail "did not detect an out-of-scope absolute path"
rm -rf "$TMP/skills/bad-path"
run > "$OUT" 2>&1; RC=$?
[ "$RC" -eq 0 ] || fail "path plant did not clean up, got $RC ($(cat "$OUT"))"
echo "OK: skill-content detects an out-of-scope absolute path, silent on ~/dev/wiki/ and ~/dev/devbrain/"

# (e) URLs outside the domain allowlist — no real skill has a URL today, so
# this canary has to be planted by hand rather than found in the repo.
mkdir -p "$TMP/skills/bad-url"
printf -- '---\nname: bad-url\ndescription: d\n---\n\nSee https://evil.example.com/phish for details.\n' \
  > "$TMP/skills/bad-url/SKILL.md"
run > "$OUT" 2>&1
grep -q $'url-fuera-de-allowlist\tbad-url/SKILL.md\tevil.example.com' "$OUT" || fail "did not detect an out-of-allowlist URL"
rm -rf "$TMP/skills/bad-url"
run > "$OUT" 2>&1; RC=$?
[ "$RC" -eq 0 ] || fail "url plant did not clean up, got $RC ($(cat "$OUT"))"
echo "OK: skill-content detects a URL outside the domain allowlist, silent on github.com/docs.claude.com"

# ---- exit codes and --quiet ------------------------------------------------
printf '# Heartbeat\nx\n' > "$TMP/live/HEARTBEAT.md"
run > "$OUT" 2>&1; RC=$?
[ "$RC" -eq 1 ] || fail "drift should exit 1, got $RC"
run --quiet > "$TMP/q" 2>&1; RCQ=$?
[ "$RCQ" -eq 1 ] || fail "--quiet must keep exit 1, got $RCQ"
[ ! -s "$TMP/q" ] || fail "--quiet must print nothing, got: $(cat "$TMP/q")"
rm "$TMP/live/HEARTBEAT.md"
echo "OK: exit 1 on drift, --quiet keeps the code and prints nothing"

# ---- a missing store is an error, not a false 'clean' ----------------------
DRIFT_SNAPSHOT="$TMP/no-such" DRIFT_LIVE="$TMP/live" \
  DRIFT_WIKI="$TMP/wiki" DRIFT_MEMORY="$TMP/mem" "$BIN" >/dev/null 2>"$TMP/err"; RC=$?
[ "$RC" -eq 2 ] || fail "missing store should exit 2, got $RC"
grep -qi traceback "$TMP/err" && fail "missing store crashed instead of erroring cleanly"
grep -q "DRIFT_SNAPSHOT" "$TMP/err" || fail "the error should name which store is missing"
echo "OK: a missing store exits 2 cleanly and names itself"

echo "PASS: devbrain-drift"

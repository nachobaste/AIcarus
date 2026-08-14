#!/bin/bash
# tests/test-day-engine.sh — the pure engine behind devbrain-day (plan 240) and, later,
# Telegram approval (plan 250). Both interfaces resolve "which proposal" to a TITLE before
# calling this engine — never a list position — so a backlog that changes mid-session can
# never make "dale 2" hit the wrong proposal. This suite is what proves that contract.
set -uo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$DIR/lib/day_engine.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1"; exit 1; }

mkdir -p "$TMP/repo/src" "$TMP/machine-config"
# The allowfile lives inside a directory literally named "machine-config" —
# day_engine.py's self-repo refusal is structural (repo name == basename of the
# allowfile's own directory), not a hardcoded string, so the fixture has to look
# like a real devbrain checkout for this to exercise the same guardrail.
printf 'a\nb\nc\n' > "$TMP/repo/src/uno.js"
printf 'a\nb\nc\n' > "$TMP/repo/src/dos.js"
printf 'demo\n' > "$TMP/machine-config/allow"

BACKLOG="$TMP/backlog.md"
cat > "$BACKLOG" <<'EOF'
# Mejoras propuestas

## 2026-08-08 — demo
### El deploy pierde el segundo intento
- repo: demo
- evidencia: src/uno.js:1
- porque: reintenta sin esperar el rate limit
- tamano: 1 noche

## Propuestas — 2026-08-08
### Arreglar el reintento del deploy
- origen: El deploy pierde el segundo intento
- repo: demo
- esfuerzo: 1 noche
- riesgos: ninguno serio
- verificar: correr el deploy dos veces seguidas

#### Opcion A — parche puntual
- archivos: src/uno.js
- pros: rapido
- contras: no arregla la clase entera

#### Opcion B — arreglo de fondo
- archivos: src/dos.js
- pros: cierra la clase
- contras: mas caro

### Propuesta contra machine-config
- origen: El deploy pierde el segundo intento
- repo: machine-config
- esfuerzo: 1 noche
- riesgos: x
- verificar: y

#### A
- archivos: bin/devbrain

#### B
- archivos: bin/devbrain-night
EOF

eng() { RESEARCH_ALLOWFILE="$TMP/machine-config/allow" python3 "$BIN" "$@"; }

# ---- list --------------------------------------------------------------------
eng list < "$BACKLOG" > "$TMP/list.out"
grep -qxF "Arreglar el reintento del deploy" "$TMP/list.out" || fail "pending proposal missing from list"
grep -qxF "Propuesta contra machine-config" "$TMP/list.out" || fail "second pending proposal missing from list"
echo "OK: list prints every pending title, one per line"

# ---- show ----------------------------------------------------------------
eng show "Arreglar el reintento del deploy" < "$BACKLOG" > "$TMP/show.out" 2>"$TMP/err"
grep -q "Opcion A" "$TMP/show.out" || fail "show did not include the proposal's options"
grep -q "Opcion B" "$TMP/show.out" || fail "show did not include the second option"
echo "OK: show prints the full proposal, including both options"

eng show "No existe" < "$BACKLOG" > /dev/null 2>"$TMP/err"; RC=$?
[ "$RC" -ne 0 ] || fail "show on an unknown title should fail"
echo "OK: show on an unknown title fails, does not print a fabricated proposal"

# ---- render: the happy path first, or every rejection below proves nothing --
eng render "Arreglar el reintento del deploy" < "$BACKLOG" > "$TMP/r.out" 2>"$TMP/err"; RC=$?
[ "$RC" -eq 0 ] || fail "render on an allowed repo should exit 0, got $RC ($(cat "$TMP/err"))"
head -1 "$TMP/r.out" | grep -qx "repo: demo" || fail "render did not report the right repo"
grep -q "^slug: " "$TMP/r.out" || fail "render did not produce a slug line"
grep -q "src/uno.js" "$TMP/r.out" || fail "the default option's files are missing from the body"
grep -q "src/dos.js" "$TMP/r.out" && fail "the non-chosen option's files leaked into the body"
echo "OK: render defaults to Option A and reports repo + slug + body"

eng render "Arreglar el reintento del deploy" --opcion B < "$BACKLOG" > "$TMP/r.out" 2>"$TMP/err"
grep -q "src/dos.js" "$TMP/r.out" || fail "--opcion B did not select option B's files"
grep -q "src/uno.js" "$TMP/r.out" && fail "option A's files leaked when B was chosen"
echo "OK: --opcion B selects option B instead of the default"

# ---- render: machine-config is refused regardless of the allowlist ----------
printf 'demo\nmachine-config\n' > "$TMP/machine-config/allow"
eng render "Propuesta contra machine-config" < "$BACKLOG" > "$TMP/r.out" 2>"$TMP/err"; RC=$?
[ "$RC" -ne 0 ] || fail "a proposal against machine-config was rendered as approvable"
[ ! -s "$TMP/r.out" ] || fail "machine-config render produced output on stdout"
printf 'demo\n' > "$TMP/machine-config/allow"
echo "OK: machine-config is refused even if present in the allowlist"

# ---- render: an unlisted repo is refused ------------------------------------
sed 's/repo: demo/repo: no-listado/' "$BACKLOG" > "$TMP/backlog-otro.md"
eng render "Arreglar el reintento del deploy" < "$TMP/backlog-otro.md" > "$TMP/r.out" 2>"$TMP/err"; RC=$?
[ "$RC" -ne 0 ] || fail "a proposal for a repo outside the allowlist was rendered as approvable"
echo "OK: a repo outside the allowlist is refused"

# ---- mark: dale --------------------------------------------------------------
eng mark "Arreglar el reintento del deploy" dale < "$BACKLOG" > "$TMP/marked.md" 2>"$TMP/err"; RC=$?
[ "$RC" -eq 0 ] || fail "mark dale should exit 0, got $RC"
awk '/^### Arreglar el reintento del deploy$/{f=1} f && /^### /&&!/Arreglar el reintento/{f=0} f' "$TMP/marked.md" \
  | grep -q "^- decision: aprobada$" || fail "the decided proposal is missing its decision line"
grep -q "^### Propuesta contra machine-config$" "$TMP/marked.md" || fail "mark destroyed an unrelated proposal"
grep -q "^### El deploy pierde el segundo intento$" "$TMP/marked.md" || fail "mark destroyed the raw finding underneath"
echo "OK: mark dale adds the decision line without touching anything else"

# a second mark on an already-decided title is refused, not silently reapplied
eng mark "Arreglar el reintento del deploy" dale < "$TMP/marked.md" > /dev/null 2>"$TMP/err"; RC=$?
[ "$RC" -ne 0 ] || fail "marking an already-decided proposal again should fail"
echo "OK: an already-decided proposal cannot be marked twice"

# ---- mark: no requires a motivo ----------------------------------------------
eng mark "Propuesta contra machine-config" no < "$BACKLOG" > /dev/null 2>"$TMP/err"; RC=$?
[ "$RC" -ne 0 ] || fail "mark no without a motivo should be refused"
echo "OK: discarding without a motivo is refused"

eng mark "Propuesta contra machine-config" no --motivo "no aplica a este repo" < "$BACKLOG" > "$TMP/marked2.md" 2>"$TMP/err"
grep -q "decision: descartada.*no aplica a este repo" "$TMP/marked2.md" \
  || fail "the discard motivo was not recorded: $(grep decision "$TMP/marked2.md")"
echo "OK: discarding with a motivo records it verbatim"

# ---- mark: an unknown decision word is rejected, not treated as anything ----
eng mark "Arreglar el reintento del deploy" quizas < "$BACKLOG" > /dev/null 2>"$TMP/err"; RC=$?
[ "$RC" -ne 0 ] || fail "an unrecognised decision word should be refused"
echo "OK: an unrecognised decision word is refused, not guessed at"

echo "PASS: day-engine"

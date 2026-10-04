#!/bin/bash
# tests/test-redact.sh — exercises bin/notion-redact.py (the person-name redactor
# devbrain-drift uses).
set -uo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
redact_names() { python3 "$DIR/bin/notion-redact.py" --text; }

# redact_names — the name list lives OUTSIDE this repo (see Global Constraints).
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export CLASSIFY_NAMES_FILE="$TMP/redact-names.txt"

# MUST-FAIL FIRST: with no name list, redaction refuses AND emits nothing.
# Checking only the exit code is not enough — a `cat; return 2` implementation
# would leak every byte and still exit 2. Assert on stdout, not just status.
leak="$(printf 'SECRETPAYLOAD\n' | redact_names 2>/dev/null)"; rc=$?
[ "$rc" -eq 2 ] && echo "OK: missing name list refuses with exit 2" || \
  { echo "FAIL: expected exit 2, got $rc"; exit 1; }
[ -z "$leak" ] && echo "OK: and emits nothing on stdout" || \
  { echo "FAIL: leaked stdout with no name list: $leak"; exit 1; }

printf 'anything\n' > "$CLASSIFY_NAMES_FILE"  # non-empty but matches nothing
printf 'Zzz Qqq\n' | redact_names >/dev/null 2>&1
[ $? -eq 0 ] && echo "OK: a present list allows redaction to run" || exit 1

# Now a realistic list. These are invented surnames, not real people — the real
# list is the owner's and lives only in ~/.config/devbrain/secrets/.
printf 'Fakesurname Uno\nSegundoapellido\n' > "$CLASSIFY_NAMES_FILE"
out="$(printf 'Responsable: Maria Jose Fakesurname Uno firma G2\n' | redact_names)"
case "$out" in
  *Fakesurname*) echo "FAIL: name survived redaction"; exit 1 ;;
  *"[puesto]"*)  echo "OK: name redacted to placeholder" ;;
  *) echo "FAIL: unexpected output: $out"; exit 1 ;;
esac
out="$(printf 'Director Financiero de Proyectos aprueba\n' | redact_names)"
[ "$out" = "Director Financiero de Proyectos aprueba" ] \
  && echo "OK: job titles pass through untouched" || exit 1

# --- regressions for the five findings the first review of this task raised ---

# (1) ALL-CAPS must still be redacted. Real documents in this corpus have
# ALL-CAPS names and project titles (e.g. "PROYECTO ALFA", "CIUDAD EJEMPLO"),
# and institutional signature blocks are routinely uppercase.
out="$(printf 'Firma FAKESURNAME UNO hoy\n' | redact_names)"
case "$out" in *FAKESURNAME*) echo "FAIL: ALL-CAPS name leaked"; exit 1 ;; esac
echo "OK: ALL-CAPS name redacted"

# (3) A job title immediately before a name must survive — only the name goes.
out="$(printf 'El Presidente Ejecutivo Fakesurname Uno aprobo\n' | redact_names)"
case "$out" in
  *"Presidente Ejecutivo"*) echo "OK: preceding job title survives" ;;
  *) echo "FAIL: over-captured the title: $out"; exit 1 ;;
esac
case "$out" in *Fakesurname*) echo "FAIL: name leaked"; exit 1 ;; esac

# (4) A name wrapped across two lines must still be caught.
out="$(printf 'Firmado por Fakesurname\nUno el lunes\n' | redact_names)"
case "$out" in *Fakesurname*) echo "FAIL: line-wrapped name leaked"; exit 1 ;; esac
echo "OK: line-wrapped name redacted"

# (5) Irregular whitespace (tab, double space) must still be caught.
out="$(printf 'Firma Fakesurname\tUno y Fakesurname  Uno\n' | redact_names)"
case "$out" in *Fakesurname*) echo "FAIL: irregular whitespace leaked"; exit 1 ;; esac
echo "OK: tab and double-space separated names redacted"

# (6) A regex metacharacter in the names file is a literal, not a wildcard.
printf 'A.C\n' > "$CLASSIFY_NAMES_FILE"
out="$(printf 'AXC no es A.C\n' | redact_names)"
case "$out" in
  *AXC*) echo "OK: metacharacter treated as literal" ;;
  *) echo "FAIL: '.' matched as a wildcard: $out"; exit 1 ;;
esac

# (8) A short entry must not shred unrelated words. Regression for a verified
# case: "Ana" turned bananas/analisis/Panama into b[puesto]nas/[puesto]lisis/
# P[puesto]ma.
printf 'Ana\n' > "$CLASSIFY_NAMES_FILE"
out="$(printf 'Compramos bananas para el analisis en Panama\n' | redact_names)"
[ "$out" = "Compramos bananas para el analisis en Panama" ] \
  && echo "OK: short name does not match inside other words" \
  || { echo "FAIL: over-redacted: $out"; exit 1; }
out="$(printf 'Firma Ana hoy\n' | redact_names)"
case "$out" in *"[puesto]"*) echo "OK: the standalone name is still redacted" ;;
  *) echo "FAIL: word-boundary anchoring broke real redaction: $out"; exit 1 ;; esac

echo "ALL OK"

#!/bin/bash
# tests/test-schedule.sh — exercises lib/schedule.sh (pure schedule matching)
set -uo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$DIR/lib/schedule.sh"
fails=0
ck() { # <desc> <expected_rc> <schedule> <dow> <dom> <month> <hour>
  local desc="$1" want="$2"; shift 2
  schedule_is_due "$@"; local got=$?
  if [ "$got" = "$want" ]; then echo "OK: $desc"; else echo "FAIL: $desc (want rc=$want got rc=$got)"; fails=$((fails+1)); fi
}

# daily
ck "daily:12 vence a las 12"            0 "daily:12"        3 15 7 12
ck "daily:12 no vence a las 13"         1 "daily:12"        3 15 7 13
ck "daily:6,14 vence a las 6"           0 "daily:6,14"      3 15 7 6
ck "daily:6,14 vence a las 14"          0 "daily:6,14"      3 15 7 14
ck "daily:6,14 no vence a las 10"       1 "daily:6,14"      3 15 7 10

# weekly (1=lunes)
ck "weekly:1:8 vence lunes 8h"          0 "weekly:1:8"      1 15 7 8
ck "weekly:1:8 no vence martes 8h"      1 "weekly:1:8"      2 15 7 8
ck "weekly:1:8 no vence lunes 9h"       1 "weekly:1:8"      1 15 7 9

# monthly
ck "monthly:1:2 vence el 1 a las 2"     0 "monthly:1:2"     4 1  7 2
ck "monthly:1:2 no vence el 2"          1 "monthly:1:2"     5 2  7 2
ck "monthly:20:8 vence el 20 a las 8"   0 "monthly:20:8"    3 20 7 8

# quarterly
ck "quarterly ene vence"                0 "quarterly:1,4,7,10:1:6" 4 1 1 6
ck "quarterly jul vence"                0 "quarterly:1,4,7,10:1:6" 4 1 7 6
ck "quarterly ago NO vence"             1 "quarterly:1,4,7,10:1:6" 4 1 8 6

# formato inválido → rc 2, nunca 0 (un manifiesto roto no debe disparar nada)
ck "formato desconocido es invalido"    2 "cada-rato"       3 15 7 12
ck "daily sin hora es invalido"         2 "daily:"          3 15 7 12
ck "vacio es invalido"                  2 ""                3 15 7 12

# no se confunde 1 (hora) con 10/11/12 — bug clásico de matcheo por substring
ck "daily:1 no vence a las 10"          1 "daily:1"         3 15 7 10
ck "daily:1 no vence a las 12"          1 "daily:1"         3 15 7 12
ck "daily:1 vence a la 1"               0 "daily:1"         3 15 7 1

# `manual` nunca vence, pero tampoco es inválido: si devolviera 2 el despachador
# lo reportaría como manifiesto roto en cada corrida.
ck "manual nunca vence"                 1 "manual"          3 15 7 12
ck "manual tampoco vence a otra hora"   1 "manual"          1 1 1 0
ck "manual no es formato invalido"      1 "manual"          7 31 12 23

[ "$fails" = "0" ] && { echo "PASS (todos)"; exit 0; } || { echo "FAILED: $fails"; exit 1; }

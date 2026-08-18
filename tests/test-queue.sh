#!/bin/bash
# tests/test-queue.sh
set -uo pipefail
export DEVBRAIN_NO_TG=1
DIR="$(cd "$(dirname "$0")/.." && pwd)"
export DEVBRAIN_QUEUE_DIR="$(mktemp -d)"; trap 'rm -rf "$DEVBRAIN_QUEUE_DIR"' EXIT
Q="$DIR/bin/devbrain-queue"
source "$DIR/lib/queue.sh"

"$Q" add repoa "agregar función que reste" >/dev/null
f=$(ls "$DEVBRAIN_QUEUE_DIR"/*.plan.md | head -1)
[ -n "$f" ] && echo "OK: add creates file" || exit 1
[ "$(fm_get "$f" repo)" = "repoa" ] && echo "OK: repo set" || exit 1
[ "$(fm_get "$f" status)" = "requested" ] && echo "OK: status requested (approval only via interview)" || exit 1
basename "$f" | grep -qE '^10-repoa--agregar-funci' && echo "OK: NN + slug naming" || { basename "$f"; exit 1; }

"$Q" add repoa "otra tarea" >/dev/null
f2=$(ls "$DEVBRAIN_QUEUE_DIR"/20-*.plan.md 2>/dev/null | head -1)
[ -n "$f2" ] && echo "OK: second file gets NN=20" || exit 1

# capture-then-grep: grep -q + pipefail turns list's SIGPIPE into a false failure
out=$("$Q" list)
echo "$out" | grep -q "requested" && echo "OK: list shows status" || exit 1
"$Q" pause "$(basename "$f")"
[ "$(fm_get "$f" status)" = "paused" ] && echo "OK: pause" || exit 1
"$Q" resume "$(basename "$f")"
[ "$(fm_get "$f" status)" = "requested" ] && echo "OK: resume restores requested" || exit 1
echo "ALL OK"

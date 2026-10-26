#!/bin/bash
# tests/_night_gate_probe.sh — support for tests/test-queue-premise-gate.sh, not run on its own.
#
# Extracts next_plan() FROM THE REAL TEXT of bin/devbrain-night and evaluates it, instead of
# reimplementing it. A test that rewrites the predicate it audits passes even when the real one is broken.
[ -z "${OPENCLAW_CLI+x}" ] && [ "${OPENCLAW_SHELL-}" != exec ] || { echo "FAIL: these tests do not run under OpenClaw" >&2; exit 1; }
set -uo pipefail
ROOT="${PROBE_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"   # PROBE_ROOT: a mutated copy of the tree
. "$ROOT/lib/queue.sh"                       # fm_get, queue_premisas_ok
QUEUE_DIR="${DEVBRAIN_QUEUE_DIR:?}"
eval "$(awk '/^next_plan\(\) \{/,/^\}/' "$ROOT/bin/devbrain-night")"
p=$(next_plan) && basename "$p" || true

#!/bin/bash
# tests/test-night.sh — runner dry-run with a stubbed devbrain
set -uo pipefail
export DEVBRAIN_NO_TG=1
DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export DEVBRAIN_QUEUE_DIR="$TMP/queue" DEVBRAIN_PROJECTS_DIR="$TMP/projects" DEVBRAIN_NIGHT_FORCE=1
export DEVBRAIN_NIGHT_LOG="$TMP/night.log"   # never pollute the production log from tests
mkdir -p "$TMP/queue" "$TMP/projects/repoa" "$TMP/projects/otro"
source "$DIR/lib/queue.sh"

mkplan() { # <file> <repo> <status> <approved:0|1>
  { echo "---"; echo "repo: $2"; echo "status: $3"; echo "prioridad: ${1%%-*}"
    echo "creado: 2026-07-18"; [ "$4" = 1 ] && echo "aprobado: 2026-07-18"
    echo "---"; echo "plan body for $2"; } > "$DEVBRAIN_QUEUE_DIR/$1"
}
mkplan "10-repoa--a.plan.md" repoa approved 1
mkplan "20-otro--b.plan.md"        otro         approved 1
mkplan "30-repoa--c.plan.md" repoa approved 0   # approved but NO aprobado: line
mkplan "40-repoa--d.plan.md" repoa requested 0

# stub devbrain: first repo succeeds, second fails, third hits the real-world
# Max session-limit message (must trigger the quota-pause path, not failed)
cat > "$TMP/devbrain-stub" <<'EOF'
#!/bin/bash
[ "$1" = "execute" ] || exit 9
echo "$2" >> "$STUB_STATE/stub-calls.log"
case "$2" in
  repoa) echo "PR ready for review: https://github.com/x/repoa/pull/7"; exit 0 ;;
  otro)         echo "boom: tests failed"; exit 1 ;;
  quota)        if [ -f "$STUB_STATE/quota-hit" ]; then
                  echo "PR ready for review: https://github.com/x/quota/pull/9"; exit 0
                else
                  touch "$STUB_STATE/quota-hit"
                  echo "You've hit your session limit · resets 11:30pm (America/Guatemala)"; exit 1
                fi ;;
  bloqueado)    mkdir -p "$PROJECTS_DIR_FOR_STUB/bloqueado/.devbrain"
                echo "deno lint" > "$PROJECTS_DIR_FOR_STUB/bloqueado/.devbrain/blocked-by.txt"
                echo "BLOQUEADO: deno lint"; exit 9 ;;
esac
EOF
chmod +x "$TMP/devbrain-stub"
export DEVBRAIN_BIN="$TMP/devbrain-stub" STUB_STATE="$TMP" DEVBRAIN_QUOTA_PAUSE=1 PROJECTS_DIR_FOR_STUB="$DEVBRAIN_PROJECTS_DIR"
mkplan "70-quota--q.plan.md" quota approved 1
mkdir -p "$TMP/projects/quota"

# stale-running plan from a dead previous runner must be failed at start, not skipped forever
mkplan "05-repoa--stale.plan.md" repoa running 1

bash "$DIR/bin/devbrain-night" >/dev/null 2>&1

[ "$(fm_get "$DEVBRAIN_QUEUE_DIR/05-repoa--stale.plan.md" status)" = "failed" ] && echo "OK: stale running -> failed" || exit 1
fm_get "$DEVBRAIN_QUEUE_DIR/05-repoa--stale.plan.md" motivo_fallo | grep -q "stale" && echo "OK: stale motivo recorded" || exit 1
[ ! -d "$DEVBRAIN_QUEUE_DIR/.night.lock" ] && echo "OK: lock released on exit" || exit 1

# a second instance while the lock is held must exit 0 without touching the queue
mkdir "$DEVBRAIN_QUEUE_DIR/.night.lock"
mkplan "90-repoa--locked.plan.md" repoa approved 1
bash "$DIR/bin/devbrain-night" >/dev/null 2>&1
[ "$(fm_get "$DEVBRAIN_QUEUE_DIR/90-repoa--locked.plan.md" status)" = "approved" ] && echo "OK: lock blocks second instance" || exit 1
rmdir "$DEVBRAIN_QUEUE_DIR/.night.lock"
rm "$DEVBRAIN_QUEUE_DIR/90-repoa--locked.plan.md"

[ "$(fm_get "$DEVBRAIN_QUEUE_DIR/10-repoa--a.plan.md" status)" = "done" ] && echo "OK: success -> done" || exit 1
[ "$(fm_get "$DEVBRAIN_QUEUE_DIR/10-repoa--a.plan.md" pr)" = "https://github.com/x/repoa/pull/7" ] && echo "OK: PR url recorded" || exit 1
[ "$(fm_get "$DEVBRAIN_QUEUE_DIR/20-otro--b.plan.md" status)" = "failed" ] && echo "OK: failure -> failed, night continued" || exit 1
fm_get "$DEVBRAIN_QUEUE_DIR/20-otro--b.plan.md" motivo_fallo | grep -q "exit 1" && echo "OK: motivo_fallo recorded" || exit 1
[ "$(fm_get "$DEVBRAIN_QUEUE_DIR/30-repoa--c.plan.md" status)" = "approved" ] && echo "OK: no-aprobado line refused" || exit 1
[ "$(fm_get "$DEVBRAIN_QUEUE_DIR/40-repoa--d.plan.md" status)" = "requested" ] && echo "OK: requested untouched" || exit 1
[ -f "$DEVBRAIN_QUEUE_DIR/night-report-latest.md" ] && echo "OK: night report written" || exit 1
grep -q "pull/7" "$DEVBRAIN_QUEUE_DIR/night-report-latest.md" && echo "OK: report lists the PR" || exit 1
# plan body was staged into the project's .devbrain dir
grep -q "plan body for repoa" "$DEVBRAIN_PROJECTS_DIR/repoa/.devbrain/plan-latest.md" && echo "OK: plan staged for execute" || exit 1

# session-limit message → pause + retry (NOT failed); succeeds on second attempt
[ "$(fm_get "$DEVBRAIN_QUEUE_DIR/70-quota--q.plan.md" status)" = "done" ] && echo "OK: session limit -> pause -> retry -> done" || { echo "FAIL: quota plan = $(fm_get "$DEVBRAIN_QUEUE_DIR/70-quota--q.plan.md" status)"; exit 1; }
grep -q "quota limit" "$DEVBRAIN_QUEUE_DIR/night-report-latest.md" && echo "OK: report shows quota pause" || exit 1
# ---- blocked (plan 290, D4/D5): a missing permission is 'blocked', not 'failed' --
mkplan "80-bloqueado--b.plan.md" bloqueado approved 1
mkdir -p "$TMP/projects/bloqueado"
bash "$DIR/bin/devbrain-night" >/dev/null 2>&1

[ "$(fm_get "$DEVBRAIN_QUEUE_DIR/80-bloqueado--b.plan.md" status)" = "blocked" ] \
  && echo "OK: a missing permission -> status blocked, not failed" || exit 1
[ "$(fm_get "$DEVBRAIN_QUEUE_DIR/80-bloqueado--b.plan.md" bloqueado_por)" = "deno lint" ] \
  && echo "OK: bloqueado_por records the exact missing command" || exit 1
grep -q "bloqueado" "$DEVBRAIN_QUEUE_DIR/night-report-latest.md" \
  && echo "OK: the night report mentions the blocked task" || exit 1

# The D4 test: a SECOND night run must NOT retry it. next_plan() only selects
# status=approved, and 'blocked' is not that — this proves it end to end (the stub
# was never invoked again), not just by reading next_plan()'s filter and assuming
# it applies here too.
: > "$TMP/stub-calls.log"
bash "$DIR/bin/devbrain-night" >/dev/null 2>&1
grep -q '^bloqueado$' "$TMP/stub-calls.log" \
  && { echo "FAIL: the blocked plan was executed again on a second night"; exit 1; }
[ "$(fm_get "$DEVBRAIN_QUEUE_DIR/80-bloqueado--b.plan.md" status)" = "blocked" ] \
  && echo "OK: a blocked plan is never re-executed on a later night, status stays blocked" || exit 1

echo "ALL OK"

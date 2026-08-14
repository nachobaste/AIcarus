#!/bin/bash
# lib/queue.sh — frontmatter helpers for queue plan files + portable timeout.
# Frontmatter = the block between the first two '---' lines. Keys are single-line.

fm_get() { # <file> <key> -> prints value (empty if absent)
  awk -v k="$2" '
    NR==1 && $0=="---" {infm=1; next}
    infm && $0=="---" {exit}
    infm && index($0, k": ")==1 {print substr($0, length(k)+3); exit}
  ' "$1"
}

queue_file_age_days() { # <file> -> integer days since last write (mtime), portable BSD/GNU.
  # NOT a "since blocked" timestamp: nothing in this codebase records the moment a
  # plan transitions to status: blocked (bin/devbrain-night only writes `status` and
  # `bloqueado_por`, no date). mtime is the closest honest proxy available without
  # inventing a new field: devbrain-night's two fm_set calls rewrite the file at the
  # exact moment it blocks it, and a blocked plan is never retried/rewritten
  # afterwards, so in practice mtime often IS the block moment.
  # But it is still a proxy, not a recorded fact — any later edit to the same file
  # (by hand, by tooling) would silently reset the clock with no way to detect it.
  # Callers must present this as an estimate ("~N days"), never as a confirmed date.
  local f="$1" mtime now
  mtime="$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null)" || return 1
  [ -n "$mtime" ] || return 1
  now="$(date +%s)"
  echo $(( (now - mtime) / 86400 ))
}

fm_set() { # <file> <key> <value> -> replace key, or insert before closing ---
  local f="$1" k="$2" v="$3" tmp
  tmp="$(mktemp)"
  awk -v k="$k" -v v="$v" '
    NR==1 && $0=="---" {infm=1; print; next}
    infm==1 && $0=="---" {if (!done) {print k": "v; done=1}; infm=2; print; next}
    infm==1 && index($0, k": ")==1 {print k": "v; done=1; next}
    {print}
  ' "$f" > "$tmp" && mv "$tmp" "$f"
}

queue_next_nn() { # <queue_dir> -> next NN (max existing +10), shared by devbrain-queue and devbrain-day
  local qdir="$1" max=0 nn f
  for f in "$qdir"/*.plan.md; do
    [ -e "$f" ] || continue
    nn=$(basename "$f" | cut -d- -f1)
    case "$nn" in (*[!0-9]*) continue;; esac
    [ "$nn" -gt "$max" ] && max=$nn
  done
  echo $((max + 10))
}

queue_slugify() { # <text> -> lowercase-hyphen slug, same rule devbrain-queue add already used
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | cut -c1-40 | sed 's/^-//;s/-$//'
}

queue_blocked_command() { # <project_dir> -> the exact command a session couldn't run,
  # or nothing. The ONE reader of .devbrain/blocked-by.txt — bin/devbrain and
  # bin/devbrain-night both call this, so they can never disagree about what counts
  # as blocked. An empty file is not a block: a session that touched the file
  # without naming a real command leaves nothing to act on.
  local f="$1/.devbrain/blocked-by.txt" content
  [ -f "$f" ] || return 0
  content="$(cat "$f" 2>/dev/null)"
  [ -n "$(printf '%s' "$content" | tr -d '[:space:]')" ] && printf '%s' "$content"
  return 0
}

queue_commit_and_push() { # <queue_dir> <message> -> commit+push queue_dir if it's in a git repo; NEVER fails the caller
  local qdir="$1" msg="$2" root out rc=0
  root="$(cd "$qdir" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null)" || return 0
  out="$( (cd "$root" \
    && git add "$qdir" \
    && { git diff --cached --quiet -- "$qdir" || git commit -q -m "$msg"; } \
    && git push -q origin main) 2>&1 )" || rc=$?
  [ "$rc" -ne 0 ] && echo "queue_commit_and_push: WARN (rc=$rc, continuing anyway): $out" >&2
  return 0
}

with_timeout() { # <seconds> <cmd...>  (stdin passes through; returns 124 on kill)
  # Polling loop in THIS shell, no backgrounded watchdog process at all — macOS
  # ships bash 3.2 as /bin/bash (shebang execs it directly, ignoring PATH), which
  # has no `wait -n`, and a subshell cannot `wait` on a PID it didn't fork itself
  # (it's a sibling, not a child) so a background `sleep`-based watchdog can
  # neither be awaited nor reliably killed from a helper subshell. An earlier
  # version backgrounded a `sleep $secs` watchdog; when the guarded command
  # finished early, killing the watchdog's wrapper subshell left the `sleep`
  # itself orphaned (reparented to init) — it kept running for the rest of its
  # duration and then fired a stale `kill -TERM` at whatever PID had since been
  # recycled, killing an unrelated process minutes after the real work had
  # already finished cleanly. A polling loop forks nothing but the guarded
  # command, so there is nothing left to orphan.
  local secs="$1"; shift
  # <&0 is load-bearing: bash gives background jobs /dev/null stdin unless
  # explicitly redirected, which would starve piped-in prompts.
  "$@" <&0 &
  local cmd=$! waited=0
  while kill -0 "$cmd" 2>/dev/null; do
    if [ "$waited" -ge "$secs" ]; then
      kill -TERM "$cmd" 2>/dev/null
      wait "$cmd" 2>/dev/null
      return 124
    fi
    sleep 1
    waited=$((waited + 1))
  done
  wait "$cmd"
}

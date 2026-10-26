#!/bin/bash
# lib/queue.sh — frontmatter helpers for queue plan files + portable timeout.
# Frontmatter = the block between the first two '---' lines. Keys are single-line.

# BSD stat (macOS) and GNU stat (Linux) take different flags, and `stat -f` on GNU means
# "filesystem status", so trying one and falling back to the other is wrong: decide by OS.
if [ "$(uname -s)" = Darwin ]; then
  file_mode()  { stat -f %Lp "$1"; }   # <file> -> octal permission bits
  file_mtime() { stat -f %m "$1"; }    # <file> -> mtime, epoch seconds
else
  file_mode()  { stat -c %a "$1"; }
  file_mtime() { stat -c %Y "$1"; }
fi

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
  mtime="$(file_mtime "$f" 2>/dev/null)" || return 1
  [ -n "$mtime" ] || return 1
  now="$(date +%s)"
  echo $(( (now - mtime) / 86400 ))
}

fm_set() { # <file> <key> <value> -> replace key, or insert before closing ---
  # Frontmatter is single-line per key, and the value is attacker-shaped input (it can come
  # from an agent or from text a person typed into a chat), so it must never be able to start
  # a new line of the frontmatter. Two holes closed:
  #  * every line separator Python's str.splitlines() knows (LF, VT, FF, CR, FS, GS, RS,
  #    U+0085, U+2028, U+2029; CRLF counts as one) is joined with " ‖ ", not just LF. Tools
  #    that parse a plan with splitlines() would otherwise see a second key. A caller that
  #    needs to read the pieces back splits on " ‖ " (see devbrain-preflight).
  #  * the value reaches awk through the environment, so awk does not interpret backslash
  #    escapes in it (`-v v=...` turns a literal \n into a newline).
  # The flattening runs under LC_ALL=C on purpose: BSD awk's regex does not match the
  # multi-byte separators (U+0085/U+2028/U+2029) in a UTF-8 locale. In valid UTF-8 those byte
  # sequences cannot match inside another character, so the result is the same.
  # The write goes to a temp file next to the plan and is renamed over it: the mode is kept,
  # a hard link to a file outside the queue is replaced instead of rewritten, and no temp file
  # is left behind on failure. Nothing here installs an EXIT handler: the night runner owns
  # the one that releases its lock.
  local f="$1" k="$2" v tmp mode
  v="$(printf '%s' "$3" | LC_ALL=C awk '
    { sub(/\015$/, ""); gsub(/\013|\014|\015|\034|\035|\036|\302\205|\342\200\250|\342\200\251/, " \342\200\226 ")
      printf "%s%s", (n++ ? " \342\200\226 " : ""), $0 }')"
  tmp="$(mktemp "$(dirname "$f")/.fm_set.XXXXXX")" || return 1
  mode="$(file_mode "$f" 2>/dev/null)"
  if FM_VALUE="$v" awk -v k="$k" '
    NR==1 && $0=="---" {infm=1; print; next}
    infm==1 && $0=="---" {if (!done) {print k": "ENVIRON["FM_VALUE"]; done=1}; infm=2; print; next}
    infm==1 && index($0, k": ")==1 {print k": "ENVIRON["FM_VALUE"]; done=1; next}
    {print}
  ' "$f" > "$tmp" && chmod "${mode:-644}" "$tmp" && mv "$tmp" "$f"; then return 0; fi
  rm -f "$tmp"; return 1
}

fm_del() { # <file> <key> -> remove the key from the frontmatter (no-op if absent)
  local tmp; tmp="$(mktemp)"
  awk -v k="$2" '
    NR==1 && $0=="---" {infm=1; print; next}
    infm==1 && $0=="---" {infm=2; print; next}
    infm==1 && index($0, k": ")==1 {next}
    {print}
  ' "$1" > "$tmp" && mv "$tmp" "$1"
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

queue_blocked_command() { # <project_dir> -> the PROGRAM of each command a session couldn't
  # run (one per line), or nothing. The ONE reader of .devbrain/blocked-by.txt — bin/devbrain
  # and bin/devbrain-night both call this, so they can never disagree about what counts as
  # blocked. An empty file is not a block: a session that touched the file without naming a
  # real command leaves nothing to act on.
  #
  # It returns only the first token after the `VAR=value` prefixes, or [HIDDEN] when what is
  # left has no program-name shape (a quote, a $(...), an = ...). The full line can carry a
  # password (`PGPASSWORD=... psql ...`) and nothing detects that shape, and this value goes to
  # the frontmatter, the queue's commit message, Telegram and the night report. The full
  # command stays on this machine's disk, in .devbrain/blocked-by.txt, until the next run of
  # that repo.
  local f="$1/.devbrain/blocked-by.txt" line out="" prog
  local dq='^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*="([^"\\]|\\.)*"([[:space:]]+|$)'
  local sq="^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*='[^']*'([[:space:]]+|\$)"
  local plain='^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=[^[:space:]"'"'"'\\]*([[:space:]]+|$)'
  [ -f "$f" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$(printf '%s' "$line" | tr -d '[:space:]')" ] || continue
    while [[ "$line" =~ $dq ]] || [[ "$line" =~ $sq ]] || [[ "$line" =~ $plain ]]; do
      line="${line:${#BASH_REMATCH[0]}}"
    done
    prog="${line#"${line%%[![:space:]]*}"}"; prog="${prog%%[[:space:]]*}"
    [[ "$prog" =~ ^[A-Za-z0-9_./+@-]+$ ]] || prog="[HIDDEN]"
    out="${out:+$out$'\n'}$prog"
  done < "$f"
  printf '%s' "$out"
  return 0
}

# ABSOLUTE path of lib/queue_filter.py, resolved when this file is LOADED and not when a
# function runs: a later `cd` by the caller neither changes it nor lets a queue_filter.py in
# another directory take its place. Empty when it cannot be resolved (zsh, where BASH_SOURCE
# is empty): the filter then fails closed (rc 6).
QUEUE_FILTER_PY=""
[ -n "${BASH_SOURCE[0]:-}" ] && { QUEUE_FILTER_PY="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)/queue_filter.py" || QUEUE_FILTER_PY=""; }

queue_filter_text() { # stdin: the text bytes -> stdout: ONE line (rc 0), or only the reason (rc 4)
  # The text an agent writes is hostile input: before it reaches a plan it goes through
  # lib/queue_filter.py. Reasons for rc 4: format, length, key, personal data; a rejection
  # never returns the text or a fragment of it. rc 6 = the filter could not run (missing
  # interpreter or file, or it crashed): it fails closed, with an error that is not a reason.
  # The interpreter is always `python3 -I` found on a fixed PATH, because the Unicode category
  # of a new emoji depends on the Python's Unicode version.
  local py f="$QUEUE_FILTER_PY" rc=0
  py="$(PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" command -v python3)"
  [ -n "$py" ] && [ -x "$py" ] && [ -f "$f" ] || { echo "error: the text filter cannot run (python3 or $f is missing)" >&2; return 6; }
  "$py" -I "$f" || rc=$?
  case "$rc" in 0|4) return "$rc" ;; *) return 6 ;; esac
}

queue_sync_from_origin() { # <queue_dir> -> merge origin/<branch> into the queue's checkout; 1 on conflict
  # The queue is edited from several machines and sessions that push to origin; a runner that
  # never updates its checkout reads stale plans and its push collides. Merge, never rebase (a
  # rebase forces a force-push). On a conflict it aborts, leaves the tree as it was and returns
  # 1 so the caller decides.
  local qdir="$1" root branch out
  root="$(cd "$qdir" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null)" || return 0
  branch="$(git -C "$root" symbolic-ref --short -q HEAD 2>/dev/null)" || branch=""
  [ -z "$branch" ] && return 0
  git -C "$root" fetch -q origin 2>/dev/null || { echo "queue_sync_from_origin: WARN fetch failed in $root" >&2; return 0; }
  git -C "$root" rev-parse --verify -q "origin/$branch" >/dev/null || return 0
  if ! out="$(git -C "$root" merge -q --no-edit "origin/$branch" 2>&1)"; then
    git -C "$root" merge --abort 2>/dev/null
    echo "queue_sync_from_origin: ERROR conflict merging origin/$branch in $root; tree left untouched: $out" >&2
    return 1
  fi
  return 0
}

queue_plan_body() { # <plan file> -> the plan without its frontmatter
  awk 'NR==1 && $0=="---" {infm=1; next} infm==1 && $0=="---" {infm=2; next} infm==2 {print}' "$1"
}

# queue_premisas_ok <plan file> -> 0 if the plan's premises hold. A premise is a body line
# `<claim> :: <path>:<line>`; bin/devbrain-verifier appends `:: HOLDS|FALSE|UNVERIFIABLE` and writes `verificado:`.
# Fails (rc 1, ONE line on stderr) when a premise is FALSE or UNVERIFIABLE, when there are premises and `verificado:`
# is empty, or when one has no verdict. A plan with no premise line passes. Every way to run a plan calls this
# (devbrain-night's next_plan); `approve` only warns. Fail closed: if the checker cannot read the plan, it does not run.
queue_premisas_ok() {
  local f="$1" out rc
  out="$(python3 -I "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/verifier.py" gate "$f" 2>&1 < /dev/null)"; rc=$?
  [ -z "$out" ] || printf '%s\n' "$out" >&2
  [ "$rc" -eq 0 ] || return 1  # fail closed
  return 0
}

# queue_disenso_bloquea <plan file> -> 0 if the tenth man blocks the plan: `disenso: BLOCKS` and no
# `disenso_anulado:` (the human override, written by `approve <n> <note>`). No dissent or UNAVAILABLE: 1.
queue_disenso_bloquea() {
  [ "$(fm_get "$1" disenso)" = "BLOCKS" ] && [ -z "$(fm_get "$1" disenso_anulado)" ]
}

# tenth_counts <queue_dir> -> "overridden A · confirmed C · wrong S · right X · missed N".
# Outcomes of the tenth man, from the plans' own state: overridden = a human overrode and the plan is still
# approved; wrong = overrode and it finished (done); right = overrode and it failed; confirmed = the human changed
# or denied a blocked plan; missed = it did not block (DOES NOT BLOCK / UNAVAILABLE) and the plan failed.
tenth_counts() {
  local f r d st a=0 c=0 s=0 x=0 n=0
  for f in "$1"/*.plan.md; do
    [ -e "$f" ] || continue
    r="$(fm_get "$f" disenso_resultado)"; d="$(fm_get "$f" disenso)"; st="$(fm_get "$f" status)"
    case "$r" in
      anulado) case "$st" in done) s=$((s+1)) ;; failed) x=$((x+1)) ;; *) a=$((a+1)) ;; esac ;;
      confirmado) c=$((c+1)) ;;
      *) [ "$d" != "BLOCKS" ] && [ -n "$d" ] && [ "$st" = failed ] && n=$((n+1)) ;;
    esac
  done
  echo "overridden $a · confirmed $c · wrong $s · right $x · missed $n"
}

recorta() { # <n> [suffix] — stdin cut to n CHARACTERS (not bytes), with the suffix if it was cut
  python3 -c 'import sys;n=int(sys.argv[1]);s=sys.stdin.read().strip();print(s if len(s)<=n else s[:n].rstrip()+sys.argv[2])' "$1" "${2:-…}"
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

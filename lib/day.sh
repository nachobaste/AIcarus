#!/bin/bash
# lib/day.sh — day_apply: the one function that turns a decision on a proposal into a
# written plan (or a discard) and a git commit. Sourced by bin/devbrain-day (the
# terminal interface) and, potentially, a Telegram approval path — one
# implementation, so the two interfaces cannot validate or write differently.
#
# Requires (sourced by the caller, same convention as devbrain-queue): lib/queue.sh
# (fm_get/fm_set/queue_next_nn/queue_slugify/queue_commit_and_push).

# Absolute default, NOT derived from ${BASH_SOURCE[0]}: that resolves emptily
# under zsh when a caller sources this file directly instead of running an actual
# bash script — see the identical lesson already fixed in lib/classify.sh
# (NOTION_REDACT_BIN). A missing engine must also exit with its OWN distinct code,
# never "python can't open file" (exit 2), which is indistinguishable from
# day_engine.py's own deliberate refusals.
DAY_ENGINE="${DAY_ENGINE:-$HOME/dev/devbrain/lib/day_engine.py}"

day_apply() { # <title> dale|no [reason] [option A|B] -> writes/commits, prints a one-line result
  local title="$1" decision="$2" reason="${3:-}" option="${4:-}"
  if [ ! -f "$DAY_ENGINE" ]; then
    echo "day_apply: engine not found at $DAY_ENGINE (DAY_ENGINE misconfigured)" >&2
    return 6
  fi
  local queue_dir="${DEVBRAIN_QUEUE_DIR:-$HOME/dev/queue}"
  local wiki_dir="${DEVBRAIN_WIKI_DIR:-$HOME/dev/wiki}"
  local backlog="$wiki_dir/projects/mejoras-propuestas.md"

  [ -f "$backlog" ] || { echo "day_apply: backlog does not exist: $backlog" >&2; return 4; }

  case "$decision" in
    dale)
      local rendered rc repo slug body nn f
      local -a render_args=("render" "$title")
      [ -n "$option" ] && render_args+=("--option" "$option")
      rendered="$(RESEARCH_ALLOWFILE="${RESEARCH_ALLOWFILE:-$(cd "$(dirname "$DAY_ENGINE")/.." && pwd)/devbrain-projects.allow}" \
                  python3 "$DAY_ENGINE" "${render_args[@]}" < "$backlog")"
      rc=$?
      if [ $rc -ne 0 ]; then
        echo "day_apply: could not approve '$title' (rc=$rc) — check the destination repo" >&2
        return "$rc"
      fi
      repo="$(printf '%s\n' "$rendered" | sed -n '1s/^repo: //p')"
      slug="$(printf '%s\n' "$rendered" | sed -n '2s/^slug: //p')"
      body="$(printf '%s\n' "$rendered" | tail -n +4)"

      nn="$(queue_next_nn "$queue_dir")"
      f="$queue_dir/$nn-$repo--$slug.plan.md"
      {
        echo "---"
        echo "repo: $repo"
        echo "status: approved"
        echo "prioridad: $nn"
        echo "creado: $(date +%Y-%m-%d)"
        echo "aprobado: $(date +%Y-%m-%d)"
        echo "---"
        echo ""
        printf '%s\n' "$body"
      } > "$f"

      local newbacklog
      newbacklog="$(python3 "$DAY_ENGINE" mark "$title" dale < "$backlog")" || {
        echo "day_apply: the plan was written but the backlog could NOT be marked — check by hand: $backlog" >&2
        rm -f "$f"
        return 5
      }
      printf '%s\n' "$newbacklog" > "$backlog"

      queue_commit_and_push "$queue_dir" "day: approve $(basename "$f")"
      queue_commit_and_push "$wiki_dir" "research: decision (approved) — $title"
      echo "Approved: $(basename "$f")"
      ;;
    no)
      if [ -z "$reason" ]; then
        echo "day_apply: discarding requires a reason (without one, research repeats the same mistake)" >&2
        return 2
      fi
      local newbacklog rc
      newbacklog="$(python3 "$DAY_ENGINE" mark "$title" no --reason "$reason" < "$backlog")"
      rc=$?
      [ $rc -eq 0 ] || { echo "day_apply: could not discard '$title' (rc=$rc)" >&2; return "$rc"; }
      printf '%s\n' "$newbacklog" > "$backlog"
      queue_commit_and_push "$wiki_dir" "research: decision (discarded) — $title"
      echo "Discarded: $title"
      ;;
    *)
      echo "day_apply: unknown decision: '$decision' (dale|no)" >&2
      return 2
      ;;
  esac
}

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
DAY_ENGINE="${DAY_ENGINE:-$HOME/dev/machine-config/lib/day_engine.py}"

day_apply() { # <titulo> dale|no [motivo] [opcion A|B] -> writes/commits, prints a one-line result
  local titulo="$1" decision="$2" motivo="${3:-}" opcion="${4:-}"
  if [ ! -f "$DAY_ENGINE" ]; then
    echo "day_apply: no se encontró el motor en $DAY_ENGINE (DAY_ENGINE mal configurado)" >&2
    return 6
  fi
  local queue_dir="${DEVBRAIN_QUEUE_DIR:-$HOME/dev/queue}"
  local wiki_dir="${DEVBRAIN_WIKI_DIR:-$HOME/dev/wiki}"
  local backlog="$wiki_dir/projects/mejoras-propuestas.md"

  [ -f "$backlog" ] || { echo "day_apply: no existe el backlog: $backlog" >&2; return 4; }

  case "$decision" in
    dale)
      local rendered rc repo slug body nn f
      local -a render_args=("render" "$titulo")
      [ -n "$opcion" ] && render_args+=("--opcion" "$opcion")
      rendered="$(RESEARCH_ALLOWFILE="${RESEARCH_ALLOWFILE:-$(cd "$(dirname "$DAY_ENGINE")/.." && pwd)/devbrain-projects.allow}" \
                  python3 "$DAY_ENGINE" "${render_args[@]}" < "$backlog")"
      rc=$?
      if [ $rc -ne 0 ]; then
        echo "day_apply: no se pudo aprobar '$titulo' (rc=$rc) — revisar el repo destino" >&2
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
      newbacklog="$(python3 "$DAY_ENGINE" mark "$titulo" dale < "$backlog")" || {
        echo "day_apply: el plan se escribió pero NO se pudo marcar el backlog — revisar a mano: $backlog" >&2
        rm -f "$f"
        return 5
      }
      printf '%s\n' "$newbacklog" > "$backlog"

      queue_commit_and_push "$queue_dir" "day: aprobar $(basename "$f")"
      queue_commit_and_push "$wiki_dir" "research: decisión (aprobada) — $titulo"
      echo "Aprobado: $(basename "$f")"
      ;;
    no)
      if [ -z "$motivo" ]; then
        echo "day_apply: descartar requiere un motivo (sin eso, el research repite el mismo error)" >&2
        return 2
      fi
      local newbacklog rc
      newbacklog="$(python3 "$DAY_ENGINE" mark "$titulo" no --motivo "$motivo" < "$backlog")"
      rc=$?
      [ $rc -eq 0 ] || { echo "day_apply: no se pudo descartar '$titulo' (rc=$rc)" >&2; return "$rc"; }
      printf '%s\n' "$newbacklog" > "$backlog"
      queue_commit_and_push "$wiki_dir" "research: decisión (descartada) — $titulo"
      echo "Descartado: $titulo"
      ;;
    *)
      echo "day_apply: decision desconocida: '$decision' (dale|no)" >&2
      return 2
      ;;
  esac
}

# lib/models.sh — which model and effort each role's `claude` call uses. Sourced.
#
#   models_resolve <role> <default-model> <default-effort> [fallback-role]
#
# Sets MODEL_ARGS to "--model M --effort E" (each pair only when it has a value) and
# returns 0, or prints a clear error and returns 2 so the caller exits before running
# the binary. Precedence per value:
#   1. DEVBRAIN_MODEL_<ROLE> / DEVBRAIN_EFFORT_<ROLE> in the environment;
#   2. the older DEVBRAIN_PLAN_MODEL / DEVBRAIN_PLAN_EFFORT (plan) and
#      DEVBRAIN_EXEC_MODEL / DEVBRAIN_EXEC_EFFORT (execute), kept so existing setups work;
#   3. config/models.conf (`role=model`, `role.effort=level`);
#   4. the fallback role's value (the reviewer falls back to plan, as it always did);
#   5. the default the caller passes.
#
# Only --model and --effort ever come from here. Permission mode, --allowedTools,
# --disallowedTools and timeouts stay literal at each call site and are never
# configurable. The validation below is what keeps a config value from becoming a
# flag: nothing starting with "-", no spaces, nothing outside [A-Za-z0-9._:/-].
#
# Expand it as ${MODEL_ARGS[@]+"${MODEL_ARGS[@]}"} where the defaults are empty: bash
# 3.2 (macOS /bin/bash) treats an empty array as unbound under `set -u`.
# DEVBRAIN_MODELS_FILE wins over DEVBRAIN_CONFIG_DIR, like every per-file variable: the
# config dir also locates the allowlist, so it can't be pointed elsewhere just to swap
# this one file.
MODELS_FILE="${DEVBRAIN_MODELS_FILE:-${DEVBRAIN_CONFIG_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/config}/models.conf}"

# Last `key=value` line for this exact key; `#` starts a comment; blank = unset.
_models_get() { # <role> <model|effort>
  local up env old="" v=""
  up="$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')"
  if [ "$2" = model ]; then env="DEVBRAIN_MODEL_$up"; else env="DEVBRAIN_EFFORT_$up"; fi
  case "$1.$2" in
    plan.model) old=DEVBRAIN_PLAN_MODEL ;;     plan.effort) old=DEVBRAIN_PLAN_EFFORT ;;
    execute.model) old=DEVBRAIN_EXEC_MODEL ;;  execute.effort) old=DEVBRAIN_EXEC_EFFORT ;;
  esac
  v="${!env:-}"
  [ -z "$v" ] && [ -n "$old" ] && v="${!old:-}"
  if [ -z "$v" ] && [ -f "$MODELS_FILE" ]; then
    local key="$1"; [ "$2" = effort ] && key="$1.effort"
    v="$(awk -v k="$key" '{ sub(/#.*/, "") } index($0, "=") {
           name = substr($0, 1, index($0, "=") - 1); gsub(/[ \t]/, "", name)
           if (name == k) { val = substr($0, index($0, "=") + 1); gsub(/^[ \t]+|[ \t]+$/, "", val); last = val } }
         END { printf "%s", last }' "$MODELS_FILE")"
  fi
  printf '%s' "$v"
}

models_resolve() {
  local role="$1" m e
  m="$(_models_get "$role" model)"; e="$(_models_get "$role" effort)"
  if [ -n "${4:-}" ]; then
    [ -n "$m" ] || m="$(_models_get "$4" model)"
    [ -n "$e" ] || e="$(_models_get "$4" effort)"
  fi
  m="${m:-$2}"; e="${e:-$3}"
  case "$m" in
    -*|*[!abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:/-]*)
      echo "models: invalid model for role $role: '$m' (allowed: [A-Za-z0-9._:/-], not starting with '-'). Not calling claude." >&2
      return 2 ;;
  esac
  case "$e" in
    ''|low|medium|high|xhigh|max) ;;   # the levels `claude --help` lists for --effort
    *) echo "models: invalid effort for role $role: '$e' (allowed: low, medium, high, xhigh, max). Not calling claude." >&2
       return 2 ;;
  esac
  MODEL_ARGS=()
  [ -n "$m" ] && MODEL_ARGS+=(--model "$m")
  [ -n "$e" ] && MODEL_ARGS+=(--effort "$e")
  return 0
}

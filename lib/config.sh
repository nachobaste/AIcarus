# config_path <name> [root] — where a config file lives: $DEVBRAIN_CONFIG_DIR/<name>,
# default <root>/config/<name>, with <root> defaulting to this repo. Prints the path
# even when the file is missing, so each caller keeps its own "missing file" handling.
# A per-file variable (DEVBRAIN_ALLOWFILE, RESEARCH_ALLOWFILE, ...) still wins: callers
# use this only as that variable's default.
config_path() {
  local root="${2:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
  echo "${DEVBRAIN_CONFIG_DIR:-$root/config}/$1"
}

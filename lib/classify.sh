#!/bin/bash
# lib/classify.sh — data classification and the single egress gate.
#
# Four tiers: personal | business-confidential | interno-devbrain | publico.
# Unknown paths fail CLOSED to the strictest business tier: a new directory nobody
# classified must not leak by default.

# The list of person names to redact NEVER lives in this repo — that would be the
# exact leak the gate exists to prevent, and this repo has a public GitHub remote.
# It lives beside your other secrets, one pattern per line, mode 600.
#
# FAIL CLOSED: if the file is missing or empty, redact_names refuses with exit 2
# rather than passing content through unredacted. A gate that silently does
# nothing is worse than no gate, because the dashboard looks clean either way.
CLASSIFY_NAMES_FILE="${CLASSIFY_NAMES_FILE:-$HOME/.config/devbrain/secrets/redact-names.txt}"

# Same pattern bin/devbrain-drift already uses for its own memory path: an explicit
# variable with an absolute default, because the path is specific to this machine
# (not derived, not guessed).
CLASSIFY_MEMORY="${CLASSIFY_MEMORY:-$HOME/.claude/projects/-Users-urbot/memory}"

# Optional, config-driven tier map: one "path-prefix=tier" line per line, comments
# with '#'. Absent by default — every ~/dev/projects/<repo> not explicitly listed
# here falls through to the catch-all below. See devbrain-classify.tiers.example
# for the format if you want to add project-specific tiers of your own (e.g. one
# repo under a stricter "business-confidential" label, another repo public).
CLASSIFY_TIERS_FILE="${CLASSIFY_TIERS_FILE:-$HOME/dev/machine-config/devbrain-classify.tiers}"

classify_tier() {
  local path="$1" line prefix tier
  case "$path" in
    "$HOME"/dev/personal/*)  printf 'personal\n'; return ;;
    "$HOME"/dev/wiki/*)      printf 'interno-devbrain\n'; return ;;
    "$HOME"/dev/queue/*)     printf 'interno-devbrain\n'; return ;;
    "$HOME"/dev/machine-config/*) printf 'interno-devbrain\n'; return ;;
    "$CLASSIFY_MEMORY"/*)    printf 'interno-devbrain\n'; return ;;
  esac
  if [ -f "$CLASSIFY_TIERS_FILE" ]; then
    while IFS='=' read -r prefix tier; do
      case "$prefix" in ''|'#'*) continue ;; esac
      prefix="$(printf '%s' "$prefix" | sed 's/[[:space:]]*$//')"
      tier="$(printf '%s' "$tier" | sed 's/^[[:space:]]*//')"
      case "$path" in
        "$prefix"|"$prefix"/*) printf '%s\n' "$tier"; return ;;
      esac
    done < "$CLASSIFY_TIERS_FILE"
  fi
  # Deliberate catch-all, not a silent default: any path under ~/dev/projects/ (or
  # anywhere else) with no tier of its own — including a brand-new repo you just
  # cloned and haven't classified yet — fails CLOSED to the strictest business
  # tier, same rationale as the header comment: an unclassified path must never
  # leak by default.
  printf 'business-confidential\n'
}

# assert_egress_ok <tier> <destination>
# destination is one of: github | notion | telegram
# Exit 0 = allowed. Exit 2 = refused (never a silent drop).
assert_egress_ok() {
  local tier="$1" dest="$2"
  case "$tier:$dest" in
    # personal is refused for every destination. It is NOT listed here, because
    # bash `case` stops at the first match: a branch here would return 0 and
    # fail open. Falling through to the refusal after `esac` is the whole point.
    publico:*)                          return 0 ;;
    interno-devbrain:github)            return 0 ;;
    interno-devbrain:notion)            return 0 ;;
    interno-devbrain:telegram)          return 0 ;;
    business-confidential:notion)       return 0 ;;
    business-confidential:telegram)     return 0 ;;
  esac
  printf 'EgressViolation: tier=%s may not reach destination=%s\n' "$tier" "$dest" >&2
  return 2
}

# redact_names is a thin wrapper over bin/notion-redact.py. The matching itself is
# NOT done in sed: a sed/BRE version can leak ALL-CAPS names, gets defeated by tabs
# and line wraps, mishandles regex metacharacters from the names file, and
# over-captures preceding job titles. Use a real script, not a one-liner, for
# anything that touches real names.
# The path is an explicit variable with an absolute default, NOT derived from
# ${BASH_SOURCE[0]}: that resolution can break under zsh and under symlinks, and
# the resulting "python can't open file" also exits 2 — indistinguishable by exit
# code from the deliberate missing-names refusal. A missing redactor exits 3
# instead, so the two failures can never be confused.
NOTION_REDACT_BIN="${NOTION_REDACT_BIN:-$HOME/dev/machine-config/bin/notion-redact.py}"

redact_names() {
  if [ ! -f "$NOTION_REDACT_BIN" ]; then
    printf 'redact_names: redactor not found at %s (this is NOT the missing-names-list case)\n' \
      "$NOTION_REDACT_BIN" >&2
    return 3
  fi
  python3 "$NOTION_REDACT_BIN" --text
}

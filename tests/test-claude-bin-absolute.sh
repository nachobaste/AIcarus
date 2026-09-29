#!/bin/bash
# test-claude-bin-absolute.sh — no script under bin/ may invoke `claude` bare.
#
# Unattended scripts narrow their PATH on purpose, and the installer puts `claude` in
# ~/.local/bin, which is not on it. A bare invocation is "command not found" (rc=127) on
# every unattended run, and the log still looks normal. Resolve the binary once
# (`command -v claude`, falling back to the installer's location) and call "$CLAUDE_BIN".
#
# A check that was only ever seen passing cannot be told apart from one that looks at
# nothing: the planted cases below must be caught by the same scanner.
set -uo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }

# devbrain-interview is interactive (you, in your own terminal, with your full PATH).
EXEMPT=" devbrain-interview "

scan() { # <dir of scripts>  -> prints "file:line:text" for every bare invocation
  local d="$1" f n
  for f in "$d"/*; do
    [ -f "$f" ] || continue
    n="$(basename "$f")"
    case "$EXEMPT" in *" $n "*) continue ;; esac
    # (a) a variable default:            ${X:-claude}
    # (b) a pipeline into claude:        | claude ...
    # (c) a line-leading invocation:     claude -p ...   /   exec claude
    # Comments and lines that START with echo do not count. printf is NOT excluded: a
    # `printf ... | claude` pipeline starts with printf, and excluding it hides exactly that.
    grep -n -E ':-claude\}|\|[[:space:]]*claude([[:space:]]|$)|^[[:space:]]*(exec[[:space:]]+)?claude[[:space:]]' "$f" 2>/dev/null \
      | grep -v -E '^[0-9]+:[[:space:]]*#' \
      | grep -v -E '^[0-9]+:[[:space:]]*echo[[:space:]]' \
      | sed "s|^|$n:|"
  done
}

OUT="$(scan "$DIR/bin")"
[ -z "$OUT" ] || fail "claude invoked without a resolved path under bin/:
$OUT"
echo "OK: no script under bin/ invokes claude bare"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
printf '#!/bin/bash\nCLAUDE_BIN="${X_CLAUDE_BIN:-claude}"\n' > "$T/bare-default"
printf '#!/bin/bash\nprintf hi | claude -p\n' > "$T/bare-pipeline"
printf '#!/bin/bash\nexec claude --model x\n' > "$T/bare-exec"
for c in bare-default bare-pipeline bare-exec; do
  mkdir -p "$T/one"; rm -f "$T/one"/*; cp "$T/$c" "$T/one/$c"
  [ -n "$(scan "$T/one")" ] || fail "the scanner did NOT catch the planted case: $c"
done
echo "OK: the scanner catches a bare default, pipeline and exec (all three planted)"

mkdir -p "$T/clean"
printf '#!/bin/bash\n# claude -p in a comment\necho "run: claude -p"\nCLAUDE_BIN="${X:-$(command -v claude 2>/dev/null || echo "$HOME/.local/bin/claude")}"\nprintf hi | "$CLAUDE_BIN" -p\n' > "$T/clean/ok"
[ -z "$(scan "$T/clean")" ] || fail "false positive on comments, echo or the resolved path: $(scan "$T/clean")"
echo "OK: comments, echo and the resolved path do not trip the scanner"

echo "PASS: claude-bin-absolute"

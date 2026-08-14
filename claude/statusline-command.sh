#!/bin/bash
# Claude Code status line
# Shows: current directory, git branch (if in a repo), and model name

input=$(cat)

dir=$(echo "$input" | jq -r '.workspace.current_dir')
dir_display="${dir/#$HOME/~}"

model=$(echo "$input" | jq -r '.model.display_name')

# Git branch, if inside a git repo (use --no-optional-locks to avoid lock contention)
branch=""
if git -C "$dir" --no-optional-locks rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  branch=$(git -C "$dir" --no-optional-locks branch --show-current 2>/dev/null)
  if [ -z "$branch" ]; then
    branch=$(git -C "$dir" --no-optional-locks rev-parse --short HEAD 2>/dev/null)
  fi
fi

# Colors (dim variants, since status line renders dimmed)
DIR_COLOR="\033[2;36m"   # dim cyan
GIT_COLOR="\033[2;33m"   # dim yellow
MODEL_COLOR="\033[2;35m" # dim magenta
RESET="\033[0m"

if [ -n "$branch" ]; then
  printf "${DIR_COLOR}%s${RESET} ${GIT_COLOR}(%s)${RESET} ${MODEL_COLOR}[%s]${RESET}\n" "$dir_display" "$branch" "$model"
else
  printf "${DIR_COLOR}%s${RESET} ${MODEL_COLOR}[%s]${RESET}\n" "$dir_display" "$model"
fi

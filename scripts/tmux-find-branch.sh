#!/bin/bash
# tmux-find-branch: Find and jump to tmux windows by git branch name
# Used via tmux popup (prefix+b)
# Matches by ticket number in the pane's directory path

seen=""
entries=""

while IFS=$'\t' read -r session_window window_name pane_path; do
  # Deduplicate by session:window
  case "$seen" in
    *"|$session_window|"*) continue ;;
  esac
  seen="${seen}|${session_window}|"

  # Get git branch for this pane's directory
  branch=$(git -C "$pane_path" branch --show-current 2>/dev/null)
  [ -z "$branch" ] && branch="(no git)"

  # Use folder name as extra search context
  folder=$(basename "$pane_path")

  line="$branch  │  $session_window  ($window_name)  [$folder]"
  if [ -z "$entries" ]; then
    entries="$line"
  else
    entries="$entries
$line"
  fi
done < <(tmux list-panes -a -F "#{session_name}:#{window_index}	#{window_name}	#{pane_current_path}")

if [ -z "$entries" ]; then
  echo "No tmux windows found."
  read -n 1
  exit 1
fi

# Pre-fill fzf query with ticket number from clipboard if present
initial_query=""
clipboard=$(pbpaste 2>/dev/null)
if echo "$clipboard" | grep -qoE '[0-9]{4,6}'; then
  initial_query=$(echo "$clipboard" | grep -oE '[0-9]{4,6}' | head -1)
fi

selected=$(echo "$entries" | fzf --prompt="Branch> " --query="$initial_query" --reverse --no-sort)

[ -z "$selected" ] && exit 0

# Extract session:window from selection (between │ and the first parenthetical)
target=$(echo "$selected" | sed 's/.*│  \([^ ]*\)  .*/\1/')
session="${target%%:*}"

tmux select-window -t "$target"
tmux switch-client -t "$session"

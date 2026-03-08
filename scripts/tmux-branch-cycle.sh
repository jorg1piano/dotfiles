#!/bin/bash
# tmux-branch-cycle: Find windows matching clipboard ticket and enable cycling
# Usage: tmux-branch-cycle.sh [init|next|prev]

MATCH_FILE="/tmp/tmux-branch-matches"
INDEX_FILE="/tmp/tmux-branch-index"

action="${1:-init}"

case "$action" in
  init)
    # Extract ticket number from clipboard
    clipboard=$(pbpaste 2>/dev/null)
    ticket=$(echo "$clipboard" | grep -oE '[0-9]{4,6}' | head -1)

    if [ -z "$ticket" ]; then
      tmux display-message "No ticket number found in clipboard"
      exit 1
    fi

    # Find all windows with this ticket in their branch or path
    matches=""
    seen=""

    while IFS=$'\t' read -r session_window window_name pane_path; do
      case "$seen" in
        *"|$session_window|"*) continue ;;
      esac
      seen="${seen}|${session_window}|"

      branch=$(git -C "$pane_path" branch --show-current 2>/dev/null)
      folder=$(basename "$pane_path")

      if echo "$branch $folder $pane_path" | grep -q "$ticket"; then
        if [ -z "$matches" ]; then
          matches="$session_window"
        else
          matches="$matches
$session_window"
        fi
      fi
    done < <(tmux list-panes -a -F "#{session_name}:#{window_index}	#{window_name}	#{pane_current_path}")

    if [ -z "$matches" ]; then
      tmux display-message "No windows found for ticket $ticket"
      exit 1
    fi

    echo "$matches" > "$MATCH_FILE"
    echo "0" > "$INDEX_FILE"

    count=$(echo "$matches" | wc -l | tr -d ' ')
    target=$(echo "$matches" | head -1)
    session="${target%%:*}"

    tmux select-window -t "$target"
    tmux switch-client -t "$session"
    tmux display-message "Ticket $ticket: 1/$count (←/→ to cycle, Esc to exit)"
    ;;

  next|prev)
    if [ ! -f "$MATCH_FILE" ]; then
      tmux display-message "No branch cycle active — press b first"
      exit 1
    fi

    count=$(wc -l < "$MATCH_FILE" | tr -d ' ')
    index=$(cat "$INDEX_FILE")

    if [ "$action" = "next" ]; then
      index=$(( (index + 1) % count ))
    else
      index=$(( (index - 1 + count) % count ))
    fi

    echo "$index" > "$INDEX_FILE"

    # Get the target (1-indexed for sed)
    line_num=$((index + 1))
    target=$(sed -n "${line_num}p" "$MATCH_FILE")
    session="${target%%:*}"

    tmux select-window -t "$target"
    tmux switch-client -t "$session"
    tmux display-message "Ticket: $((index + 1))/$count (←/→ to cycle, Esc to exit)"
    ;;
esac

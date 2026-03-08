#!/usr/bin/env bash
# Move the current window to the previous or next session.
# Usage: tmux-move-window.sh prev|next

set -euo pipefail

direction="$1"

cur_session=$(tmux display-message -p '#{session_name}')

# Get ordered list of sessions (creation order, matches choose-tree)
IFS=$'\n' read -r -d '' -a sessions < <(tmux list-sessions -F '#{session_name}' && printf '\0') || true

# Find current session position
cur_pos=-1
for i in "${!sessions[@]}"; do
    if [[ "${sessions[$i]}" == "$cur_session" ]]; then
        cur_pos=$i
        break
    fi
done

# Get window count for current session
win_count=$(tmux list-windows -t "$cur_session" | wc -l | tr -d ' ')

# Guard: don't move if session has only 1 window (would leave it empty)
if [[ $win_count -le 1 ]]; then
    tmux display-message "Can't move: session has only 1 window"
    exit 0
fi

if [[ "$direction" == "prev" ]]; then
    if [[ $cur_pos -le 0 ]]; then
        tmux display-message "Already at first session"
        exit 0
    fi
    target_session="${sessions[$((cur_pos - 1))]}"
    tmux move-window -t "$target_session:"
    tmux switch-client -t "$target_session"
elif [[ "$direction" == "next" ]]; then
    if [[ $cur_pos -ge $(( ${#sessions[@]} - 1 )) ]]; then
        tmux display-message "Already at last session"
        exit 0
    fi
    target_session="${sessions[$((cur_pos + 1))]}"
    # Insert before the first window in target session
    first_target_win=$(tmux list-windows -t "$target_session" -F '#{window_index}' | head -1)
    target_index=$((first_target_win - 1))
    if [[ $target_index -lt 0 ]]; then
        target_index=0
    fi
    tmux move-window -t "$target_session:$target_index"
    tmux switch-client -t "$target_session"
else
    echo "Usage: $0 prev|next" >&2
    exit 1
fi

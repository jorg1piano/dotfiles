#!/bin/bash
# Usage: tmux-status.sh [working|idle]
# working = Claude is processing (white text, default)
# idle    = Claude needs input (orange text)

LOG=~/.claude/hooks/tmux-status.log
echo "$(date '+%H:%M:%S') action=${1:-idle} TMUX_PANE=${TMUX_PANE:-unset} TMUX=${TMUX:-unset}" >> "$LOG"

PANE="${TMUX_PANE:-}"
if [ -z "$PANE" ]; then
  echo "$(date '+%H:%M:%S') SKIPPED - no TMUX_PANE" >> "$LOG"
  exit 0
fi

case "${1:-idle}" in
  working)
    tmux set-window-option -t "$PANE" window-status-current-style 'bg=colour25,fg=white,bold' 2>/dev/null
    tmux set-window-option -t "$PANE" window-status-style '' 2>/dev/null
    ;;
  idle)
    tmux set-window-option -t "$PANE" window-status-current-style 'bg=colour25,fg=colour208,bold' 2>/dev/null
    tmux set-window-option -t "$PANE" window-status-style 'fg=colour208,bold' 2>/dev/null
    ;;
esac

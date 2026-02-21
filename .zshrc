claude() {
  if [ -n "$TMUX" ]; then
    tmux set-window-option monitor-silence 30
  fi
  command claude "$@"
  if [ -n "$TMUX" ]; then
    tmux set-window-option monitor-silence 0
  fi
}
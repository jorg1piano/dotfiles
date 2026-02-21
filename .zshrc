claude() {
  if [ -n "$TMUX" ]; then
    # Save current window name and append robot icon
    local current_name=$(tmux display-message -p '#W')
    tmux rename-window "${current_name} 🤖"
    tmux set-window-option monitor-silence 30
  fi
  command claude "$@"
  if [ -n "$TMUX" ]; then
    # Remove robot icon and restore name
    local updated_name=$(tmux display-message -p '#W')
    tmux rename-window "${updated_name% 🤖}"
    tmux set-window-option monitor-silence 0
  fi
}
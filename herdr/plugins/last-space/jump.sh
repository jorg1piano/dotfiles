#!/bin/sh
# Focus the previously used space (second line of the MRU file written by
# record.sh). The resulting workspace.focused event re-runs record.sh, which
# swaps the two entries — so pressing the key again comes straight back.

set -u

state_dir="${HERDR_PLUGIN_STATE_DIR:-$HOME/.config/herdr}"
file="$state_dir/mru"

previous=$(sed -n 2p "$file" 2>/dev/null) || previous=""
[ -n "$previous" ] || exit 0

herdr="${HERDR_BIN_PATH:-herdr}"

# A stale id (space closed since it was recorded) just fails; drop it so the next
# press falls through to whatever is recorded then instead of retrying forever.
if ! "$herdr" workspace focus "$previous" >/dev/null 2>&1; then
  current=$(sed -n 1p "$file" 2>/dev/null) || current=""
  printf '%s\n\n' "$current" >"$file"
fi

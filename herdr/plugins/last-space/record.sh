#!/bin/sh
# Record the most-recently-used spaces. Run from the workspace.focused event hook.
#
# State file holds exactly two lines: current space, then the one before it.
# Refocusing the space you are already on is ignored, so the second line always
# points at a *different* space and the jump action can toggle back and forth.

set -u

state_dir="${HERDR_PLUGIN_STATE_DIR:-$HOME/.config/herdr}"
file="$state_dir/mru"

ws="${HERDR_WORKSPACE_ID:-}"
[ -n "$ws" ] || exit 0

mkdir -p "$state_dir" 2>/dev/null || exit 0

current=$(sed -n 1p "$file" 2>/dev/null) || current=""
[ "$ws" = "$current" ] && exit 0

printf '%s\n%s\n' "$ws" "$current" >"$file"

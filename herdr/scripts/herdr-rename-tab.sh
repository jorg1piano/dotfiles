#!/usr/bin/env bash
# Prompt for a new label for the focused tab (tmux's prefix+, on windows).
# Herdr has no built-in rename action, so this shells out to `herdr tab rename`.
# Bound from config.toml as a [[keys.command]] type = "popup" so the read is
# interactive; HERDR_ACTIVE_TAB_ID is injected by Herdr.
set -euo pipefail

tab_id="${HERDR_ACTIVE_TAB_ID:-}"
if [ -z "$tab_id" ]; then
  echo "herdr: no active tab" >&2
  read -rsn1 -p "Press any key to close…"
  exit 1
fi

current=$(herdr tab get "$tab_id" 2>/dev/null |
  python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["tab"]["label"])' 2>/dev/null || true)

printf 'Rename tab %s (currently "%s")\n' "$tab_id" "$current"
read -rp "New name: " label

# Empty input aborts rather than blanking the label.
[ -n "${label// /}" ] || exit 0

herdr tab rename "$tab_id" "$label" >/dev/null

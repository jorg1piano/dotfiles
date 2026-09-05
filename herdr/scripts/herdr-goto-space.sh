#!/usr/bin/env bash
# Jump to a space by typing its id (w93) or fuzzy-matching its label.
# Bound from ~/.config/herdr/config.toml as a [[keys.command]] popup on
# prefix+shift+i. Herdr's built-in picker is a tree you navigate; this is one
# prompt for when I already know the id.
#
# An id typed with a tab suffix (w93:t1) lands on that tab. A query that matches
# nothing is still tried as an id, so the popup works without ever looking at
# the list.
set -uo pipefail

pause() { printf '\npress enter to close '; read -r _ || true; }
command -v fzf >/dev/null 2>&1 || { echo "fzf is required for the space picker"; pause; exit 1; }

rows=$(herdr workspace list 2>/dev/null | python3 -c '
import json, sys

try:
    workspaces = json.load(sys.stdin)["result"]["workspaces"]
except Exception:
    sys.exit(0)

for w in workspaces:
    status = w.get("agent_status") or "unknown"
    if status == "unknown":
        status = ""
    print("%-5s %3s  %-36s %s" % (
        w["workspace_id"], w.get("number", ""), w.get("label", ""), status))
')

[ -n "$rows" ] || { echo "no spaces open"; pause; exit 1; }

out=$(printf '%s\n' "$rows" | fzf --height=100% --reverse --print-query \
  --prompt='goto space > ' \
  --header='id     #  label                                 agent')
rc=$?
# 130 is escape or ctrl-c; anything the query still matched comes back as 0/1.
[ "$rc" -eq 130 ] && exit 0

query=$(printf '%s\n' "$out" | sed -n '1p' | tr -d '[:space:]')
choice=$(printf '%s\n' "$out" | sed -n '2p' | awk '{print $1}')

target="${choice:-$query}"
[ -n "$target" ] || exit 0

# w93:t1 focuses the tab too; the CLI has no focus-pane-by-id, so a pane suffix
# just lands on the space.
tab=""
case "$target" in
  *:t*) tab="$target" ;;
esac
target="${target%%:*}"

herdr workspace focus "$target" >/dev/null 2>&1 || {
  echo "no space called $target"
  pause
  exit 1
}
[ -n "$tab" ] && herdr tab focus "$tab" >/dev/null 2>&1
exit 0

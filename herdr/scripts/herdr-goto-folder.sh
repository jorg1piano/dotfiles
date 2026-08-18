#!/bin/sh
# Fuzzy-pick a folder under ~/github and go to it: focus the space that already
# holds it, or open a new one. Herdr's prefix+g (goto) only sees spaces that
# exist, so this is the same gesture over the folders on disk.
#
# Bound from ~/.config/herdr/config.toml as a [[keys.command]] popup.

set -u

root="${HERDR_GOTO_ROOT:-$HOME/github}"

pause() { printf '\npress enter to close '; read -r _ || true; }

[ -d "$root" ] || { echo "no such directory: $root"; pause; exit 1; }
command -v fzf >/dev/null 2>&1 || { echo "fzf is required for the folder picker"; pause; exit 1; }

name=$(
  find "$root" -mindepth 1 -maxdepth 1 -type d ! -name '.*' -exec basename {} ';' |
    sort -f |
    fzf --height=100% --reverse --prompt='goto folder > ' --header="$root"
)
[ -n "$name" ] || exit 0

path="$root/$name"

# A folder is "already open" if some space is rooted at it: repo-backed spaces
# expose worktree.checkout_path, plain ones only show up through their panes' cwd
# (snapshot.panes, not snapshot.agents — the latter lists agent panes only, so a
# plain shell space would look absent and get opened a second time).
existing=$(
  herdr api snapshot 2>/dev/null | PATH_ARG="$path" python3 -c '
import json, os, sys

target = os.path.realpath(os.environ["PATH_ARG"])
try:
    snap = json.load(sys.stdin)["result"]["snapshot"]
except Exception:
    sys.exit(0)

cwds = {}
for pane in snap.get("panes", []):
    cwd = pane.get("cwd")
    if cwd:
        cwds.setdefault(pane["workspace_id"], []).append(os.path.realpath(cwd))

# Sidebar order, so a folder open in several spaces resolves to the topmost one.
workspaces = snap.get("workspaces", [])

def checkout_of(workspace):
    checkout = (workspace.get("worktree") or {}).get("checkout_path")
    return os.path.realpath(checkout) if checkout else None

for workspace in workspaces:
    if checkout_of(workspace) == target or target in cwds.get(workspace["workspace_id"], []):
        print(workspace["workspace_id"])
        sys.exit(0)

# Nothing sits exactly on the folder, so settle for a space working inside it —
# an agent that cd-ed into a subdirectory still counts as having it open. The
# separator keeps ~/github/ragnarok from matching ~/github/ragnarok-something.
prefix = target + os.sep
for workspace in workspaces:
    if any(cwd.startswith(prefix) for cwd in cwds.get(workspace["workspace_id"], [])):
        print(workspace["workspace_id"])
        sys.exit(0)
'
)

if [ -n "$existing" ]; then
  herdr workspace focus "$existing" >/dev/null || { echo "could not focus $existing"; pause; exit 1; }
  exit 0
fi

# Linked worktrees open through `worktree open` so they nest under their repo in
# the sidebar; everything else is just a plain space at that path. Herdr rejects
# worktree actions addressed from a linked worktree, hence --cwd on the main
# checkout (same constraint as sdf-worktree-open.sh).
if git -C "$path" rev-parse --is-inside-work-tree >/dev/null 2>&1 &&
  [ "$(git -C "$path" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" != "$(git -C "$path" rev-parse --path-format=absolute --git-dir 2>/dev/null)" ]; then
  main=$(dirname "$(git -C "$path" rev-parse --path-format=absolute --git-common-dir)")
  if herdr worktree open --cwd "$main" --path "$path" --focus >/dev/null; then
    exit 0
  fi
  echo "worktree open failed, falling back to a plain space"
fi

herdr workspace create --cwd "$path" --label "$name" --focus >/dev/null || {
  echo "could not open a space at $path"
  pause
  exit 1
}

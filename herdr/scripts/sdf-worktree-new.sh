#!/bin/sh
# Prompt for a branch, create the sibling folder <repo>-<branch>, check a
# worktree out into it, and open it as a Herdr space nested under the repo with
# two panes: the agent on the left, `just setup && just run` on the right.
#
# The split between what runs here and what runs in the panes is deliberate.
# `herdr worktree open` refuses a path that is not a worktree yet, and only it
# produces the real nesting under the repo, so the checkout has to happen before
# the space exists. But the checkout itself is fast; what is slow is this repo's
# postCheckoutCommand (`just doctor --fix`, minutes of bootstrap). So the popup
# does the checkout with --no-post-checkout and hands the bootstrap to the right
# pane, where it is visible and interruptible, via `just setup`.
#
# Bound from ~/.config/herdr/config.toml as the prefix+alt+shift+n popup.
# Herdr provides HERDR_ACTIVE_PANE_CWD for the pane the chord was pressed in.
#
# Set HERDR_AGENT to run something other than claude in the left pane. The agent
# is typed into an interactive login shell, so a shell alias or function works
# here exactly as it does by hand.

set -u

agent="${HERDR_AGENT:-claude}"

pause() { printf '\npress enter to close '; read -r _ || true; }
fail() { echo "$@" >&2; pause; exit 1; }

for tool in sdf herdr jq git; do
  command -v "$tool" >/dev/null 2>&1 || fail "$tool is not on PATH"
done

sdf worktree create --help 2>&1 | grep -q -- --no-post-checkout ||
  fail "this sdf has no --no-post-checkout; update it, or the bootstrap will run here instead of in the pane"

# Herdr's CLI reports API failures as a JSON {"error":...} document, sometimes
# with a zero exit status, so every call is routed through this.
herdr_json() {
  out=$(herdr "$@" 2>&1) || fail "herdr $*: $out"
  case "$out" in
    *'"error"'*) fail "herdr $*: $out" ;;
  esac
  printf '%s' "$out"
}

repo="${HERDR_ACTIVE_PANE_CWD:-$PWD}"
cd "$repo" 2>/dev/null || fail "cannot cd to $repo"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
  fail "Not inside a Git work tree: $repo"

# Anchor on the main checkout: Herdr rejects worktree actions sourced from a
# linked worktree ("linked_worktree_source"), and the <repo>-<branch> folder
# belongs next to the main checkout, not next to whichever worktree the chord
# was pressed in.
main=$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")
project=$(basename "$main")

printf 'New branch in %s: ' "$project"
IFS= read -r branch || exit 0
[ -n "$branch" ] || exit 0

# Slashes in a branch name are directory separators, so the folder gets the
# flattened form. sdf keeps the branch name exactly as typed.
slug=$(printf '%s' "$branch" | tr '/' '-')
dest="$(dirname "$main")/$project-$slug"

if [ -e "$dest" ]; then
  fail "$dest already exists. Open it with prefix+shift+g, or mount the branch with prefix+alt+m"
fi
mkdir -p "$dest" || fail "could not create $dest"

# --destination mounts the worktree in the folder made above instead of one sdf
# names itself, which is what lets this script own the folder, the space and the
# layout while sdf stays unaware of Herdr.
echo "sdf worktree create $branch --destination $dest --no-post-checkout"
if ! sdf worktree create "$branch" --destination "$dest" --no-post-checkout; then
  # Leave nothing behind: the folder is still the empty one made above.
  rmdir "$dest" 2>/dev/null
  fail "sdf worktree create $branch failed"
fi

echo "opening $dest"
opened=$(herdr_json worktree open --cwd "$main" --path "$dest" --label "$branch" --focus)
left=$(printf '%s' "$opened" | jq -r '.result.root_pane.pane_id // empty')
[ -n "$left" ] || fail "herdr worktree open returned no root pane: $opened"

# worktree open appends to the end of the sidebar, so put the space where it
# belongs: directly under the repo it was branched from. Best effort, since a
# misplaced space is cosmetic and prefix+alt+shift+r sweeps the rest.
workspace=$(printf '%s' "$opened" | jq -r '.result.root_pane.workspace_id // empty')
lib="$HOME/dotfiles/herdr/scripts"
[ -n "$workspace" ] && python3 "$lib/herdr-nest-workspace.py" "$workspace" "$main" 2>/dev/null

split=$(herdr_json pane split "$left" --direction right --cwd "$dest" --no-focus)
right=$(printf '%s' "$split" | jq -r '.result.pane.pane_id // empty')
[ -n "$right" ] || fail "herdr pane split returned no pane: $split"

# Fire-and-forget into an interactive shell, so this popup closes now and the
# next worktree can be dispatched while this one is still bootstrapping.
start_pane() {
  target=$1
  shift
  herdr_json pane send-text "$target" "$*" >/dev/null
  herdr_json pane send-keys "$target" enter >/dev/null
}

# `just setup` is the bootstrap the skipped postCheckoutCommand would have run,
# and `just run` needs what it installs, so they are one command line: run only
# boots if setup succeeded. `just run` adds --isolated by itself inside a
# worktree, so sibling stacks do not fight over ports.
if [ -f "$dest/Justfile" ] || [ -f "$dest/justfile" ]; then
  start_pane "$right" 'just setup && just run'
else
  echo "no justfile in $dest, leaving the right pane at a shell"
fi

start_pane "$left" "$agent"

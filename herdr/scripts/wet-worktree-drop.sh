#!/bin/sh
# Tear down a `wet` worktree: `just stack nuke` to stop its Docker stack and drop
# the data volume, `wet worktree pop` to remove the checkout, then close the Herdr
# workspace backing it. The inverse of the prefix+u flow in wet-worktree-space.sh,
# which creates the worktree and runs `just setup && just stack up`.
#
# Bound from ~/.config/herdr/config.toml as the prefix+alt+shift+d popup.
# Herdr provides HERDR_ACTIVE_PANE_CWD / HERDR_ACTIVE_WORKSPACE_ID.

set -u

pause() { printf '\npress enter to close '; read -r _ || true; }
fail() { echo "$@" >&2; pause; exit 1; }

for tool in wet just herdr; do
  command -v "$tool" >/dev/null 2>&1 || fail "$tool is not on PATH"
done

cwd="${HERDR_ACTIVE_PANE_CWD:-$PWD}"
workspace="${HERDR_ACTIVE_WORKSPACE_ID:-}"
cd "$cwd" 2>/dev/null || fail "cannot cd to $cwd"

git rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
  fail "Not inside a Git work tree: $cwd"

# `wet worktree pop` removes the worktree holding the current directory, so it
# would take out the main checkout if run from there.
if [ "$(git rev-parse --git-dir)" = "$(git rev-parse --git-common-dir)" ]; then
  fail "Already in the main worktree, nothing to drop: $cwd"
fi

# The stack recipes and wet both key off the worktree root, not the pane's
# subdirectory.
root=$(git rev-parse --show-toplevel) || fail "cannot resolve worktree root"
cd "$root" || fail "cannot cd to $root"

echo "drop $root"
echo "  just stack nuke   # stop the stack and drop its data volume"
echo "  wet worktree pop  # remove the checkout, keep the branch"
printf '\nproceed? [y/N] '
IFS= read -r answer || exit 0
case "$answer" in [Yy]*) ;; *) exit 0 ;; esac

echo
echo "just stack nuke"
if ! just stack nuke; then
  # A worktree whose stack never came up, or a repo without the stack module,
  # is still worth popping — but that is the user's call, not this script's.
  echo
  printf 'just stack nuke failed. pop the worktree anyway? [y/N] '
  IFS= read -r answer || exit 0
  case "$answer" in [Yy]*) ;; *) exit 1 ;; esac
fi

echo
echo "wet worktree pop"
wet worktree pop || fail "wet worktree pop failed"

# Only close the workspace once the checkout is gone; this kills the popup along
# with it, so it must be the last thing we do.
if [ -n "$workspace" ]; then
  herdr workspace close "$workspace" >/dev/null ||
    fail "worktree removed, but closing workspace $workspace failed"
fi

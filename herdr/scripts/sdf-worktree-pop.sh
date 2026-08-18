#!/bin/sh
# Remove the current worktree with `sdf worktree pop`, then close the Herdr
# workspace that was backing it.
#
# Bound from ~/.config/herdr/config.toml as a [[keys.command]] popup.
# Herdr provides HERDR_ACTIVE_PANE_CWD / HERDR_ACTIVE_WORKSPACE_ID.

set -u

cwd="${HERDR_ACTIVE_PANE_CWD:-$PWD}"
workspace="${HERDR_ACTIVE_WORKSPACE_ID:-}"
cd "$cwd" 2>/dev/null || { echo "cannot cd to $cwd"; sleep 3; exit 1; }

pause() { printf '\npress enter to close '; read -r _ || true; }

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "Not inside a Git work tree: $cwd"
  pause
  exit 1
fi

# `sdf worktree pop` refuses to run from the main worktree.
if [ "$(git rev-parse --git-dir)" = "$(git rev-parse --git-common-dir)" ]; then
  echo "Already in the main worktree, nothing to pop: $cwd"
  pause
  exit 1
fi

echo "pop $(git rev-parse --show-toplevel)"
printf 'force? [y/N] '
IFS= read -r force || exit 0
printf 'delete branch too (--nuke)? [y/N] '
IFS= read -r nuke || exit 0

set --
case "$force" in [Yy]*) set -- "$@" --force ;; esac
case "$nuke" in [Yy]*) set -- "$@" --nuke ;; esac

echo
echo "sdf worktree pop $*"
if ! sdf worktree pop "$@"; then
  echo "sdf worktree pop failed"
  pause
  exit 1
fi

# Only close the workspace once the checkout is actually gone; this kills the
# popup along with it, so it must be the last thing we do.
if [ -n "$workspace" ]; then
  herdr workspace close "$workspace" >/dev/null || {
    echo "worktree removed, but closing workspace $workspace failed"
    pause
    exit 1
  }
fi

#!/bin/sh
# Close the active workspace. Pop linked worktrees with a root .wet.yaml first.
# Bound from config.toml as the prefix+shift+d popup.

set -u

pause() { printf '\npress enter to close '; read -r _ || true; }
fail() { echo "$@" >&2; pause; exit 1; }

cwd="${HERDR_ACTIVE_PANE_CWD:-$PWD}"
workspace="${HERDR_ACTIVE_WORKSPACE_ID:-}"
[ -n "$workspace" ] || fail "No active Herdr workspace"
command -v herdr >/dev/null 2>&1 || fail "herdr is not on PATH"
cd "$cwd" 2>/dev/null || fail "cannot cd to $cwd"

if root=$(git rev-parse --show-toplevel 2>/dev/null) && [ -f "$root/.wet.yaml" ]; then
  cd "$root" || fail "cannot cd to $root"
  git_dir=$(git rev-parse --absolute-git-dir) || fail "cannot resolve Git directory"
  common_dir=$(git rev-parse --path-format=absolute --git-common-dir) ||
    fail "cannot resolve common Git directory"

  # Main checkouts close normally. Only linked worktrees can be popped.
  if [ "$git_dir" != "$common_dir" ]; then
    command -v wet >/dev/null 2>&1 || fail "wet is not on PATH"
    echo "pop $root"
    echo "  wet worktree pop  # remove the checkout, keep the branch"
    printf '\nproceed? [y/N] '
    IFS= read -r answer || exit 0
    case "$answer" in [Yy]*) ;; *) exit 0 ;; esac

    wet worktree pop || fail "wet worktree pop failed"
  fi
fi

# Closing the workspace also kills this popup, so it must happen last.
herdr workspace close "$workspace" >/dev/null ||
  fail "closing workspace $workspace failed"

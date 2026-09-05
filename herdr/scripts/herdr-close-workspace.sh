#!/bin/sh
# Close the active workspace. Pop linked worktrees with a root .wet.yaml first,
# in the background so the confirmation popup can close immediately.
# Bound from config.toml as the prefix+shift+d popup.

set -u

pause() { printf '\npress enter to close '; read -r _ || true; }
fail() { echo "$@" >&2; pause; exit 1; }

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || fail "cannot locate close helper"

close_workspace() {
  result=$(herdr workspace close "$workspace" 2>&1) || { echo "$result" >&2; return 1; }
  # Herdr can report an API error as JSON with a zero exit status.
  case "$result" in *'"error"'*) echo "$result" >&2; return 1 ;; esac
}

# This worker has its own session and no terminal. Its output goes to the log.
if [ "${1:-}" = "--pop" ]; then
  root=$2
  workspace=$3
  log=$4
  main=$5
  fail() {
    echo "$@" >&2
    python3 "$script_dir/herdr-show-cleanup-error.py" "$root" "$workspace" "$main" "$log" "$*" || true
    exit 1
  }

  # Herdr closes the workspace. wet must not kill an inherited tmux pane.
  unset TMUX TMUX_PANE
  cd "$root" || fail "cannot cd to $root"
  # A running catalog watches deletion events and can recreate build directories
  # while Git removes them, which makes worktree pop fail with ENOTEMPTY.
  if [ -d "$root/catalog" ] && command -v flutter_static >/dev/null 2>&1; then
    (cd "$root/catalog" && flutter_static down) || fail "could not stop the Flutter catalog"
  fi
  wet worktree pop || fail "wet worktree pop failed; workspace left open"
  # The checkout no longer exists, so leave it before invoking Herdr.
  cd / || fail "cannot leave the removed checkout"
  close_workspace || fail "worktree removed, but closing workspace $workspace failed"
  python3 "$script_dir/herdr-focus-main-workspace.py" "$main" ||
    fail "worktree closed, but returning to the main checkout failed"
  exit 0
fi

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
    command -v python3 >/dev/null 2>&1 || fail "python3 is not on PATH"
    echo "pop $root"
    echo "  wet worktree pop  # remove the checkout, keep the branch"
    echo "Cleanup will continue in the background and close this workspace when done."
    echo "Herdr will then return to this repository's main checkout."
    printf '\nproceed? [y/N] '
    IFS= read -r answer || exit 0
    case "$answer" in [Yy]*) ;; *) exit 0 ;; esac

    python3 - "$script_dir/herdr-close-workspace.sh" "$root" "$workspace" <<'PY' || fail "cannot start worktree cleanup"
import os
import subprocess
import sys
import tempfile

script, root, workspace = sys.argv[1:]
# Git lists the main checkout first. Resolve it before pop removes the worktree.
record = subprocess.check_output(
    ["git", "-C", root, "worktree", "list", "--porcelain", "-z"]
).split(b"\0", 1)[0]
if not record.startswith(b"worktree "):
    raise RuntimeError("cannot resolve the main checkout")
main = os.fsdecode(record[len(b"worktree "):])
with tempfile.NamedTemporaryFile(prefix="herdr-worktree-pop-", suffix=".log", delete=False) as log:
    subprocess.Popen(
        ["/bin/sh", script, "--pop", root, workspace, log.name, main],
        stdin=subprocess.DEVNULL,
        stdout=log,
        stderr=subprocess.STDOUT,
        cwd="/",
        start_new_session=True,
    )
PY
    exit 0
  fi
fi

# Closing the workspace also kills this popup, so it must happen last.
close_workspace ||
  fail "closing workspace $workspace failed"

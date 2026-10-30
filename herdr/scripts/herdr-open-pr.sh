#!/usr/bin/env bash
# Open the PR for the branch checked out in the active pane's directory.
# Bound from config.toml as a popup so failures (no PR, detached HEAD, not a
# GitHub repo) stay on screen; on success the popup closes straight away.
# HERDR_ACTIVE_PANE_CWD is injected by Herdr.
set -uo pipefail

fail() {
  echo "$*" >&2
  read -rsn1 -p "Press any key to close…"
  exit 1
}

cwd="${HERDR_ACTIVE_PANE_CWD:-$PWD}"
cd "$cwd" 2>/dev/null || fail "Can't enter $cwd"

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || fail "$cwd is not a git repo"
branch=$(git rev-parse --abbrev-ref HEAD)
[ "$branch" != "HEAD" ] || fail "$cwd is on a detached HEAD"

# Newest PR for this branch in any state, so merged and closed ones open too.
url=$(gh pr list --head "$branch" --state all --limit 1 --json url --jq '.[0].url // empty' 2>&1) ||
  fail "gh failed: $url"
[ -n "$url" ] || fail "No PR for $branch in $cwd"

open "$url"

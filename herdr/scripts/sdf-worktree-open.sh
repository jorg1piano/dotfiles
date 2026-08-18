#!/bin/sh
# Prompt for a branch, materialize the worktree with `sdf worktree <verb>`, then
# hand the resulting path to Herdr so it opens as a worktree workspace.
#
#   $1  sdf worktree subcommand: "create" (new branch) or "mount" (existing).
#       Both take [branch] and support --cd, so they share this flow.
#
# Bound from ~/.config/herdr/config.toml as a [[keys.command]] popup.
# Herdr provides HERDR_ACTIVE_PANE_CWD / HERDR_ACTIVE_WORKSPACE_ID.

set -u

verb="${1:-create}"
case "$verb" in
  create) prompt='Branch to create (or ticket id)' ;;
  mount)  prompt='Existing branch to mount' ;;
  *) echo "unsupported sdf worktree subcommand: $verb"; sleep 3; exit 1 ;;
esac

repo="${HERDR_ACTIVE_PANE_CWD:-$PWD}"
cd "$repo" 2>/dev/null || { echo "cannot cd to $repo"; sleep 3; exit 1; }

pause() { printf '\npress enter to close '; read -r _ || true; }

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "Not inside a Git work tree: $repo"
  pause
  exit 1
fi

# Herdr rejects new/open worktree actions that start from a linked worktree
# ("linked_worktree_source"), so always address it from the main checkout.
main=$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")

# Mounting targets a branch that already exists, so offer the remote branches
# in a fuzzy picker (most recently committed first) instead of typing one out.
# Creating takes a brand new name, so it stays a plain prompt.
branch=""
if [ "$verb" = mount ] && command -v fzf >/dev/null 2>&1; then
  printf 'fetching remote branches... '
  git fetch --quiet --prune 2>/dev/null || echo "(fetch failed, using cached refs)"
  echo

  branch=$(
    git for-each-ref --sort=-committerdate \
      --format='%(refname:lstrip=3)%09%(committerdate:relative)%09%(authorname)' \
      refs/remotes/origin |
      awk -F'\t' '$1 != "" && $1 != "HEAD"' |
      fzf --height=100% --reverse --delimiter='\t' --with-nth=1,2,3 \
          --prompt='mount branch > ' --header='sorted by last commit' |
      cut -f1
  )
  [ -n "$branch" ] || exit 0
fi

if [ -z "$branch" ]; then
  printf '%s: ' "$prompt"
  IFS= read -r branch || exit 0
  [ -n "$branch" ] || exit 0
fi

echo
echo "sdf worktree $verb $branch"
path=$(sdf worktree "$verb" "$branch" --cd | tail -n 1)

if [ -z "$path" ] || [ ! -d "$path" ]; then
  echo "sdf did not return a usable worktree path (got: '$path')"
  pause
  exit 1
fi

echo "opening $path"
if ! herdr worktree open --cwd "$main" --path "$path" --focus >/dev/null; then
  echo "herdr worktree open failed for $path"
  pause
  exit 1
fi

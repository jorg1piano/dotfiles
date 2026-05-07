#!/bin/bash
# Open the GitHub issue or PR associated with a worktree.
# The ticket number is the first run of digits in the worktree folder name
# (e.g. "issue-10-foo", "story-10-bar", "story-test-20000-baz").

set -e

mode="$1"
path="$2"

if [ -z "$mode" ] || [ -z "$path" ]; then
  tmux display-message "tmux-open-ticket-or-pr: missing args"
  exit 1
fi

folder=$(basename "$path")
ticket=$(echo "$folder" | grep -oE '[0-9]+' | head -1)

if [ -z "$ticket" ]; then
  tmux display-message "No ticket number in folder: $folder"
  exit 1
fi

case "$mode" in
  ticket)
    if ! (cd "$path" && gh issue view "$ticket" --web) 2>/tmp/tmux-open-ticket.err; then
      tmux display-message "Failed to open issue #$ticket: $(cat /tmp/tmux-open-ticket.err)"
      exit 1
    fi
    ;;
  pr)
    if ! (cd "$path" && gh pr view --web) 2>/tmp/tmux-open-pr.err; then
      # Fall back: search for a PR linked to this issue/branch number
      pr_num=$(cd "$path" && gh pr list --search "$ticket in:title" --json number --jq '.[0].number' 2>/dev/null)
      if [ -n "$pr_num" ] && [ "$pr_num" != "null" ]; then
        (cd "$path" && gh pr view "$pr_num" --web)
      else
        tmux display-message "No PR found for #$ticket: $(cat /tmp/tmux-open-pr.err)"
        exit 1
      fi
    fi
    ;;
  *)
    tmux display-message "tmux-open-ticket-or-pr: unknown mode '$mode'"
    exit 1
    ;;
esac

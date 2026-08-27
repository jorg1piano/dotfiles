#!/bin/sh
# Pick a Git repository under ~/github, sorted by the last commit authored by you,
# and open it as a new focused Herdr workspace.
#
# Repos may live directly under ~/github or inside grouping directories. The scan
# finds every directory containing a .git entry and stops descending once a repo
# root is found.

set -u

root="${HERDR_REPO_ROOT:-$HOME/github}"

pause() { printf '\npress enter to close '; read -r _ || true; }

[ -d "$root" ] || { echo "no such directory: $root"; pause; exit 1; }
command -v fzf >/dev/null 2>&1 || { echo "fzf is required for the repo picker"; pause; exit 1; }
command -v git >/dev/null 2>&1 || { echo "git is required for the repo picker"; pause; exit 1; }

selection=$(
  ROOT_ARG="$root" python3 - <<'PY' | fzf \
    --height=100% \
    --reverse \
    --delimiter='\t' \
    --with-nth=2.. \
    --prompt='recent repo > ' \
    --header="last contributed repos under $root (enter or click to open)" \
    --bind='left-click:accept,double-click:accept' \
    --preview='git -C {1} log --max-count=12 --date=short --pretty=format:"%C(yellow)%h%Creset %Cgreen%ad%Creset %C(bold blue)%an%Creset %s" --all 2>/dev/null' \
    --preview-window='right,55%,wrap'
import os
import re
import subprocess
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime

root = os.path.realpath(os.environ["ROOT_ARG"])

skip_dirs = {
    ".cache", ".direnv", ".hg", ".svn", ".venv", "__pycache__",
    "build", "dist", "node_modules", "target", "vendor",
}

def git(repo, args, timeout=6):
    try:
        return subprocess.check_output(
            ["git", "-C", repo, *args], stderr=subprocess.DEVNULL, text=True, timeout=timeout
        ).strip()
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
        return ""

def values(repo, args):
    out = git(repo, args)
    return [line.strip() for line in out.splitlines() if line.strip()]

# Prefer commits authored with configured identities. Include global config plus
# per-repo config below, because work repos sometimes override user.email.
global_emails = values(root, ["config", "--global", "--get-all", "user.email"])
global_names = values(root, ["config", "--global", "--get-all", "user.name"])

repos = []
for dirpath, dirnames, filenames in os.walk(root):
    if ".git" in dirnames or ".git" in filenames:
        repos.append(os.path.realpath(dirpath))
        dirnames[:] = []
        continue
    dirnames[:] = [d for d in dirnames if d not in skip_dirs and not d.startswith(".")]

def row_for(repo):
    if git(repo, ["rev-parse", "--is-inside-work-tree"]) != "true":
        return None

    emails = set(global_emails + values(repo, ["config", "--get-all", "user.email"]))
    names = set(global_names + values(repo, ["config", "--get-all", "user.name"]))
    author_parts = [re.escape(v) for v in sorted(emails | names) if v]

    contributed_epoch = ""
    if author_parts:
        # Accurate author search can be expensive on very large histories, so cap
        # it and fall back to latest repo activity if it takes too long.
        contributed_epoch = git(
            repo,
            ["log", "--all", "-1", "--format=%ct", "--perl-regexp", "--author=(?:" + "|".join(author_parts) + ")"],
            timeout=3,
        )

    fallback_epoch = git(repo, ["log", "--all", "-1", "--format=%ct"], timeout=3)
    epoch_text = contributed_epoch or fallback_epoch
    if not epoch_text:
        return None

    epoch = int(epoch_text.splitlines()[0])
    date = datetime.fromtimestamp(epoch).strftime("%Y-%m-%d")
    rel = os.path.relpath(repo, root)
    marker = "" if contributed_epoch else "  (no authored commit found; sorted by repo activity)"
    return (epoch, repo, date, rel + marker)

rows = []
with ThreadPoolExecutor(max_workers=int(os.environ.get("HERDR_REPO_SCAN_JOBS", "12"))) as pool:
    futures = [pool.submit(row_for, repo) for repo in repos]
    for future in as_completed(futures):
        row = future.result()
        if row:
            rows.append(row)

for _epoch, repo, date, label in sorted(rows, reverse=True):
    print(f"{repo}\t{date}\t{label}")
PY
)

[ -n "$selection" ] || exit 0

path=$(printf '%s' "$selection" | cut -f1)
label=$(basename "$path")

# Linked worktrees open through Herdr's worktree API so they are grouped under
# their main checkout. Main checkouts open as plain, always-new workspaces.
if [ "$(git -C "$path" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" != "$(git -C "$path" rev-parse --path-format=absolute --git-dir 2>/dev/null)" ]; then
  main=$(dirname "$(git -C "$path" rev-parse --path-format=absolute --git-common-dir)")
  if herdr worktree open --cwd "$main" --path "$path" --label "$label" --focus >/dev/null; then
    exit 0
  fi
  echo "worktree open failed, falling back to a plain workspace"
fi

herdr workspace create --cwd "$path" --label "$label" --focus >/dev/null || {
  echo "could not open a workspace at $path"
  pause
  exit 1
}

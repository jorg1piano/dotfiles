#!/bin/sh
# Pick a Git repository/worktree under ~/github and open it in Herdr.
#
# The list is grouped by main repository and sorted by recent repository activity
# using Git's local reflogs for speed. Set HERDR_REPO_ACCURATE_AUTHORS=1 to sort
# by your last authored commit instead. Linked worktrees are shown only as
# indented sub-items under the repository they are attached to.

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
    --header="repos under $root; worktrees are indented under their attached repo (enter/click opens)" \
    --bind='left-click:accept,double-click:accept' \
    --preview='git -C {1} log --max-count=12 --date=short --pretty=format:"%C(yellow)%h%Creset %Cgreen%ad%Creset %C(bold blue)%an%Creset %s" --all 2>/dev/null' \
    --preview-window='right,55%,wrap'
import json
import os
import re
import signal
import subprocess
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime
from pathlib import Path

signal.signal(signal.SIGPIPE, signal.SIG_DFL)

root = os.path.realpath(os.environ["ROOT_ARG"])
accurate_authors = os.environ.get("HERDR_REPO_ACCURATE_AUTHORS") == "1"
cache_path = Path(os.path.expanduser("~/.cache/herdr/recent-repos.json"))
cache_ttl = int(os.environ.get("HERDR_REPO_CACHE_TTL", "86400"))
refresh = os.environ.get("HERDR_REPO_REFRESH") == "1"

skip_dirs = {
    ".cache", ".direnv", ".hg", ".svn", ".venv", "__pycache__",
    "build", "dist", "node_modules", "target", "vendor",
}

def git(repo, args, timeout=2):
    try:
        return subprocess.check_output(
            ["git", "-C", repo, *args], stderr=subprocess.DEVNULL, text=True, timeout=timeout
        ).strip()
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
        return ""

def values(repo, args):
    out = git(repo, args)
    return [line.strip() for line in out.splitlines() if line.strip()]

def date(epoch):
    return datetime.fromtimestamp(int(epoch)).strftime("%Y-%m-%d") if epoch else "----------"

def rel(path):
    try:
        return os.path.relpath(path, root)
    except ValueError:
        return path

def load_cache():
    if refresh:
        return None
    try:
        data = json.loads(cache_path.read_text())
        if data.get("root") == root and data.get("accurate_authors") == accurate_authors and data.get("created", 0) + cache_ttl >= datetime.now().timestamp():
            return data
    except Exception:
        pass
    return None

def emit(data):
    for group in data["groups"]:
        main = group["main"]
        main_date = date(group.get("sort_epoch", 0))
        suffix = "" if (not accurate_authors or group.get("authored")) else "  · by repo activity"
        print(f"{main}\t{main_date}\t▣ {main_date}  {rel(main)}{suffix}")
        for wt in group.get("worktrees", []):
            branch = f"  [{wt['branch']}]" if wt.get("branch") else ""
            wt_date = date(wt.get("head_epoch", 0))
            print(f"{wt['path']}\t{wt_date}\t  ↳ {wt_date}  {os.path.basename(wt['path'])}{branch}  — attached to {rel(main)}")

cached = load_cache()
if cached:
    emit(cached)
    raise SystemExit

def read_text(path):
    try:
        return Path(path).read_text(errors="ignore").strip()
    except Exception:
        return ""

def resolve_gitdir(repo):
    dotgit = os.path.join(repo, ".git")
    if os.path.isdir(dotgit):
        return os.path.realpath(dotgit)
    text = read_text(dotgit)
    if text.startswith("gitdir:"):
        raw = text.split(":", 1)[1].strip()
        if not os.path.isabs(raw):
            raw = os.path.join(repo, raw)
        return os.path.realpath(raw)
    return ""

def branch_name(gitdir):
    head = read_text(os.path.join(gitdir, "HEAD"))
    if head.startswith("ref:"):
        return os.path.basename(head.rsplit("/", 1)[-1])
    return ""

def newest_mtime(paths):
    newest = 0
    for path in paths:
        if not path or not os.path.exists(path):
            continue
        if os.path.isfile(path):
            try:
                newest = max(newest, int(os.path.getmtime(path)))
            except OSError:
                pass
            continue
        for dirpath, _dirnames, filenames in os.walk(path):
            for name in filenames:
                try:
                    newest = max(newest, int(os.path.getmtime(os.path.join(dirpath, name))))
                except OSError:
                    pass
    return newest

def inspect(repo):
    repo = os.path.realpath(repo)
    gitdir = resolve_gitdir(repo)
    if not gitdir:
        return None

    marker = f"{os.sep}.git{os.sep}worktrees{os.sep}"
    is_worktree = marker in gitdir
    common_dir = (gitdir.split(marker, 1)[0] + os.sep + ".git") if is_worktree else gitdir
    main = os.path.dirname(common_dir)

    head_epoch = newest_mtime([os.path.join(gitdir, "logs", "HEAD"), os.path.join(gitdir, "HEAD")])
    return {
        "path": repo,
        "main": os.path.realpath(main if is_worktree else repo),
        "common_dir": os.path.realpath(common_dir),
        "gitdir": gitdir,
        "is_worktree": is_worktree,
        "branch": branch_name(gitdir),
        "head_epoch": head_epoch,
    }

roots = []
for dirpath, dirnames, filenames in os.walk(root):
    if ".git" in dirnames or ".git" in filenames:
        roots.append(os.path.realpath(dirpath))
        dirnames[:] = []
        continue
    dirnames[:] = [d for d in dirnames if d not in skip_dirs and not d.startswith(".")]

items = [item for item in (inspect(path) for path in roots) if item]

by_main = {}
for item in items:
    group = by_main.setdefault(item["main"], {"main": item["main"], "common_dir": item["common_dir"], "worktrees": []})
    if item["is_worktree"]:
        group["worktrees"].append(item)
    else:
        group["main_item"] = item
        group["common_dir"] = item["common_dir"]

for main, group in by_main.items():
    group.setdefault("main_item", {"path": main, "main": main, "is_worktree": False, "branch": "", "head_epoch": 0})

# Fast score: reflog mtimes for the main repo plus linked worktree HEAD reflogs.
def fast_score(group):
    common = group.get("common_dir") or os.path.join(group["main"], ".git")
    paths = [
        os.path.join(common, "logs", "HEAD"),
        os.path.join(common, "logs", "refs", "heads"),
        os.path.join(common, "packed-refs"),
    ]
    paths.extend(os.path.join(wt["gitdir"], "logs", "HEAD") for wt in group.get("worktrees", []))
    return newest_mtime(paths) or group["main_item"].get("head_epoch", 0)

global_emails = values(root, ["config", "--global", "--get-all", "user.email"]) if accurate_authors else []
global_names = values(root, ["config", "--global", "--get-all", "user.name"]) if accurate_authors else []

def score(group):
    authored = ""
    if accurate_authors:
        main = group["main"]
        emails = set(global_emails + values(main, ["config", "--get-all", "user.email"]))
        names = set(global_names + values(main, ["config", "--get-all", "user.name"]))
        author_parts = [re.escape(v) for v in sorted(emails | names) if v]
        if author_parts:
            authored = git(
                main,
                ["log", "--all", "-1", "--format=%ct", "--perl-regexp", "--author=(?:" + "|".join(author_parts) + ")"],
                timeout=2,
            )
    group["sort_epoch"] = int(authored or fast_score(group) or 0)
    group["authored"] = bool(authored)
    group["worktrees"].sort(key=lambda wt: (wt.get("head_epoch", 0), wt.get("path", "")), reverse=True)
    return group

if accurate_authors:
    groups = []
    with ThreadPoolExecutor(max_workers=int(os.environ.get("HERDR_REPO_SCORE_JOBS", "16"))) as pool:
        for future in as_completed([pool.submit(score, group) for group in by_main.values()]):
            groups.append(future.result())
else:
    groups = [score(group) for group in by_main.values()]

data = {"root": root, "accurate_authors": accurate_authors, "created": datetime.now().timestamp(), "groups": sorted(groups, key=lambda g: (g.get("sort_epoch", 0), rel(g["main"]).lower()), reverse=True)}
try:
    cache_path.parent.mkdir(parents=True, exist_ok=True)
    cache_path.write_text(json.dumps(data))
except Exception:
    pass

emit(data)
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

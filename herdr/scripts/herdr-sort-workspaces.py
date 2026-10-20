#!/usr/bin/env python3
"""Sort Herdr spaces by the last commit made in each one.

Spaces are grouped by repository: the main checkout and its linked worktree
spaces form one group. Groups are ordered by their newest commit, most recent
first. Inside a group the main checkout stays on top and the worktree spaces
below it are ordered the same way. Spaces outside Git sink to the bottom in
their current order.

Usage: herdr-sort-workspaces.py [--dry-run]
"""

import json
import os
import socket
import subprocess
import sys
from datetime import datetime

SOCK = os.path.expanduser("~/.config/herdr/herdr.sock")


def request(method, params):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(10)
    s.connect(SOCK)
    s.sendall((json.dumps({"id": "sort-workspaces", "method": method, "params": params}) + "\n").encode())
    buf = b""
    while not buf.endswith(b"\n"):
        chunk = s.recv(65536)
        if not chunk:
            break
        buf += chunk
    s.close()
    reply = json.loads(buf.decode().splitlines()[0])
    if "error" in reply:
        raise RuntimeError(reply["error"].get("message", reply["error"]))
    return reply["result"]


def git(path, *args):
    return subprocess.check_output(["git", "-C", path, *args], text=True, stderr=subprocess.DEVNULL).strip()


def infer_worktree_from_cwd(path):
    """Best-effort worktree info for plain spaces that were not opened via Herdr worktree."""
    if not path:
        return None
    try:
        git_dir = git(path, "rev-parse", "--path-format=absolute", "--git-dir")
        common_dir = git(path, "rev-parse", "--path-format=absolute", "--git-common-dir")
        checkout = git(path, "rev-parse", "--show-toplevel")
    except Exception:
        return None
    return {
        "repo_key": common_dir,
        "checkout_path": checkout,
        "is_linked_worktree": os.path.realpath(common_dir) != os.path.realpath(git_dir),
    }


def last_commit_time(path):
    try:
        return int(git(path, "log", "-1", "--format=%ct", "HEAD"))
    except Exception:
        return 0


def desired_order(workspaces, panes):
    cwd_by_workspace = {}
    for pane in panes:
        if pane.get("cwd"):
            cwd_by_workspace.setdefault(pane["workspace_id"], pane["cwd"])

    order = [w["workspace_id"] for w in workspaces]
    groups = {}  # repo_key (or workspace id for non-git spaces) -> {"main", "members"}
    times = {}
    for workspace in workspaces:
        wid = workspace["workspace_id"]
        wt = workspace.get("worktree") or infer_worktree_from_cwd(cwd_by_workspace.get(wid))
        times[wid] = last_commit_time(wt["checkout_path"]) if wt else 0
        group = groups.setdefault(wt["repo_key"] if wt else wid, {"main": None, "members": []})
        if wt and not wt.get("is_linked_worktree") and group["main"] is None:
            group["main"] = wid
        else:
            group["members"].append(wid)

    def recency(wid):
        # Newest first; ties (including never-committed spaces) keep sidebar order.
        return (-times[wid], order.index(wid))

    blocks = []
    for group in groups.values():
        block = ([group["main"]] if group["main"] else []) + sorted(group["members"], key=recency)
        newest = max(block, key=lambda wid: (times[wid], -order.index(wid)))
        blocks.append((recency(newest), block))
    blocks.sort(key=lambda b: b[0])
    return [wid for _, block in blocks for wid in block], times


def main():
    dry_run = "--dry-run" in sys.argv[1:]
    try:
        snap = request("session.snapshot", {})["snapshot"]
        workspaces = snap.get("workspaces", [])
        desired, times = desired_order(workspaces, snap.get("panes", []))

        if dry_run:
            labels = {w["workspace_id"]: w.get("label", "") for w in workspaces}
            for wid in desired:
                stamp = datetime.fromtimestamp(times[wid]).strftime("%Y-%m-%d %H:%M") if times[wid] else "-"
                print(f"{stamp:16}  {wid:6}  {labels[wid]}")
            return

        # Place each space at its slot from the top down. Everything above slot i
        # is already final, so the space is always at or below i and inserting
        # at i is unaffected by pulling it out of its old position.
        order = [w["workspace_id"] for w in workspaces]
        moved = 0
        for i, wid in enumerate(desired):
            if order[i] == wid:
                continue
            request("workspace.move", {"workspace_id": wid, "insert_index": i})
            order.remove(wid)
            order.insert(i, wid)
            moved += 1
    except Exception as exc:
        sys.exit(f"herdr-sort-workspaces: {exc}")

    print(f"sorted {len(desired)} spaces, moved {moved}")


if __name__ == "__main__":
    main()

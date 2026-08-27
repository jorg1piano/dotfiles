#!/usr/bin/env python3
"""Group linked worktree spaces under their main checkout in Herdr.

Scans the currently open Herdr workspaces. For every linked Git worktree, ensures
its repository's main checkout is open, then moves that repo's linked worktree
spaces directly underneath the main checkout in the sidebar.
"""

import json
import os
import socket
import subprocess
import sys
from collections import defaultdict

SOCK = os.path.expanduser("~/.config/herdr/herdr.sock")


def request(method, params):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(10)
    s.connect(SOCK)
    s.sendall((json.dumps({"id": "reparent-worktrees", "method": method, "params": params}) + "\n").encode())
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


def snapshot():
    return request("session.snapshot", {})["snapshot"]


def git_abs(path, arg):
    return subprocess.check_output(
        ["git", "-C", path, "rev-parse", "--path-format=absolute", arg],
        text=True,
        stderr=subprocess.DEVNULL,
    ).strip()


def infer_worktree_from_cwd(path):
    """Best-effort worktree info for plain spaces that were not opened via Herdr worktree."""
    try:
        subprocess.check_call(
            ["git", "-C", path, "rev-parse", "--is-inside-work-tree"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        git_dir = git_abs(path, "--git-dir")
        common_dir = git_abs(path, "--git-common-dir")
        checkout = git_abs(path, "--show-toplevel")
    except Exception:
        return None

    repo_root = os.path.dirname(common_dir)
    repo_name = os.path.basename(repo_root)
    return {
        "repo_key": common_dir,
        "repo_name": repo_name,
        "repo_root": repo_root,
        "checkout_path": checkout,
        "is_linked_worktree": os.path.realpath(common_dir) != os.path.realpath(git_dir),
    }


def workspace_cwds(panes):
    cwds = {}
    for pane in panes:
        cwd = pane.get("cwd")
        if cwd:
            cwds.setdefault(pane["workspace_id"], cwd)
    return cwds


def group_worktrees(workspaces, panes):
    """Return repo_key -> {main, children, repo_root, repo_name}."""
    groups = defaultdict(lambda: {"main": None, "children": [], "repo_root": None, "repo_name": None})
    cwd_by_workspace = workspace_cwds(panes)
    for workspace in workspaces:
        wt = workspace.get("worktree") or infer_worktree_from_cwd(cwd_by_workspace.get(workspace["workspace_id"], ""))
        if not wt:
            continue
        key = wt["repo_key"]
        group = groups[key]
        group["repo_root"] = wt["repo_root"]
        group["repo_name"] = wt["repo_name"]
        if wt.get("is_linked_worktree"):
            group["children"].append(workspace["workspace_id"])
        elif os.path.realpath(wt["checkout_path"]) == os.path.realpath(wt["repo_root"]):
            group["main"] = workspace["workspace_id"]
    return groups


def open_missing_mains(groups):
    opened = 0
    for group in groups.values():
        if group["main"] or not group["children"] or not group["repo_root"]:
            continue
        request(
            "worktree.open",
            {
                "cwd": group["repo_root"],
                "path": group["repo_root"],
                "label": group["repo_name"],
                "focus": False,
            },
        )
        opened += 1
    return opened


def move_children_under_mains(workspaces, groups):
    order = [w["workspace_id"] for w in workspaces]
    moved = 0

    # Process repos in the current sidebar order of their main checkout, so the
    # command is stable and does not shuffle unrelated workspaces.
    ordered_groups = sorted(
        (g for g in groups.values() if g["main"] and g["children"]),
        key=lambda g: order.index(g["main"]),
    )

    for group in ordered_groups:
        main = group["main"]
        children = [w for w in group["children"] if w in order]
        if not children or main not in order:
            continue

        # In the list after removing this repo's children, insert the child block
        # before whatever currently follows the main. Null means append at end.
        without_children = [w for w in order if w not in children]
        main_index = without_children.index(main)
        before = without_children[main_index + 1] if main_index + 1 < len(without_children) else None

        desired = without_children[: main_index + 1] + children + without_children[main_index + 1 :]
        if desired == order:
            continue

        request("workspace.move_block", {"workspace_ids": children, "before_workspace_id": before})
        order = desired
        moved += len(children)

    return moved


def main():
    try:
        snap = snapshot()
        groups = group_worktrees(snap.get("workspaces", []), snap.get("panes", []))
        opened = open_missing_mains(groups)
        if opened:
            snap = snapshot()
            groups = group_worktrees(snap.get("workspaces", []), snap.get("panes", []))
        moved = move_children_under_mains(snap.get("workspaces", []), groups)
    except Exception as exc:
        try:
            request("notification.show", {"title": "Worktree reparent failed", "body": str(exc), "sound": "request"})
        finally:
            sys.exit(f"herdr-reparent-worktrees: {exc}")

    request(
        "notification.show",
        {
            "title": "Worktrees reparented",
            "body": f"Opened {opened} main checkout(s), moved {moved} worktree space(s).",
            "sound": "none",
        },
    )


if __name__ == "__main__":
    main()

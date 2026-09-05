#!/usr/bin/env python3
"""Focus the main checkout's workspace, or open it if none exists."""

import json
import os
import subprocess
import sys


def herdr(*args):
    reply = json.loads(subprocess.check_output(["herdr", *args], text=True))
    if "error" in reply:
        raise RuntimeError(reply["error"])
    return reply["result"]


def focus_main(path):
    main = os.path.realpath(path)
    snapshot = herdr("api", "snapshot")["snapshot"]
    workspaces = snapshot["workspaces"]

    # Prefer a workspace registered for this checkout, regardless of pane cwd.
    for workspace in workspaces:
        checkout = (workspace.get("worktree") or {}).get("checkout_path")
        if checkout and os.path.realpath(checkout) == main:
            herdr("workspace", "focus", workspace["workspace_id"])
            return

    # Plain shell workspaces may only identify the checkout through pane cwd.
    # Resolve Git roots so a worktree nested under main is not mistaken for it.
    plain_ids = {w["workspace_id"] for w in workspaces if not w.get("worktree")}
    for pane in snapshot["panes"]:
        cwd = pane.get("cwd")
        if not cwd or pane["workspace_id"] not in plain_ids:
            continue
        cwd = os.path.realpath(cwd)
        if cwd != main:
            if not cwd.startswith(main + os.sep):
                continue
            try:
                root = subprocess.check_output(
                    ["git", "-C", cwd, "rev-parse", "--show-toplevel"],
                    text=True,
                    stderr=subprocess.DEVNULL,
                ).strip()
            except subprocess.CalledProcessError:
                continue
            if os.path.realpath(root) != main:
                continue
        herdr("workspace", "focus", pane["workspace_id"])
        return

    herdr("worktree", "open", "--cwd", main, "--path", main, "--focus")


if __name__ == "__main__":
    try:
        focus_main(sys.argv[1])
    except (OSError, ValueError, KeyError, RuntimeError, subprocess.CalledProcessError) as exc:
        sys.exit(f"could not focus the main checkout: {exc}")

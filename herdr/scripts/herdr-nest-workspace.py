#!/usr/bin/env python3
"""Move a Herdr workspace directly beneath its repo's main checkout.

`herdr worktree open` appends the new space to the end of the sidebar, so a
fresh worktree lands away from the repo it belongs to until something moves it.
This is the same move herdr-reparent-worktrees does, for one space, at the
moment it is created.

    nest-workspace.py WORKSPACE_ID MAIN_CHECKOUT_PATH
"""

import json
import os
import socket
import sys

SOCK = os.path.expanduser("~/.config/herdr/herdr.sock")


def request(method, params):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(10)
    s.connect(SOCK)
    s.sendall((json.dumps({"id": "nest-workspace", "method": method, "params": params}) + "\n").encode())
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


def main() -> int:
    workspace_id, main_path = sys.argv[1], os.path.realpath(sys.argv[2])
    snap = request("session.snapshot", {})["snapshot"]

    # Workspaces carry no cwd of their own, so the main checkout's space is the
    # one whose panes sit in it.
    owners = {
        p["workspace_id"]
        for p in snap["panes"]
        if p.get("cwd") and os.path.realpath(p["cwd"]) == main_path
    }
    order = [w["workspace_id"] for w in snap["workspaces"]]
    main_id = next((w for w in order if w in owners), None)
    if main_id is None or workspace_id not in order:
        # The repo's own space is not open, so there is nothing to sit under.
        return 0

    rest = [w for w in order if w != workspace_id]
    after = rest.index(main_id) + 1
    before = rest[after] if after < len(rest) else None
    if order == rest[:after] + [workspace_id] + rest[after:]:
        return 0

    request("workspace.move_block", {"workspace_ids": [workspace_id], "before_workspace_id": before})
    return 0


if __name__ == "__main__":
    sys.exit(main())

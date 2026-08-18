#!/usr/bin/env python3
"""Move the focused workspace one slot up or down in the spaces list.

Herdr has no built-in keybinding action for reordering spaces, but the socket
API exposes `workspace.move`, so we read the current order from a snapshot and
re-insert the focused workspace at the neighbouring index.

Usage: herdr-move-workspace.py up|down
Bound from ~/.config/herdr/config.toml as a [[keys.command]] type = "shell".
"""

import json
import os
import socket
import sys

SOCK = os.path.expanduser("~/.config/herdr/herdr.sock")


def request(method, params):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(5)
    s.connect(SOCK)
    s.sendall((json.dumps({"id": "move", "method": method, "params": params}) + "\n").encode())
    buf = b""
    while not buf.endswith(b"\n"):
        chunk = s.recv(65536)
        if not chunk:
            break
        buf += chunk
    s.close()
    reply = json.loads(buf.decode().splitlines()[0])
    if "error" in reply:
        sys.exit("herdr: {}".format(reply["error"].get("message", reply["error"])))
    return reply["result"]


def main():
    if len(sys.argv) != 2 or sys.argv[1] not in ("up", "down"):
        sys.exit("usage: herdr-move-workspace.py up|down")

    snap = request("session.snapshot", {})["snapshot"]
    order = [w["workspace_id"] for w in snap["workspaces"]]
    focused = snap.get("focused_workspace_id")
    if focused not in order:
        return

    index = order.index(focused)
    if sys.argv[1] == "up":
        if index == 0:
            return  # already first; stay put rather than wrapping
        target = index - 1
    else:
        if index == len(order) - 1:
            return  # already last
        # insert_index is resolved against the list *before* the workspace is
        # pulled out, so shifting down one slot means skipping past its own
        # position as well as its neighbour's — index + 1 is a no-op.
        target = index + 2

    request("workspace.move", {"workspace_id": focused, "insert_index": target})


if __name__ == "__main__":
    main()

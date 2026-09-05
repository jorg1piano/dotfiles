#!/usr/bin/env python3
"""Show cleanup failures in a tab when Herdr notifications are disabled."""

import json
import shlex
import subprocess
import sys


def herdr(*args):
    output = subprocess.check_output(["herdr", *args], text=True)
    # pane run succeeds without a JSON response.
    if not output.strip():
        return {}
    reply = json.loads(output)
    if "error" in reply:
        raise RuntimeError(reply["error"])
    return reply["result"]


def show_error(root, workspace, main, log, message):
    try:
        result = herdr(
            "notification", "show", "Worktree cleanup failed",
            "--body", f"{root}\n{message}\nLog file {log}", "--sound", "request",
        )
        if result.get("shown"):
            return
    except (OSError, ValueError, KeyError, RuntimeError, subprocess.CalledProcessError) as exc:
        print(f"could not show cleanup notification: {exc}", file=sys.stderr)

    # Use the main checkout as cwd because pop may have deleted the worktree.
    created = herdr(
        "tab", "create", "--workspace", workspace, "--cwd", main,
        "--label", "Cleanup failed", "--focus",
    )
    pane = created["root_pane"]["pane_id"]
    herdr("pane", "run", pane, shlex.join(["cat", "--", log]))


if __name__ == "__main__":
    try:
        show_error(*sys.argv[1:])
    except (OSError, ValueError, KeyError, RuntimeError, subprocess.CalledProcessError) as exc:
        sys.exit(f"could not show the cleanup log: {exc}")

#!/usr/bin/env python3
"""Fuzzy-search Herdr commands by name and run the chosen one.

Herdr has no command palette, and its CLI cannot trigger keybinding actions
directly, so this lists:

  - the built-in actions the CLI can perform (split, zoom, tabs, spaces, ...)
  - every [[keys.command]] in config.toml, under its description
  - every plugin action, under its title

Each row shows its key binding when it has one. The built-ins act on the pane
that was active when the popup opened (HERDR_ACTIVE_*), not the popup itself.

Bound from config.toml as the prefix+x popup.
"""

import json
import os
import subprocess
import sys
import tomllib

CONFIG = os.path.expanduser("~/.config/herdr/config.toml")

# Herdr's default bindings for the built-ins below; [keys] in config.toml overrides them.
DEFAULT_KEYS = {
    "split_vertical": "prefix+v",
    "split_horizontal": "prefix+minus",
    "zoom": "prefix+z",
    "close_pane": "prefix+x",
    "focus_pane_left": "prefix+h",
    "focus_pane_right": "prefix+l",
    "focus_pane_up": "prefix+k",
    "focus_pane_down": "prefix+j",
    "rename_pane": "prefix+shift+p",
    "new_tab": "prefix+c",
    "close_tab": "prefix+shift+x",
    "next_tab": "prefix+n",
    "previous_tab": "prefix+p",
    "rename_tab": "prefix+shift+t",
    "new_workspace": "prefix+shift+n",
    "rename_workspace": "prefix+shift+w",
    "reload_config": "prefix+shift+r",
}

pane = os.environ.get("HERDR_ACTIVE_PANE_ID", "")
tab = os.environ.get("HERDR_ACTIVE_TAB_ID", "")
workspace = os.environ.get("HERDR_ACTIVE_WORKSPACE_ID", "")
cwd = os.environ.get("HERDR_ACTIVE_PANE_CWD") or os.getcwd()


def herdr(*args):
    result = subprocess.run(["herdr", *args], capture_output=True, text=True)
    # Herdr can report an API error as JSON with a zero exit status.
    if result.returncode != 0 or '"error"' in result.stdout:
        raise SystemExit((result.stderr or result.stdout).strip() or f"herdr {args[0]} failed")
    return result.stdout


def ask(prompt):
    try:
        return input(prompt).strip()
    except EOFError:
        return ""


def rename(kind, target):
    label = ask(f"new {kind} name: ")
    if label:
        herdr(kind, "rename", target, label)


def step_tab(offset):
    tabs = json.loads(herdr("tab", "list", "--workspace", workspace))["result"]["tabs"]
    ids = [t["tab_id"] for t in tabs]
    if tab in ids and len(ids) > 1:
        herdr("tab", "focus", ids[(ids.index(tab) + offset) % len(ids)])


def split(direction):
    herdr("pane", "split", pane, "--direction", direction, "--cwd", cwd, "--focus")


BUILTINS = [
    ("Split vertical (new pane to the right)", "split_vertical", lambda: split("right")),
    ("Split horizontal (new pane below)", "split_horizontal", lambda: split("down")),
    ("Zoom pane (toggle fullscreen)", "zoom", lambda: herdr("pane", "zoom", pane, "--toggle")),
    ("Close pane", "close_pane", lambda: herdr("pane", "close", pane)),
    ("Rename pane", "rename_pane", lambda: rename("pane", pane)),
    *[
        (f"Focus pane {d}", f"focus_pane_{d}", lambda d=d: herdr("pane", "focus", "--direction", d, "--pane", pane))
        for d in ("left", "right", "up", "down")
    ],
    *[
        (f"Swap pane {d}", None, lambda d=d: herdr("pane", "swap", "--direction", d, "--pane", pane))
        for d in ("left", "right", "up", "down")
    ],
    ("Move pane to a new tab", None, lambda: herdr("pane", "move", pane, "--new-tab", "--focus")),
    ("Move pane to a new space", None, lambda: herdr("pane", "move", pane, "--new-workspace", "--focus")),
    ("New tab", "new_tab", lambda: herdr("tab", "create", "--workspace", workspace, "--cwd", cwd, "--focus")),
    ("Close tab", "close_tab", lambda: herdr("tab", "close", tab)),
    ("Next tab", "next_tab", lambda: step_tab(1)),
    ("Previous tab", "previous_tab", lambda: step_tab(-1)),
    ("Rename tab", "rename_tab", lambda: rename("tab", tab)),
    ("New space", "new_workspace", lambda: herdr("workspace", "create", "--cwd", cwd, "--focus")),
    ("Rename space", "rename_workspace", lambda: rename("workspace", workspace)),
    ("Reload config", "reload_config", lambda: herdr("server", "reload-config")),
]


def run_custom(command):
    kind, line = command.get("type"), command.get("command", "")
    if kind == "plugin_action":
        plugin, _, action = line.rpartition(".")
        herdr("plugin", "action", "invoke", action, "--plugin", plugin)
    elif kind == "popup":
        # Already in a popup, so hand the terminal over to the command.
        os.execvp("sh", ["sh", "-c", line])
    else:
        subprocess.run(["sh", "-c", line])


def plugin_actions():
    try:
        actions = json.loads(herdr("plugin", "action", "list"))["result"]["actions"]
    except (SystemExit, ValueError, KeyError):
        return []
    return actions


def entries():
    with open(CONFIG, "rb") as f:
        config = tomllib.load(f)
    keys = {**DEFAULT_KEYS, **{k: v for k, v in config.get("keys", {}).items() if isinstance(v, str)}}

    rows = [(label, keys.get(name, "") if name else "", run) for label, name, run in BUILTINS]

    # A command bound to several keys gets one row listing all of them.
    custom = {}
    for command in config.get("keys", {}).get("command", []):
        line = command.get("command", "")
        # Skip the palette's own binding.
        if "herdr-command-palette" in line:
            continue
        label = (command.get("description") or line).rstrip(".")
        row = custom.setdefault((command.get("type"), line), [label, [], command])
        if command.get("key"):
            row[1].append(command["key"])
    for label, bound, command in custom.values():
        rows.append((label, ", ".join(bound), lambda c=command: run_custom(c)))
    bound_actions = {line for kind, line in custom if kind == "plugin_action"}

    for action in plugin_actions():
        qualified = f"{action['plugin_id']}.{action['action_id']}"
        if qualified in bound_actions:
            continue
        run = lambda a=action: herdr("plugin", "action", "invoke", a["action_id"], "--plugin", a["plugin_id"])
        rows.append((action["title"], "", run))
    return rows


def main():
    rows = entries()
    # Long descriptions would push every key far right, so wrap the column at 56.
    width = min(max(len(label) for label, _, _ in rows), 56)
    lines = "\n".join(f"{i}\t{label.ljust(width)}  {key}" for i, (label, key, _) in enumerate(rows))
    picked = subprocess.run(
        ["fzf", "--height=100%", "--reverse", "--prompt=command > ", "--delimiter=\t", "--with-nth=2"],
        input=lines,
        stdout=subprocess.PIPE,
        text=True,
    ).stdout.strip()
    if not picked:
        return
    _, _, run = rows[int(picked.split("\t", 1)[0])]
    run()


if __name__ == "__main__":
    try:
        main()
    except SystemExit as error:
        if error.code not in (None, 0):
            print(error.code, file=sys.stderr)
            ask("\npress enter to close ")
        raise

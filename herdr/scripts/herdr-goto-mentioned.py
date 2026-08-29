#!/usr/bin/env python3
"""Go to the space or pane the focused pane is talking about.

An agent that answers "w3F is waiting on a yes/no" has already done the hard
part: it named the place. This reads the focused pane's recent output, keeps the
ids that actually exist in the session, and lists them newest mention first.
Pick one and it focuses that space or pane.

Bound from ~/.config/herdr/config.toml as a [[keys.command]] popup, which runs
this in its own pane and exports HERDR_PANE_ID / HERDR_TAB_ID for it.
"""

import json
import os
import re
import subprocess
import sys

LINES = os.environ.get("HERDR_GOTO_LINES", "400")

# Ids as Herdr prints them: w2, w6R, w3F:pF, w2:t1. The trailing lookahead keeps
# "w2" out of words like "w2x" while still allowing the ":pF" suffix.
ID_RE = re.compile(r"\bw[0-9A-Za-z]{1,4}(?::[ptw][0-9A-Za-z]{1,4})?(?![0-9A-Za-z:])")

# Homebrew is not on a popup's login-less PATH.
os.environ["PATH"] = os.environ.get("PATH", "") + ":/opt/homebrew/bin:/usr/local/bin"


LOG = os.environ.get("HERDR_GOTO_LOG", os.path.expanduser("~/.cache/herdr-goto.log"))


def note(message):
    """Popups vanish on exit, so every run leaves a trace here instead."""
    try:
        os.makedirs(os.path.dirname(LOG), exist_ok=True)
        with open(LOG, "a", encoding="utf-8") as handle:
            handle.write(message.rstrip() + "\n")
    except OSError:
        pass


def die(message):
    note("die: " + message)
    print("herdr-goto-mentioned: %s" % message, file=sys.stderr)
    try:
        with open("/dev/tty") as tty:
            print("\npress enter to close ", end="", file=sys.stderr, flush=True)
            tty.readline()
    except OSError:
        pass
    sys.exit(1)


def herdr(*args, capture=True):
    try:
        result = subprocess.run(
            ["herdr", *args], capture_output=capture, text=True, check=False
        )
    except FileNotFoundError:
        die("herdr is not on PATH")
    if result.returncode != 0:
        die("herdr %s failed: %s" % (" ".join(args), (result.stderr or "").strip()))
    return result.stdout


def snapshot():
    try:
        return json.loads(herdr("api", "snapshot"))["result"]["snapshot"]
    except (ValueError, KeyError):
        die("could not read the session snapshot")


def source_pane(snap):
    """The pane that was focused when the popup opened, never the popup itself."""
    own = os.environ.get("HERDR_PANE_ID", "")
    tab = os.environ.get("HERDR_TAB_ID", "")
    others = [pane for pane in snap["panes"] if pane["pane_id"] != own]
    # Herdr hands a [[keys.command]] popup the pane that was focused when the
    # key was pressed. By the time this runs, "focused" is the popup itself,
    # so this is the only reliable answer; the heuristics below are a fallback.
    active = os.environ.get("HERDR_ACTIVE_PANE_ID", "")
    for pane in snap["panes"]:
        if pane["pane_id"] == active:
            return pane
    for group in (
        [pane for pane in others if pane["pane_id"] == snap.get("focused_pane_id")],
        [pane for pane in others if pane.get("focused")],
        [pane for pane in others if pane.get("tab_id") == tab],
        others,
    ):
        if group:
            return group[0]
    die("no other pane to read")


def resolve(token, snap):
    """(workspace_id, tab_id or None) that focusing this token would land on."""
    for pane in snap["panes"]:
        if pane["pane_id"] == token:
            return pane["workspace_id"], pane["tab_id"]
    for tab in snap["tabs"]:
        if tab["tab_id"] == token:
            return tab["workspace_id"], token
    for workspace in snap["workspaces"]:
        if workspace["workspace_id"] == token:
            return token, None
    return None


def describe(token, snap):
    spaces = {ws["workspace_id"]: ws for ws in snap["workspaces"]}
    for pane in snap["panes"]:
        if pane["pane_id"] == token:
            # A plain shell has no terminal title, so name it by its space.
            title = (pane.get("terminal_title_stripped")
                     or (spaces.get(pane["workspace_id"], {}).get("label"))
                     or os.path.basename(pane.get("cwd") or ""))
            return "pane", title.strip()
    for tab in snap["tabs"]:
        if tab["tab_id"] == token:
            return "tab", (tab.get("label") or "").strip()
    if token in spaces:
        return "space", (spaces[token].get("label") or "").strip()
    return None, ""


def candidates(text, snap, source):
    """Ids in the text that exist and would move focus, newest mention first."""
    here = (source["workspace_id"], source["tab_id"])

    found, crowded, seen = [], [], set()
    for line in reversed(text.splitlines()):
        # A line naming four or more ids is a listing, not someone telling you
        # where to go. Those still belong in the picker, just under the real
        # references.
        bucket = crowded if len(set(ID_RE.findall(line))) >= 4 else found
        for token in ID_RE.findall(line):
            if token in seen:
                continue
            target = resolve(token, snap)
            if target is None:
                continue
            # Already here: a bare space id for this space, or a pane in this
            # very tab. Focusing either is a no-op, so it is not a destination.
            if target[0] == here[0] and target[1] in (None, here[1]):
                continue
            seen.add(token)
            kind, title = describe(token, snap)
            bucket.append((token, kind, title, line.strip(), target))

    # "w3F" and "w3F:pF" in the same buffer are one destination named twice.
    # Keep the pane or tab id, since it lands on the right tab, and hold the
    # position of whichever was mentioned most recently.
    rows = found + crowded
    specific = {target[0] for _, kind, _, _, target in rows if kind != "space"}
    return [row for row in rows if row[1] != "space" or row[4][0] not in specific]


def pick(found):
    rows = [
        "%s\t%-5s %-24s %s" % (token, kind, title[:24], context[:90])
        for token, kind, title, context, _ in found
    ]
    try:
        result = subprocess.run(
            [
                "fzf",
                "--height=100%",
                "--reverse",
                "--delimiter=\t",
                "--with-nth=2..",
                "--prompt=goto > ",
                "--header=mentioned in the focused pane — newest first",
            ],
            input="\n".join(rows),
            # fzf draws its interface on stderr and reads keys from /dev/tty.
            # Capturing stderr swallows the whole UI, which is what left the
            # popup blank; only the selection on stdout may be taken.
            stdout=subprocess.PIPE,
            text=True,
        )
    except FileNotFoundError:
        die("fzf is not on PATH (brew install fzf)")
    line = result.stdout.strip()
    if not line:
        sys.exit(0)
    return line.split("\t", 1)[0]


def focus(token, snap):
    panes = {pane["pane_id"]: pane for pane in snap["panes"]}
    tabs = {tab["tab_id"]: tab for tab in snap["tabs"]}

    if token in panes:
        workspace, tab = panes[token]["workspace_id"], panes[token]["tab_id"]
    elif token in tabs:
        workspace, tab = tabs[token]["workspace_id"], token
    else:
        workspace, tab = token, None

    herdr("workspace", "focus", workspace)
    # There is no focus-pane-by-id in the CLI, so a pane id lands on its tab;
    # inside a tab the agent pane is the one that keeps focus anyway.
    if tab:
        herdr("tab", "focus", tab)


def main():
    note("run: %s" % " ".join(
        "%s=%s" % (name, os.environ.get(name, ""))
        for name in ("HERDR_ENV", "HERDR_PANE_ID", "HERDR_TAB_ID",
                     "HERDR_ACTIVE_PANE_ID", "HERDR_WORKSPACE_ID")
    ))

    if os.environ.get("HERDR_ENV") != "1":
        die("not running inside a Herdr pane")

    snap = snapshot()
    pane = source_pane(snap)
    text = herdr(
        "pane", "read", pane["pane_id"],
        "--source", "recent-unwrapped", "--lines", LINES, "--format", "text",
    )

    found = candidates(text, snap, pane)
    if not found:
        die("no space or pane id mentioned in the last %s lines of %s"
            % (LINES, pane["pane_id"]))

    if os.environ.get("HERDR_GOTO_DRY_RUN") == "1":
        for token, kind, title, context, _ in found:
            print("%s\t%s\t%s\t%s" % (token, kind, title, context[:80]))
        return

    note("candidates: %s" % " ".join(row[0] for row in found))
    token = pick(found)
    note("focus: %s" % token)
    focus(token, snap)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Pick something mentioned in the focused pane and open it.

Finds useful targets in the recent pane output: URLs/localhost ports, common
local dev surfaces (Storybook/app/Metro), Android emulator serials/AVD names,
and iOS Simulator UDIDs. Presents them in fzf so enter or click opens one.
"""

import json
import os
import re
import shlex
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

LINES = os.environ.get("HERDR_OPEN_LINES", "600")
RECENT_LINES = os.environ.get("HERDR_OPEN_RECENT_LINES", "100")
LOG = os.environ.get("HERDR_OPEN_LOG", os.path.expanduser("~/.cache/herdr-open-mentioned.log"))
home = os.path.expanduser("~")
os.environ["PATH"] = os.environ.get("PATH", "") + f":/opt/homebrew/bin:/usr/local/bin:{home}/Library/Android/sdk/emulator:{home}/Library/Android/sdk/platform-tools:/Applications/Xcode.app/Contents/Developer/usr/bin"

URL_RE = re.compile(r"https?://[^\s)'\"]+")
LOCAL_RE = re.compile(r"\b(?:localhost|127\.0\.0\.1|0\.0\.0\.0)(?::\d{2,5})(?:/[^\s)'\"]*)?")
PATH_RE = re.compile(r"(?<![\w])(?:~|/)[^\s)'\"]+")
ANDROID_SERIAL_RE = re.compile(r"\bemulator-\d{4,5}\b")
AVD_NAME_RE = re.compile(r"\bwet-[A-Za-z0-9_.-]+\b")
ADB_DEVICE_LINE_RE = re.compile(r"^\s*([A-Za-z0-9_.:-]+)\s+device\b", re.M)
FLUTTER_DEVICE_RE = re.compile(r"\b(?:Launching .* on|Syncing files to device|A Dart VM Service on|DevTools .* on)\s+(.+?)\s+(?:in debug mode|\.\.\.|is available)", re.I)
IOS_UDID_RE = re.compile(r"\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\b")
PORT_RE = re.compile(r"\b(?:port|listening on|running on|server on|phx|phoenix|grpc)\D{0,20}(\d{3,5})\b", re.I)


@dataclass(frozen=True)
class Candidate:
    key: str
    label: str
    detail: str
    command: str


def note(message: str) -> None:
    try:
        os.makedirs(os.path.dirname(LOG), exist_ok=True)
        with open(LOG, "a", encoding="utf-8") as handle:
            handle.write(message.rstrip() + "\n")
    except OSError:
        pass


def die(message: str) -> None:
    note("die: " + message)
    print(f"herdr-open-mentioned: {message}", file=sys.stderr)
    try:
        with open("/dev/tty") as tty:
            print("\npress enter to close ", end="", file=sys.stderr, flush=True)
            tty.readline()
    except OSError:
        pass
    sys.exit(1)


def run(args, *, input_text=None, check=False):
    try:
        return subprocess.run(args, input=input_text, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=check)
    except FileNotFoundError:
        return None


def herdr(*args) -> str:
    result = run(["herdr", *args])
    if result is None:
        die("herdr is not on PATH")
    if result.returncode != 0:
        die("herdr %s failed: %s" % (" ".join(args), result.stderr.strip()))
    return result.stdout


def snapshot():
    try:
        return json.loads(herdr("api", "snapshot"))["result"]["snapshot"]
    except (ValueError, KeyError):
        die("could not read the session snapshot")


def source_pane(snap):
    active = os.environ.get("HERDR_ACTIVE_PANE_ID", "")
    own = os.environ.get("HERDR_PANE_ID", "")
    for pane in snap.get("panes", []):
        if pane.get("pane_id") == active:
            return pane
    for pane in snap.get("panes", []):
        if pane.get("pane_id") != own and pane.get("focused"):
            return pane
    for pane in snap.get("panes", []):
        if pane.get("pane_id") != own:
            return pane
    die("no pane to read")


def panes_to_scan(snap, source):
    """All panes in the source window/tab.

    Herdr's popup is its own pane, but HERDR_ACTIVE_PANE_ID points at the pane
    that was active before it opened. Scan every pane with that pane's tab_id so
    prefix+O sees the app/server pane and the agent pane in the same window.
    """
    source_tab = source.get("tab_id")
    selected = [
        pane for pane in snap.get("panes", [])
        if pane.get("tab_id") == source_tab
        and pane.get("pane_id") != os.environ.get("HERDR_PANE_ID", "")
    ]
    return selected or [source]


def read_panes(panes, lines=LINES):
    chunks = []
    for pane in panes:
        title = pane.get("terminal_title_stripped") or pane.get("pane_id")
        text = herdr("pane", "read", pane["pane_id"], "--source", "recent-unwrapped", "--lines", str(lines), "--format", "text")
        chunks.append(f"\n--- {pane['pane_id']} {title} ---\n{text}")
    return "\n".join(chunks)


def add(candidates, seen, kind, label, detail, command):
    key = f"{label}:{command}"
    if key not in seen:
        seen.add(key)
        candidates.append(Candidate(key, label, detail, command))


def shell_quote(s: str) -> str:
    return shlex.quote(s)


def open_url_command(url: str) -> str:
    return "open -a 'Google Chrome' " + shell_quote(url)


def open_path_command(path: str) -> str:
    quoted = shell_quote(path)
    return f"if [ -d {quoted} ]; then open {quoted}; else open -R {quoted}; fi"


def open_file_command(path: str) -> str:
    return "open " + shell_quote(path)


def open_emulator_command(identifier: str) -> str:
    script = os.path.expanduser("~/dotfiles/herdr/scripts/herdr-open-android-emulator.sh")
    return f"{shell_quote(script)} {shell_quote(identifier)}"


def parse_dotenv(path: str) -> dict[str, str]:
    values = {}
    try:
        for line in Path(path).read_text(encoding="utf-8", errors="replace").splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            values[key.strip()] = value.strip().strip('"').strip("'")
    except OSError:
        pass
    return values


def git_main_checkout(cwd: str) -> str:
    result = run(["git", "-C", cwd, "rev-parse", "--path-format=absolute", "--git-common-dir"])
    if result and result.returncode == 0:
        return str(Path(result.stdout.strip()).parent)
    return ""


def config_paths(source: dict) -> list[str]:
    roots = []
    cwd = source.get("foreground_cwd") or source.get("cwd") or os.getcwd()
    for root in (cwd, git_main_checkout(cwd), os.path.expanduser("~/github/devda/sendi"), os.path.expanduser("~/github/devda/wet")):
        if root and root not in roots and os.path.exists(root):
            roots.append(root)
    return roots


def add_project_config_candidates(candidates, seen, source):
    """Put known project endpoints from config files at the top of the picker."""
    for root in config_paths(source):
        env = parse_dotenv(os.path.join(root, ".env.worktree"))
        label_prefix = os.path.basename(root.rstrip(os.sep))
        phx = env.get("PHX_PORT")
        tidewave = env.get("TIDEWAVE_PORT")
        device = env.get("FLUTTER_DEVICE_ID")

        if phx:
            add(candidates, seen, "config", f"Phoenix — {label_prefix} — localhost:{phx}", ".env.worktree", open_url_command(f"http://localhost:{phx}"))
        if tidewave:
            add(candidates, seen, "config", f"Tidewave — {label_prefix} — localhost:{tidewave}", ".env.worktree", open_url_command(f"http://localhost:{tidewave}"))
        # Storybook is convention-based for now; if a project exposes it, keep
        # it near the top next to Phoenix instead of buried in pane output.
        if os.path.exists(os.path.join(root, "mobile_elixir")) or os.path.exists(os.path.join(root, "web_elixir")):
            add(candidates, seen, "config", f"Storybook — {label_prefix} — localhost:6006", "project default", open_url_command("http://localhost:6006"))
        if device:
            add(candidates, seen, "config", f"Android emulator — {label_prefix} — {device}", ".env.worktree", open_emulator_command(device))

        worktrees = os.path.join(root, ".wet-worktrees.json")
        try:
            data = json.loads(Path(worktrees).read_text(encoding="utf-8"))
        except (OSError, ValueError):
            data = {}
        for item in data.get("worktrees", []):
            branch = item.get("branch") or os.path.basename(item.get("path", "worktree"))
            ports = item.get("ports") or {}
            pools = item.get("pools") or {}
            if ports.get("PHX_PORT"):
                add(candidates, seen, "config", f"Phoenix — {branch} — localhost:{ports['PHX_PORT']}", ".wet-worktrees.json", open_url_command(f"http://localhost:{ports['PHX_PORT']}"))
            if ports.get("TIDEWAVE_PORT"):
                add(candidates, seen, "config", f"Tidewave — {branch} — localhost:{ports['TIDEWAVE_PORT']}", ".wet-worktrees.json", open_url_command(f"http://localhost:{ports['TIDEWAVE_PORT']}"))
            device = str(pools.get("devices", "")).removeprefix("emulator:")
            if device:
                add(candidates, seen, "config", f"Android emulator — {branch} — {device}", ".wet-worktrees.json", open_emulator_command(device))


def android_avds():
    result = run([os.path.expanduser("~/Library/Android/sdk/emulator/emulator"), "-list-avds"])
    if not (result and result.returncode == 0):
        result = run(["emulator", "-list-avds"])
    if result and result.returncode == 0:
        return [line.strip() for line in result.stdout.splitlines() if line.strip()]
    return []


def avd_for_serial(serial: str) -> str:
    result = run(["adb", "-s", serial, "emu", "avd", "name"])
    if result and result.returncode == 0:
        for line in result.stdout.splitlines():
            line = line.strip()
            if line and line.upper() != "OK":
                return line
    return ""


def collect(text: str, source=None, priority_text=None):
    candidates, seen = [], set()

    # Put things mentioned in the last N lines first. Then config-derived
    # defaults. Then older mentions from the larger scrollback window.
    if priority_text:
        for candidate in collect(priority_text):
            add(candidates, seen, "recent", candidate.label, candidate.detail, candidate.command)

    if source:
        add_project_config_candidates(candidates, seen, source)

    lower = text.lower()

    for match in URL_RE.finditer(text):
        url = match.group(0).rstrip(".,;]")
        if not re.search(r"https?://(?:localhost|127\.0\.0\.1|0\.0\.0\.0|192\.168\.)", url):
            continue
        label = url.replace("http://", "").replace("https://", "")[:72]
        add(candidates, seen, "url", label, "local URL", open_url_command(url))

    for match in LOCAL_RE.finditer(text):
        url = match.group(0).rstrip(".,;]")
        if url.startswith("0.0.0.0"):
            url = "localhost" + url[len("0.0.0.0"):]
        if not url.startswith("http"):
            url = "http://" + url
        label = url.replace("http://", "")[:72]
        add(candidates, seen, "local", label, "local dev server", open_url_command(url))

    for match in PATH_RE.finditer(text):
        path = match.group(0).rstrip(".,;:]")
        # Avoid treating URL paths as Finder paths.
        if path.startswith("//"):
            continue
        expanded = os.path.expanduser(path)
        if os.path.exists(expanded):
            name = os.path.basename(expanded.rstrip(os.sep)) or expanded
            parent = os.path.basename(os.path.dirname(expanded.rstrip(os.sep)))
            if os.path.isfile(expanded) and name.lower().endswith((".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp")):
                label = expanded
                detail = "image file"
                command = open_file_command(expanded)
            elif os.path.isfile(expanded):
                label = expanded
                detail = "file in Finder"
                command = open_path_command(expanded)
            else:
                label = expanded
                detail = "folder in Finder"
                command = open_path_command(expanded)
            add(candidates, seen, "path", label, detail, command)

    if "storybook" in lower and "localhost:6006" not in lower:
        add(candidates, seen, "default", "Storybook — localhost:6006", "inferred from “storybook”", open_url_command("http://localhost:6006"))
    if any(word in lower for word in ("phoenix", "localhost app", "running application", "web app")) and "localhost:4000" not in lower:
        add(candidates, seen, "default", "App — localhost:4000", "inferred local app", open_url_command("http://localhost:4000"))
    if any(word in lower for word in ("metro", "react native", "mobile run")) and "localhost:8081" not in lower:
        add(candidates, seen, "default", "Metro — localhost:8081", "inferred mobile bundler", open_url_command("http://localhost:8081"))

    available_avds = set(android_avds())
    serial_to_avd = {}
    for serial, avd in re.findall(r"\b(emulator-\d{4,5})\b[^\n]*(?:\(|=\s*emulator:|→|:)?\s*(wet-[A-Za-z0-9_.-]+)?", text):
        if avd:
            serial_to_avd[serial] = avd

    for serial in ANDROID_SERIAL_RE.findall(text):
        avd = serial_to_avd.get(serial) or avd_for_serial(serial)
        detail = f"Android emulator {serial}" + (f" ({avd})" if avd else "")
        cmd = open_emulator_command(avd or serial)
        add(candidates, seen, "android", serial, detail, cmd)

    for serial in ADB_DEVICE_LINE_RE.findall(text):
        if serial == "List":
            continue
        if ANDROID_SERIAL_RE.fullmatch(serial):
            continue
        add(candidates, seen, "device", serial, "attached Android device", "open -a 'Android File Transfer' 2>/dev/null || true")

    for name in FLUTTER_DEVICE_RE.findall(text):
        device = re.sub(r"\s+", " ", name).strip().rstrip(".")
        if device and not device.startswith("http"):
            add(candidates, seen, "flutter-device", device, "Flutter target device", "open -a 'Android Emulator'")

    mentioned_avds = set(AVD_NAME_RE.findall(text)) | (available_avds & set(text.split()))
    for avd in sorted(mentioned_avds):
        if not available_avds or avd in available_avds:
            add(candidates, seen, "avd", avd, "Android Virtual Device", open_emulator_command(avd))

    for udid in IOS_UDID_RE.findall(text):
        # Screenshot/task paths often contain UUID directory names; don't offer
        # those as iOS simulators unless the surrounding text says simulator.
        if re.search(r"/[^\s]*" + re.escape(udid) + r"[^\s]*/", text) and not re.search(r"(?:ios|simulator|simctl)[^\n]{0,80}" + re.escape(udid), text, re.I):
            continue
        add(candidates, seen, "ios", udid, "iOS Simulator device", f"xcrun simctl boot {shell_quote(udid)} >/dev/null 2>&1 || true; open -a Simulator --args -CurrentDeviceUDID {shell_quote(udid)}")

    return candidates


def display_category(candidate):
    text = f"{candidate.label} {candidate.detail}".lower()
    if "android" in text or "emulator" in text or "flutter target" in text or "attached android" in text:
        return "mobile"
    if "storybook" in text:
        return "storybook"
    if "phoenix" in text:
        return "phoenix"
    if "tidewave" in text:
        return "tidewave"
    if "image" in text:
        return "images"
    if "finder" in text or "folder" in text or "file" in text:
        return "paths"
    if "localhost" in text or "local url" in text or "local dev server" in text:
        return "web"
    return "other"


def display_label(candidate):
    label = candidate.label
    detail = candidate.detail
    if detail in ("image file", "file in Finder"):
        parent = os.path.basename(os.path.dirname(label.rstrip(os.sep)))
        return f"{os.path.basename(label)}  ({parent})"
    if detail == "folder in Finder":
        return label.rstrip(os.sep) + "/"
    return label


def ellipsize(value, width):
    value = str(value)
    if len(value) <= width:
        return value
    return value[: max(1, width - 1)] + "…"


def display_rows(candidates):
    rows = []
    kind_width = 10
    target_width = 84
    source_width = 22
    for c in candidates:
        category = display_category(c)
        target = ellipsize(display_label(c), target_width)
        source = ellipsize(c.detail, source_width)
        table_row = f"{category:<{kind_width}} │ {target:<{target_width}} │ {source:<{source_width}}"
        # Field 1 is hidden but searchable, so typing category names like
        # "mobile", "phoenix", "storybook", "tidewave", or "paths" matches
        # every item in that group. Field 3 stays hidden and carries the full
        # command/path, so long paths remain searchable without visual noise.
        search_key = f"{category} {c.key} {c.detail} {c.command}"
        rows.append(f"{search_key}\t{table_row}\t{c.command}")
    return rows


def pick(candidates):
    rows = display_rows(candidates)
    try:
        result = subprocess.run(
            [
                "fzf",
                "--height=100%",
                "--reverse",
                "--delimiter=\t",
                "--with-nth=2",
                "--nth=1,2,3",
                "--prompt=open > ",
                "--header=KIND       │ TARGET                                                                               │ SOURCE\nenter/click opens the selected item",
                "--bind=left-click:accept,double-click:accept",
            ],
            input="\n".join(rows),
            # fzf draws the UI on stderr and reads from /dev/tty. Capturing
            # stderr makes the Herdr popup look blank; only capture selection.
            stdout=subprocess.PIPE,
            text=True,
        )
    except FileNotFoundError:
        die("fzf is not on PATH (brew install fzf)")
    line = result.stdout.strip()
    if not line:
        sys.exit(0)
    return line.split("\t", 2)[2]


def main():
    if os.environ.get("HERDR_ENV") != "1":
        die("not running inside a Herdr pane")
    snap = snapshot()
    pane = source_pane(snap)
    panes = panes_to_scan(snap, pane)
    recent_text = read_panes(panes, RECENT_LINES)
    text = read_panes(panes, LINES)
    candidates = collect(text, pane, recent_text)
    if not candidates:
        die(f"no URLs, localhost ports, emulator ids, AVD/device names, or simulator UDIDs in the last {LINES} lines")
    if os.environ.get("HERDR_OPEN_DRY_RUN") == "1":
        for candidate in candidates:
            print(f"{candidate.label}\t{candidate.detail}\t{candidate.command}")
        return
    command = pick(candidates)
    note("run: " + command)
    result = subprocess.run(["/bin/bash", "-lc", command], text=True)
    note(f"exit {result.returncode}: {command}")
    if result.returncode != 0:
        die(f"open command failed ({result.returncode}): {command}")


if __name__ == "__main__":
    main()

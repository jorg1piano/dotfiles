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

LINES = os.environ.get("HERDR_OPEN_LINES", "600")
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


def read_panes(panes):
    chunks = []
    for pane in panes:
        title = pane.get("terminal_title_stripped") or pane.get("pane_id")
        text = herdr("pane", "read", pane["pane_id"], "--source", "recent-unwrapped", "--lines", LINES, "--format", "text")
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


def open_emulator_command(identifier: str) -> str:
    script = os.path.expanduser("~/dotfiles/herdr/scripts/herdr-open-android-emulator.sh")
    return f"{shell_quote(script)} {shell_quote(identifier)}"


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


def collect(text: str):
    candidates, seen = [], set()
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
            label = path if len(path) <= 90 else "…" + path[-89:]
            detail = "folder in Finder" if os.path.isdir(expanded) else "file in Finder"
            add(candidates, seen, "path", label, detail, open_path_command(expanded))

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
        add(candidates, seen, "ios", udid, "iOS Simulator device", f"xcrun simctl boot {shell_quote(udid)} >/dev/null 2>&1 || true; open -a Simulator --args -CurrentDeviceUDID {shell_quote(udid)}")

    return candidates


def pick(candidates):
    rows = [f"{c.key}\t{c.label}\t{c.detail}\t{c.command}" for c in candidates]
    try:
        result = subprocess.run(
            [
                "fzf",
                "--height=100%",
                "--reverse",
                "--delimiter=\t",
                "--with-nth=2,3",
                "--prompt=open > ",
                "--header=enter/click opens the selected item",
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
    return line.split("\t", 3)[3]


def main():
    if os.environ.get("HERDR_ENV") != "1":
        die("not running inside a Herdr pane")
    snap = snapshot()
    pane = source_pane(snap)
    text = read_panes(panes_to_scan(snap, pane))
    candidates = collect(text)
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

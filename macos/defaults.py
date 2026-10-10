#!/usr/bin/env python3
"""Apply this repo's macOS settings. Safe to run again: only values that differ
get written, and only the apps whose settings changed get restarted.

    python3 macos/defaults.py        apply
    python3 macos/defaults.py save   copy this Mac's shortcuts and input sources into the repo

The settings below are the ones changed from the macOS defaults on the Mac this
repo came from. Keyboard shortcuts and input sources are long nested values, so
they live in plist files next to this script instead.
"""

import plistlib
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent

SETTINGS = {
    "NSGlobalDomain": {
        "AppleInterfaceStyle": "Dark",
        "AppleLanguages": ["en-NO", "nb-NO"],
        "AppleLocale": "en_NO",
        # Natural scrolling off.
        "com.apple.swipescrolldirection": False,
        # F1-F12 act as function keys; hold fn for brightness and volume.
        "com.apple.keyboard.fnState": True,
        # No back/forward on a two-finger swipe in browsers.
        "AppleEnableSwipeNavigateWithScrolls": False,
        # Double-clicking a title bar zooms instead of minimizing.
        "AppleMiniaturizeOnDoubleClick": False,
    },
    "com.apple.dock": {
        "autohide": True,
        "orientation": "bottom",
        "tilesize": 34.0,
        "show-recents": False,
        # Bottom-right hot corner opens Quick Note.
        "wvous-br-corner": 14,
        "wvous-br-modifier": 0,
    },
    "com.apple.finder": {
        "FXPreferredViewStyle": "glyv",
        "ShowHardDrivesOnDesktop": False,
        "ShowExternalHardDrivesOnDesktop": True,
        "ShowRemovableMediaOnDesktop": True,
    },
    "com.apple.WindowManager": {
        # Clicking the wallpaper only shows the desktop in Stage Manager.
        "HideDesktop": True,
        "AppWindowGroupingBehavior": 1,
    },
    "com.apple.screencapture": {
        "show-thumbnail": False,
    },
    "com.apple.menuextra.clock": {
        "ShowAMPM": True,
        "ShowDate": 0,
        "ShowDayOfWeek": True,
    },
}

# Keys copied whole from this Mac by `save`, stored as <domain>.plist.
SAVED = {
    "com.apple.symbolichotkeys": ["AppleSymbolicHotKeys"],
    "com.apple.HIToolbox": ["AppleEnabledInputSources", "AppleSelectedInputSources"],
}

# Which process to restart so a changed domain takes effect.
RESTART = {
    "com.apple.dock": ["Dock"],
    "com.apple.WindowManager": ["Dock"],
    "com.apple.finder": ["Finder"],
    "com.apple.screencapture": ["SystemUIServer"],
    "com.apple.menuextra.clock": ["ControlCenter"],
}

ACTIVATE_SETTINGS = (
    "/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings"
)


def read_domain(domain):
    out = subprocess.run(["defaults", "export", domain, "-"], capture_output=True, check=True)
    return plistlib.loads(out.stdout)


def same(a, b):
    # plistlib reads 1 back as int and True as bool, and defaults stores some
    # integers as floats, so compare by value, with booleans as 0 and 1.
    if isinstance(a, (bool, int, float)) and isinstance(b, (bool, int, float)):
        return float(a) == float(b)
    return a == b


def save():
    for domain, keys in SAVED.items():
        current = read_domain(domain)
        path = HERE / f"{domain}.plist"
        path.write_bytes(plistlib.dumps({k: current[k] for k in keys if k in current}, sort_keys=True))
        print(f"saved {path}")


def apply():
    settings = {domain: dict(values) for domain, values in SETTINGS.items()}
    for domain in SAVED:
        path = HERE / f"{domain}.plist"
        settings.setdefault(domain, {}).update(plistlib.loads(path.read_bytes()))

    changed = set()
    for domain, values in settings.items():
        current = read_domain(domain)
        for key, value in values.items():
            if key in current and same(current[key], value):
                continue
            subprocess.run(["defaults", "write", domain, key, plistlib.dumps(value).decode()], check=True)
            changed.add(domain)
            print(f"set   {domain} {key}")

    if not changed:
        print("ok    macOS settings")
        return

    for process in sorted({p for d in changed for p in RESTART.get(d, [])}):
        subprocess.run(["killall", process], capture_output=True)
    # Keyboard shortcuts and global settings are read at login. This makes the
    # running session pick most of them up; input sources still need a logout.
    subprocess.run([ACTIVATE_SETTINGS, "-u"], capture_output=True)
    if "com.apple.HIToolbox" in changed:
        print("      log out and back in for the input sources to apply")


if __name__ == "__main__":
    save() if sys.argv[1:] == ["save"] else apply()

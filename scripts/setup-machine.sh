#!/usr/bin/env bash
# Install the agent CLIs and window tools with Homebrew, then put the Rectangle
# shortcuts and Hammerspoon config from this repo in place. Safe to run again:
# anything already installed, by brew or another installer, is skipped.
#
#   ./scripts/setup-machine.sh                 install and apply
#   ./scripts/setup-machine.sh save-rectangle  copy this Mac's Rectangle settings into the repo
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
rectangle_domain=com.knollsoft.Rectangle
rectangle_plist="$repo/rectangle/com.knollsoft.Rectangle.plist"

# Rectangle's prefs also hold window frames, file-dialog bookmarks and updater
# state. Keep only its own settings so the file means the same on every Mac.
rectangle_settings() {
  defaults export "$rectangle_domain" - | python3 -c '
import plistlib, sys
d = plistlib.loads(sys.stdin.buffer.read())
keep = {k: v for k, v in d.items() if not k.startswith(("NS", "SU")) and k != "lastVersion"}
sys.stdout.buffer.write(plistlib.dumps(keep, sort_keys=True))'
}

if [ "${1:-}" = save-rectangle ]; then
  mkdir -p "$(dirname "$rectangle_plist")"
  rectangle_settings >"$rectangle_plist"
  echo "saved $rectangle_plist"
  exit 0
fi

if ! command -v brew >/dev/null 2>&1; then
  echo "Installing Homebrew"
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  eval "$(/opt/homebrew/bin/brew shellenv 2>/dev/null || /usr/local/bin/brew shellenv)"
fi

# kind package command-or-app
packages=(
  "formula herdr herdr"
  "cask claude-code claude"
  "cask codex codex"
  "formula pi-coding-agent pi"
  "formula opencode opencode"
  "cask rectangle /Applications/Rectangle.app"
  "cask hammerspoon /Applications/Hammerspoon.app"
)

for entry in "${packages[@]}"; do
  read -r kind pkg cmd <<<"$entry"

  if brew list "--$kind" "$pkg" >/dev/null 2>&1; then
    echo "ok    $pkg (brew)"
  elif [[ "$cmd" = /* ]] && [ -e "$cmd" ]; then
    echo "ok    $pkg ($cmd)"
  elif [[ "$cmd" != /* ]] && command -v "$cmd" >/dev/null 2>&1; then
    echo "ok    $pkg ($(command -v "$cmd"))"
  else
    echo "add   $pkg"
    brew install "--$kind" "$pkg"
  fi
done

# Rectangle: merge the repo's settings over whatever this Mac has. Rectangle
# writes its prefs back when it quits, so it has to be closed during the import.
current="$(mktemp)" merged="$(mktemp)"
trap 'rm -f "$current" "$merged"' EXIT
defaults export "$rectangle_domain" "$current" 2>/dev/null || plutil -create xml1 "$current"
# Exit 3 means the merge changed nothing. Any other failure stops the script.
unchanged=0
python3 - "$current" "$rectangle_plist" "$merged" <<'PY' || { [ $? -eq 3 ] && unchanged=1; } || exit 1
import plistlib, sys
cur_path, repo_path, out_path = sys.argv[1:]
with open(cur_path, "rb") as f:
    cur = plistlib.load(f)
with open(repo_path, "rb") as f:
    merged = {**cur, **plistlib.load(f)}
with open(out_path, "wb") as f:
    plistlib.dump(merged, f)
sys.exit(0 if merged != cur else 3)
PY
if [ "$unchanged" -eq 0 ]; then
  was_running=0
  if pgrep -xq Rectangle; then
    was_running=1
    osascript -e 'quit app "Rectangle"'
    sleep 1
  fi
  defaults import "$rectangle_domain" "$merged"
  echo "set   Rectangle shortcuts"
  [ "$was_running" -eq 0 ] || open -a Rectangle
else
  echo "ok    Rectangle shortcuts"
fi

# Hammerspoon: ~/.hammerspoon/init.lua only loads the repo's config, and the
# config needs the AppWindowSwitcher spoon, which is not in the repo.
hs_init="$HOME/.hammerspoon/init.lua"
hs_line="dofile(os.getenv(\"HOME\") .. \"/dotfiles/hammerspoon/init.lua\")"
mkdir -p "$HOME/.hammerspoon/Spoons"
if [ "$(cat "$hs_init" 2>/dev/null)" = "$hs_line" ]; then
  echo "ok    Hammerspoon init.lua"
else
  [ ! -e "$hs_init" ] || mv "$hs_init" "$hs_init.bak.$(date +%Y%m%d%H%M%S)"
  echo "$hs_line" >"$hs_init"
  echo "set   Hammerspoon init.lua"
fi

for spoon in AppWindowSwitcher; do
  if [ -d "$HOME/.hammerspoon/Spoons/$spoon.spoon" ]; then
    echo "ok    $spoon.spoon"
  else
    zip="$(mktemp -d)/$spoon.spoon.zip"
    curl -fsSL -o "$zip" "https://github.com/Hammerspoon/Spoons/raw/master/Spoons/$spoon.spoon.zip"
    unzip -q "$zip" -d "$HOME/.hammerspoon/Spoons"
    echo "add   $spoon.spoon"
  fi
done

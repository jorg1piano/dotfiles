#!/usr/bin/env bash
# Install the agent CLIs, window tools, Go and LazyVim with Homebrew, then put the
# Rectangle, Hammerspoon and Neovim config from this repo in place. Safe to run again:
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
  "cask 1password /Applications/1Password.app"
  "cask 1password-cli op"
  "cask slack /Applications/Slack.app"
  "formula just just"
  "formula go go"
  "formula neovim nvim"
  "formula ripgrep rg"
  "formula fd fd"
  "formula fzf fzf"
  "formula lazygit lazygit"
  "formula tree-sitter-cli tree-sitter"
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

# Go: brew's go is the latest stable release, so upgrade it when brew has a
# newer one. The tools go into GOPATH/bin and are skipped once they exist.
if brew list --formula go >/dev/null 2>&1 && [ -n "$(brew outdated --quiet go)" ]; then
  echo "up    go $(go env GOVERSION)"
  brew upgrade go
fi
echo "ok    $(go env GOVERSION)"

gobin="$(go env GOPATH)/bin"
go_tools=(
  "gopls golang.org/x/tools/gopls"
  "dlv github.com/go-delve/delve/cmd/dlv"
  "goimports golang.org/x/tools/cmd/goimports"
  "staticcheck honnef.co/go/tools/cmd/staticcheck"
  "gotestsum gotest.tools/gotestsum"
)
for entry in "${go_tools[@]}"; do
  read -r cmd module <<<"$entry"
  if [ -x "$gobin/$cmd" ]; then
    echo "ok    $cmd"
  else
    echo "add   $cmd"
    go install "$module@latest"
  fi
done
case ":$PATH:" in
  *":$gobin:"*) ;;
  *) echo "      $gobin is not on PATH. Add to ~/.zshrc: export PATH=\"$gobin:\$PATH\"" ;;
esac

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

# LazyVim: start from the upstream starter, point its keymaps and options at the
# repo, then let `just nvim-link` link the plugin specs and patch lazy.lua.
nvim_config="$HOME/.config/nvim"
if [ -d "$nvim_config" ]; then
  echo "ok    LazyVim starter"
  fresh_nvim=0
else
  git clone -q https://github.com/LazyVim/starter "$nvim_config"
  rm -rf "$nvim_config/.git"
  echo "add   LazyVim starter"
  fresh_nvim=1
fi

# Skip a file that already mentions the repo file, however it loads it.
hook() {
  file="$1" target="$2"
  line="dofile(os.getenv(\"HOME\") .. \"/$target\")"
  if grep -qF "$target" "$file" 2>/dev/null; then
    echo "ok    $(basename "$file") loads the repo"
  else
    printf '\n-- Tracked in ~/dotfiles\n%s\n' "$line" >>"$file"
    echo "set   $(basename "$file") loads the repo"
  fi
}
hook "$nvim_config/lua/config/options.lua" dotfiles/nvim/options.lua
hook "$nvim_config/lua/config/keymaps.lua" dotfiles/nvim/keymaps.lua

just -f "$repo/justfile" nvim-link | sed 's/^/      /'

# The first start would otherwise sit downloading plugins in front of you.
# Mason's language tools still finish on that first start, and quitting while
# they download makes nvim exit non-zero, which is not a failed setup.
if [ "$fresh_nvim" -eq 1 ]; then
  echo "add   LazyVim plugins"
  nvim --headless "+Lazy! sync" +qa || echo "      Mason tools finish installing the first time you open nvim"
fi

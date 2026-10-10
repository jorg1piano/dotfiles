#!/usr/bin/env bash
# Install the agent CLIs with Homebrew. Safe to run again: anything already
# installed, by brew or another installer, is skipped.
set -euo pipefail

if ! command -v brew >/dev/null 2>&1; then
  echo "Installing Homebrew"
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  eval "$(/opt/homebrew/bin/brew shellenv 2>/dev/null || /usr/local/bin/brew shellenv)"
fi

# kind package command
packages=(
  "formula herdr herdr"
  "cask claude-code claude"
  "cask codex codex"
  "formula pi-coding-agent pi"
)

for entry in "${packages[@]}"; do
  read -r kind pkg cmd <<<"$entry"

  if brew list "--$kind" "$pkg" >/dev/null 2>&1; then
    echo "ok    $pkg (brew)"
  elif command -v "$cmd" >/dev/null 2>&1; then
    echo "ok    $pkg ($(command -v "$cmd"))"
  else
    echo "add   $pkg"
    brew install "--$kind" "$pkg"
  fi
done

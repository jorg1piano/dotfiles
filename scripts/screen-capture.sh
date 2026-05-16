#!/usr/bin/env bash
# Capture a macOS display to ~/Desktop and copy the path to clipboard.
# Usage: screen-capture.sh <display-number>
set -euo pipefail

display="${1:-1}"
out="$HOME/Desktop/screenshot-display${display}-$(date +%Y%m%d-%H%M%S).png"

screencapture -D "$display" -x "$out"
echo -n "$out" | pbcopy

tmux display-message "Captured display $display → $out (path copied)"

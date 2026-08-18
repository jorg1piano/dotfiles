#!/bin/sh
# Pick one of the commands run in the active pane and copy it together with its
# whole output, up to the next prompt.
#
# Herdr swallows OSC 133 shell integration marks and strips zero-width
# characters from the grid, so there is no invisible marker to split on: blocks
# are found by matching the zsh prompt from ~/.zshrc, which always renders as
#   <cwd> <emoji> (<branch>) $ <command>
# Set HERDR_PROMPT_RE to a different Python regex (group 1 = the command) if
# that prompt ever changes.
#
# Bound from ~/.config/herdr/config.toml as a [[keys.command]] popup, which
# supplies HERDR_ACTIVE_PANE_ID for the pane that was focused.

set -u

pane="${HERDR_ACTIVE_PANE_ID:-}"
lines="${HERDR_YANK_LINES:-5000}"

pause() { printf '\npress enter to close '; read -r _ || true; }
die() {
  echo "$1"
  pause
  exit 1
}

[ -n "$pane" ] || die "no active pane (HERDR_ACTIVE_PANE_ID is unset)"
command -v fzf >/dev/null 2>&1 || die "fzf is required for the command picker"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/herdr-yank.XXXXXX") || die "cannot create a temp dir"
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

# recent-unwrapped keeps long lines logical instead of hard-wrapped at the pane
# width, so yanked output pastes as it was printed rather than as it looked.
herdr pane read "$pane" --source recent-unwrapped --lines "$lines" >"$tmp/buffer" 2>/dev/null ||
  die "could not read pane $pane"

mkdir -p "$tmp/blocks"

BUFFER="$tmp/buffer" BLOCKS="$tmp/blocks" INDEX="$tmp/index" python3 -c '
import os
import re
import sys

prompt_re = re.compile(
    os.environ.get("HERDR_PROMPT_RE")
    # <cwd> <emoji> (<branch>) $ <command> — the branch parens and the trailing
    # "$ " are what make a prompt line distinguishable from ordinary output.
    or r"^.*\S \S+ \([^)]*\) \$ ?(.*)$"
)

with open(os.environ["BUFFER"], encoding="utf-8", errors="replace") as handle:
    lines = handle.read().splitlines()

# (command, first output line, one past last output line)
blocks = []
for number, line in enumerate(lines):
    match = prompt_re.match(line)
    if not match:
        continue
    if blocks:
        blocks[-1][2] = number
    blocks.append([match.group(1).strip(), number + 1, len(lines)])

blocks_dir = os.environ["BLOCKS"]
index = []
# Newest first: the command you just ran is the one you are most likely after.
for position, (command, start, end) in enumerate(reversed(blocks)):
    if not command:
        continue  # a bare prompt — nothing was run there
    body = "\n".join([command] + lines[start:end]).rstrip() + "\n"
    name = "%03d" % position
    with open(os.path.join(blocks_dir, name), "w", encoding="utf-8") as handle:
        handle.write(body)
    index.append("%s\t%s" % (name, command))

with open(os.environ["INDEX"], "w", encoding="utf-8") as handle:
    handle.write("\n".join(index) + ("\n" if index else ""))
' || die "could not parse the pane buffer"

[ -s "$tmp/index" ] || die "no commands found in the last $lines lines of $pane"

choice=$(
  fzf --height=100% --reverse --delimiter='\t' --with-nth=2.. \
    --prompt='yank command > ' \
    --header="$pane — enter copies the command and its output" \
    --preview="cat '$tmp/blocks/'{1}" --preview-window='down,70%' <"$tmp/index" |
    cut -f1
)
[ -n "$choice" ] || exit 0

block="$tmp/blocks/$choice"
[ -f "$block" ] || die "block $choice disappeared"

if command -v pbcopy >/dev/null 2>&1; then
  pbcopy <"$block"
elif command -v wl-copy >/dev/null 2>&1; then
  wl-copy <"$block"
elif command -v xclip >/dev/null 2>&1; then
  xclip -selection clipboard <"$block"
else
  die "no clipboard tool found (pbcopy, wl-copy or xclip)"
fi

command_line=$(head -n 1 "$block")
copied=$(wc -l <"$block" | tr -d ' ')
herdr notification show "Yanked $copied lines" --body "$command_line" --sound none >/dev/null 2>&1 || true

#!/bin/sh
# Prompt for a slug and a coding agent, create a `wet` worktree named after the
# slug, open that worktree as a child space of the current repo, and lay out the
# whole solution in it: the agent in the space's root pane on the left, and a
# column on the right with slot setup/start + IEx on top and `just mobile run`
# below. Long-running commands are sent to the panes and left there, so the
# prefix+u popup returns immediately and another worktree can be dispatched
# while this one is still bootstrapping.
#
# Bound from ~/.config/herdr/config.toml as the prefix+u popup.
# Herdr provides HERDR_ACTIVE_PANE_CWD for the pane the chord was pressed in.

set -u

pause() { printf '\npress enter to close '; read -r _ || true; }
fail() { echo "$@" >&2; pause; exit 1; }

for tool in wet herdr jq; do
  command -v "$tool" >/dev/null 2>&1 || fail "$tool is not on PATH"
done

# Herdr's CLI reports API failures as a JSON {"error":...} document, sometimes
# with a zero exit status, so every call is routed through this.
herdr_json() {
  out=$(herdr "$@" 2>&1) || fail "herdr $*: $out"
  case "$out" in
    *'"error"'*) fail "herdr $*: $out" ;;
  esac
  printf '%s' "$out"
}

repo="${HERDR_ACTIVE_PANE_CWD:-$PWD}"
cd "$repo" 2>/dev/null || fail "cannot cd to $repo"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
  fail "Not inside a Git work tree: $repo"

# Herdr rejects worktree actions sourced from a linked worktree
# ("linked_worktree_source"), so anchor the open on the main checkout — the
# current pane may already sit in a worktree.
main=$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")

printf 'Slug for the new space: '
IFS= read -r slug || exit 0
[ -n "$slug" ] || exit 0

# The agent is typed into the new pane's interactive login shell, so a name that
# is only a shell alias or function resolves there just as it would by hand.
agent=''
while [ -z "$agent" ]; do
  printf 'Agent [1] claude  [2] pi  [3] codex: '
  IFS= read -r answer || exit 0
  case "$answer" in
    1|claude|'') agent=claude ;;
    2|pi) agent=pi ;;
    3|codex) agent=codex ;;
    *) echo "pick 1, 2 or 3 (or claude, pi, codex)" ;;
  esac
done

echo
echo "wet worktree create $slug"
# --no-tmux: Herdr manages the layout, a stray tmux window would fight it.
created=$(wet worktree create "$slug" --no-tmux --json) ||
  fail "wet worktree create $slug failed"

path=$(printf '%s' "$created" | jq -r '.path // empty')
[ -n "$path" ] && [ -d "$path" ] ||
  fail "wet did not return a usable worktree path (got: '$created')"

echo "opening $path"
opened=$(herdr_json worktree open --cwd "$main" --path "$path" --label "$slug" --focus)
pane=$(printf '%s' "$opened" | jq -r '.result.root_pane.pane_id // empty')
[ -n "$pane" ] || fail "herdr worktree open returned no root pane: $opened"

# Three panes: the agent stays in the space's root pane on the left, and the
# right half is a column — the stack and an IEx shell on top, the app below.
split=$(herdr_json pane split "$pane" --direction right --cwd "$path" --no-focus)
top=$(printf '%s' "$split" | jq -r '.result.pane.pane_id // empty')
[ -n "$top" ] || fail "herdr pane split returned no pane: $split"

split=$(herdr_json pane split "$top" --direction down --cwd "$path" --no-focus)
bottom=$(printf '%s' "$split" | jq -r '.result.pane.pane_id // empty')
[ -n "$bottom" ] || fail "herdr pane split returned no pane: $split"

# Fire-and-forget a command into an interactive shell. `herdr pane run` owns the
# pane until the command finishes; using it for setup made prefix+u stay busy for
# minutes and prevented dispatching a second worktree while the first booted.
start_pane() {
  target=$1
  shift
  herdr_json pane send-text "$target" "$*" >/dev/null
  herdr_json pane send-keys "$target" enter >/dev/null
}

# One command line, so each step only runs if the one before it succeeded:
# setup claims a slot/pool item, reset prepares the reusable resources, start
# boots this checkout's stack, and IEx attaches only after healthchecks pass.
start_pane "$top" 'wet setup --headless && wet slot reset --headless && wet slot start --headless && just backend iex'

# The app pane can be queued immediately, but it must not race setup. Wait for
# wet's generated files and for Phoenix to answer on this slot's port before
# handing the terminal to flutter run.
start_pane "$bottom" 'while [ ! -f .env.worktree ] || [ ! -f mobile_elixir/.env ]; do sleep 1; done; . ./.env.worktree; until curl -fsS "http://127.0.0.1:${PHX_PORT}/" >/dev/null; do sleep 2; done; just mobile run'

start_pane "$pane" "nvm use 24 && $agent"

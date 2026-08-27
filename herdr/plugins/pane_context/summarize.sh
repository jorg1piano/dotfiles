#!/bin/sh
# Keep a one-line summary of what an agent pane is working on.
#
#   summarize.sh hook          from the pane.agent_status_changed event
#   summarize.sh now           from the "summarize this pane" action
#   summarize.sh clear         from the "clear" action
#   summarize.sh run <pane>    internal: the detached worker
#
# The summary goes two places: the pane's $summary metadata token, which sidebar
# rows can print, and a full-width strip across the pane's top row. The token
# always works; the strip needs a Kitty-graphics host terminal (see README).
#
# What gets summarized is the user's last instruction, not the screen. The screen
# at the start of a turn is a banner or a half-finished tool call, and a model
# asked to name the task from that answers "I cannot determine a task from this
# terminal output". The instruction is right there in the pane and is what the
# pane is actually working on, so it is the input whenever one can be found.

set -u

SOURCE_ID=jorgen.panecontext
HERDR="${HERDR_BIN_PATH:-herdr}"
ROOT="${HERDR_PLUGIN_ROOT:-$(cd "$(dirname "$0")" && pwd)}"
STATE_DIR="${HERDR_PLUGIN_STATE_DIR:-${TMPDIR:-/tmp}/panecontext}"

MODEL=haiku
LINES=60                 # pane lines handed to the model when there is no prompt
PROMPT_LINES=250         # pane lines searched for the user's last instruction
VERBATIM_MAX=72          # instructions this short are shown as typed, no model call
MIN_INTERVAL=45          # seconds between summaries of one pane
RETRY_AFTER=15           # seconds before retrying a pane whose summary failed
TTL_MS=3600000           # a summary nobody refreshes expires after an hour
OVERLAY=1                # 0 disables the in-pane strip, leaving just the token
ASK_TASK='Condense the instruction below into at most 8 words naming the task. No preamble, no quotes, no trailing punctuation.'
ASK_SCREEN='The text below is the last screen of a terminal running a coding agent. Reply with at most 8 words naming the task it is working on, as a noun phrase. If no task is identifiable, reply with the single word NONE. No preamble, no quotes, no trailing punctuation.'

CONFIG_DIR="${HERDR_PLUGIN_CONFIG_DIR:-}"
[ -n "$CONFIG_DIR" ] && [ -f "$CONFIG_DIR/config.sh" ] && . "$CONFIG_DIR/config.sh"

LOG="$STATE_DIR/panecontext.log"

# The worker runs detached, so anything it prints is lost unless it lands here.
# `herdr plugin log list` only ever sees the hook, which returns in milliseconds.
log() {
  mkdir -p "$STATE_DIR" 2>/dev/null || return 0
  printf '%s %-9s %s\n' "$(date +%H:%M:%S)" "${pane:-?}" "$*" >> "$LOG" 2>/dev/null
  # Keep it to the recent past rather than growing without bound.
  if [ "$(wc -c < "$LOG" 2>/dev/null || echo 0)" -gt 131072 ]; then
    tail -n 200 "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"
  fi
}

# Pull one "key":"value" out of a compact JSON object. Enough for the two event
# fields this needs, and it keeps the hook free of a JSON dependency.
json_str() {
  printf '%s' "${2:-}" | sed -n "s/.*\"$1\":\"\([^\"]*\)\".*/\1/p"
}

find_bin() {
  var=$1; shift
  eval "set -- \${$var:-} \"\$@\""
  for c in "$@"; do
    [ -n "$c" ] || continue
    case $c in
      /*) [ -x "$c" ] && { printf '%s\n' "$c"; return 0; } ;;
      *)  p=$(command -v "$c" 2>/dev/null) && { printf '%s\n' "$p"; return 0; } ;;
    esac
  done
  return 1
}

# The server's PATH is whatever launched Herdr, so neither of these can be
# assumed to resolve the way they do in a login shell.
find_claude() {
  find_bin CLAUDE_BIN claude "$HOME"/.local/bin/claude /opt/homebrew/bin/claude \
    $(ls -t "$HOME"/.nvm/versions/node/*/bin/claude 2>/dev/null)
}

# Only a Python that can import PIL is any use for the strip.
find_python() {
  [ -n "${PYTHON_BIN:-}" ] && { printf '%s\n' "$PYTHON_BIN"; return 0; }
  for c in "$HOME"/.pyenv/shims/python3 python3 /opt/homebrew/bin/python3 /usr/bin/python3; do
    p=$(command -v "$c" 2>/dev/null) || continue
    "$p" -c 'import PIL' >/dev/null 2>&1 && { printf '%s\n' "$p"; return 0; }
  done
  return 1
}

# The last thing the user typed, as rendered by the agent: a marker line plus the
# indented lines it wrapped onto. Later blocks overwrite earlier ones, so what
# comes out is the most recent instruction on screen.
last_prompt() {
  awk '
    /^[[:space:]]*(❯|>)[[:space:]]+[^[:space:]]/ {
      line = $0; sub(/^[[:space:]]*(❯|>)[[:space:]]+/, "", line)
      block = line; collecting = 1; next
    }
    collecting && /^[[:space:]]+[^[:space:]]/ {
      line = $0; sub(/^[[:space:]]+/, "", line)
      block = block " " line; next
    }
    { collecting = 0 }
    END { if (length(block) > 0 && length(block) < 600) print block }
  '
}

ask_model() {
  claude_bin=$(find_claude) || { log "no claude binary on PATH"; return 1; }
  printf '%s\n\n%s\n' "$1" "$2" |
    "$claude_bin" -p --model "$MODEL" --no-session-persistence --output-format text 2>/dev/null |
    tr '\n' ' ' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

state_file() {
  mkdir -p "$STATE_DIR" 2>/dev/null || return 1
  printf '%s/%s.last\n' "$STATE_DIR" "$(printf '%s' "$1" | tr -c 'A-Za-z0-9' '_')"
}

# A pane that has no summary yet should not wait a full interval to try again,
# so a failed attempt rewinds its claim to a short retry instead of holding it.
give_up() {
  [ -n "${stamp:-}" ] && printf '%s\n' "$((now - MIN_INTERVAL + RETRY_AFTER))" > "$stamp"
  exit 1
}

run() {
  pane=$1
  [ -n "$pane" ] || exit 0

  # Rate limit per pane. The stamp is written before the work, so a failed or slow
  # summary backs off the same as a successful one instead of retrying every event.
  now=$(date +%s)
  stamp=$(state_file "$pane") || stamp=
  if [ "${FORCE:-0}" != "1" ] && [ -n "$stamp" ]; then
    last=$(cat "$stamp" 2>/dev/null || echo 0)
    case $last in ''|*[!0-9]*) last=0 ;; esac
    [ $((now - last)) -lt "$MIN_INTERVAL" ] && exit 0
    # Claimed up front so two events cannot summarize the same pane at once.
    printf '%s\n' "$now" > "$stamp"
  fi

  screen=$("$HERDR" pane read "$pane" --source recent-unwrapped --lines "$PROMPT_LINES" 2>/dev/null) || exit 0
  [ -n "$screen" ] || exit 0

  ask=$(printf '%s\n' "$screen" | last_prompt)
  # A slash command or a one-word reply is the user steering, not a task.
  case $ask in
    /*) ask= ;;
    ?|??|???|????|?????|??????|???????|????????|?????????|??????????|???????????) ask= ;;
  esac

  if [ -n "$ask" ]; then
    if [ ${#ask} -le "$VERBATIM_MAX" ]; then
      summary=$ask
    else
      summary=$(ask_model "$ASK_TASK" "$ask") || give_up
    fi
  else
    summary=$(ask_model "$ASK_SCREEN" "$(printf '%s\n' "$screen" | tail -n "$LINES")") || give_up
  fi

  # A refusal, a login notice or a rate-limit message arrives on stdout looking
  # like any other answer. Leaving the previous summary up beats replacing it
  # with an apology.
  case $summary in
    ''|NONE*|*"cannot determine"*|*"I cannot"*|*"unable to"*|*"Please run /login"*|*"usage limit"*)
      log "rejected: ${summary:-<empty>}"
      give_up ;;
  esac

  "$HERDR" pane report-metadata "$pane" --source "$SOURCE_ID" \
    --token summary="$summary" --seq "$(date +%s)" --ttl-ms "$TTL_MS" >/dev/null 2>&1

  log "summary: $summary"

  if [ "$OVERLAY" = "1" ]; then
    if py=$(find_python); then
      err=$("$py" "$ROOT/overlay.py" "$pane" "$summary" 2>&1 | head -3)
      if [ -n "$err" ]; then log "$err"; fi
    else
      log "no python3 with PIL; strip skipped"
    fi
  fi

  # Explicit, so a strip that drew cleanly does not leave the last test's exit
  # status as the worker's.
  return 0
}

case "${1:-hook}" in
  hook)
    [ "${HERDR_PLUGIN_EVENT:-}" = "pane.agent_status_changed" ] || exit 0
    ev="${HERDR_PLUGIN_EVENT_JSON:-}"
    # A pane with no detected agent has nothing to summarize, and blocked/unknown
    # mean the screen is a permission prompt or unclassified rather than work.
    [ -n "$(json_str agent "$ev")" ] || exit 0
    case $(json_str agent_status "$ev") in
      working|idle|done) ;;
      *) exit 0 ;;
    esac
    pane=$(json_str pane_id "$ev")
    [ -n "$pane" ] || pane="${HERDR_PANE_ID:-}"
    [ -n "$pane" ] || exit 0
    # Detached: the model call takes seconds and the event queue should not wait.
    nohup "$ROOT/summarize.sh" run "$pane" >/dev/null 2>&1 &
    exit 0
    ;;
  now)
    pane="${HERDR_PANE_ID:-$(json_str focused_pane_id "${HERDR_PLUGIN_CONTEXT_JSON:-}")}"
    [ -n "$pane" ] || exit 0
    FORCE=1 nohup "$ROOT/summarize.sh" run "$pane" >/dev/null 2>&1 &
    exit 0
    ;;
  clear)
    pane="${HERDR_PANE_ID:-$(json_str focused_pane_id "${HERDR_PLUGIN_CONTEXT_JSON:-}")}"
    [ -n "$pane" ] || exit 0
    "$HERDR" pane report-metadata "$pane" --source "$SOURCE_ID" --clear-token summary >/dev/null 2>&1
    if py=$(find_python); then "$py" "$ROOT/overlay.py" "$pane" --clear >/dev/null 2>&1; fi
    ;;
  run)
    run "${2:-}"
    ;;
esac

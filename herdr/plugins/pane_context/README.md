# pane_context

Keeps a one-line answer to "what is this pane working on?" and draws it as a
full-width strip across the top of the pane.

On every agent status change Herdr reports, the plugin looks for the last
instruction you typed into that pane and writes it back two ways:

- `herdr pane report-metadata --token summary=...`, which sidebar rows can print
  as `$summary`
- a `pane.graphics.set` image spanning the pane's top row

The token is the durable copy and always works. The strip is the display.

## What it summarizes

The instruction, not the screen. An agent's screen at the start of a turn is a
banner or a half-finished tool call, and a model asked to name the task from that
answers "I cannot determine a task from this terminal output". The instruction is
already in the pane, so the plugin pulls it out of the transcript: a marker line
(`❯` or `>`) plus the lines it wrapped onto, taking the most recent one.

From there:

- 72 characters or shorter: shown as typed. No model call, no cost, about half a
  second end to end.
- Longer: Haiku condenses it to eight words. "Update the just stack down command
  so that we can pass --close to close the herdr window once the Command
  completes without an error code" becomes "Add --close flag to just stack down
  command", in about 6 seconds.
- No instruction found (a fresh pane, a scrolled-away prompt): Haiku falls back
  to naming the task from the last 60 lines of screen, and is told to answer
  `NONE` when it can't. `NONE`, refusals, login notices and rate-limit messages
  are all discarded, leaving the previous summary up rather than replacing it
  with an apology.

Slash commands and one-word replies are skipped too. `/short` is you steering,
not the task.

## Install

```sh
herdr plugin link ~/github/herdr_plugins/pane_context
```

The strip additionally needs, once:

```toml
# ~/.config/herdr/config.toml
[experimental]
kitty_graphics = true
```

then `herdr server reload-config` **and a client re-attach** (detach, run `herdr`
again). The client asks the outer terminal for its pixel cell size when it
starts, so a client that attached before the flag was set reports
`cell_size_unavailable` and the strip is skipped. The outer terminal has to speak
the Kitty graphics protocol; Ghostty, Kitty and WezTerm do, Terminal.app does not.

Without the strip the summary is still there. Print it in the sidebar with:

```toml
[ui.sidebar.agents.rows_by_agent]
claude = [["state_icon", "workspace", "tab"], [{ token = "$summary", dim = true }], ["agent"]]
```

## How often it runs

The hook fires on every status edge, then drops the event unless the pane has a
detected agent, the new status is `working`, `idle` or `done`, and that pane has
not been summarized in `MIN_INTERVAL` seconds. Everything filtered out exits in
milliseconds. A short turn produces one summary; a long one produces two, at the
edges. An idle pane produces none.

Most summaries cost nothing, because most instructions are short enough to show
verbatim. The ones that reach Haiku send about 40 tokens now that the input is
one instruction rather than a screenful.

## Configuration

Drop a `config.sh` in `$(herdr plugin config-dir jorgen.panecontext)` to override
any of the shell variables at the top of `summarize.sh`:

```sh
MODEL=haiku          # any model name claude -p accepts
VERBATIM_MAX=72      # instructions this short skip the model entirely
PROMPT_LINES=250     # pane lines searched for the instruction
LINES=60             # pane lines sent to the model when no instruction is found
MIN_INTERVAL=45      # seconds between summaries of one pane
TTL_MS=3600000       # a summary nobody refreshes expires after an hour
OVERLAY=0            # token only, no strip
CLAUDE_BIN=          # when claude is not on the server's PATH
PYTHON_BIN=          # a python3 that can import PIL, for the strip
```

`claude -p` runs under the login the CLI already has; no API key is involved.

## Actions

- `jorgen.panecontext.now` — summarize the focused pane immediately, ignoring the
  rate limit
- `jorgen.panecontext.clear` — drop the token and the strip for that pane

Bind either from `config.toml`:

```toml
[[keys.command]]
key = "prefix+alt+s"
type = "plugin_action"
command = "jorgen.panecontext.now"
```

## Limits

- The instruction extractor keys on how the agent renders your input. `❯` and `>`
  cover Claude Code; another agent with a different marker falls through to the
  screen path, which still works, just slower and vaguer.
- Claude Code is not a Herdr lifecycle authority: its status comes from screen
  detection, so an unrecognized screen shows `unknown` and fires no summary.
- One graphics placement exists per pane. A pane that draws its own images
  through Herdr will fight the strip for it.
- `blocked` and `unknown` are skipped on purpose. A permission prompt is not new
  work, and summarizing it would replace the real task with the question.

# Claude attention notifier — design sketch

Status: **design only, nothing implemented.**

## Problem

A single chime when Claude stops is easy to miss. What's wanted is a nagging
reminder that keeps going while a pane needs attention, and stops the moment
that pane is actually looked at.

## Core idea

One small program owns all the state. Two kinds of event feed it:

- **raise** — Claude hooks say "this pane needs attention"
- **clear** — either Claude says "handled" or tmux says "the user just visited
  this pane"

The pane is the unit of state, because it's the one identifier both sides can
see. Claude hooks inherit `$TMUX_PANE` from the `claude` process; tmux hooks
have `#{pane_id}`. Same value (`%25`), no correlation table needed. This is
also how `soap` already keys its per-pane `claude` / `claude-processing` keys.

```
Claude Notification hook ──raise %25──┐
                                      ├──> notify-attention ──> state dir ──> daemon ──> afplay
tmux pane-focus-in ──────clear %25────┤                                         (escalating)
Claude UserPromptSubmit ─clear %25────┤
Claude SessionEnd ───────clear %25────┘
```

## Interface

`scripts/notify-attention.sh <command>`:

| Command | Called from | Does |
| --- | --- | --- |
| `raise [pane]` | Claude `Notification` hook | Mark pane as needing attention, start daemon if idle |
| `clear [pane]` | tmux focus hooks, Claude `UserPromptSubmit` / `SessionEnd` | Un-mark pane; daemon exits when none left |
| `tick` | daemon loop only | Decide whether to chime, and with which sound |
| `status` | debugging | List raised panes and their age |

Pane defaults to `$TMUX_PANE`, falling back to the tmux-reported active pane.

## State

One file per raised pane under `~/.local/state/claude-attention/panes/`, named
after the pane with `%` stripped (`%25` → `25`), mtime = raise time. That makes
the whole thing inspectable with `ls -l` and crash-safe — a stale file just
means one extra chime after a reboot, and the daemon prunes panes that no
longer appear in `tmux list-panes`.

Escalation stage is derived from the file's age at tick time rather than
stored, so there's no counter to keep in sync.

## Daemon

Single long-lived process, not one per pane. Spawned lazily by `raise` when the
pidfile is absent or dead, wakes every ~15s, calls `tick`, exits once no panes
are raised. One process, one place where the schedule lives, and it matches
`soap tick`'s model.

Must be **fully detached** from the hook that spawns it — backgrounded,
disowned, stdio to `/dev/null`. Claude Code waits on hook processes (60s
timeout), so a daemon still holding the hook's stdout will stall the turn
instead of notifying about it. This is the main trap in the whole design.

## Schedule

Derived from pane age:

| Age | Behaviour |
| --- | --- |
| 0–3 min | silent grace period |
| 3–8 min | chime every 60s |
| 8–30 min | chime every 5 min |
| 30 min+ | give up, clear the pane |

Escalate the sound with the stage (`Tink` → `Glass` → `Submarine`), and/or
raise `afplay -v`. If several panes are raised, chime **once** per tick at the
most-escalated stage — one queue, not a chorus.

## Suppression

Skip the chime for a pane that's already being looked at: `pane_active` and
`session_attached` both true for that pane, per `tmux display -p -t <pane>`.
Cheap, and it stops the notifier nagging about the pane in front of you.

If *no* client is attached anywhere, still chime — that's exactly the away case
the whole feature exists for.

## tmux wiring

`pane-focus-in` is the main clear signal; it fires on `select-pane`, and on
window and session switches. `client-session-changed` and
`session-window-changed` are candidates for belt-and-braces, probably
redundant.

⚠️ **`tmux.conf:112` already sets `pane-focus-in`** (`refresh-client -S`). A
second `set-hook -g pane-focus-in` silently *replaces* it and breaks pane
border refresh. Use append:

```tmux
set-hook -ga pane-focus-in "run-shell -b '~/dotfiles/scripts/notify-attention.sh clear #{pane_id}'"
```

`-b` so tmux doesn't block on it.

**Perf matters here.** This runs on every single pane switch, so the clear path
should be a `test -e` and an `rm` with no subshells, and bail out before doing
anything else when the pane isn't raised. If a bash spawn per pane switch turns
out to be perceptible, the clear path is the piece to rewrite in Go.

## Claude wiring (global — deliberately not part of this repo's changes)

- `Notification` → `raise` (permission prompts, `AskUserQuestion`, idle input wait)
- `UserPromptSubmit` → `clear`
- `SessionEnd` → `clear`
- `Stop` → probably *not* `raise`. It fires at the end of every turn, including
  ones where you walked away from finished work on purpose. `Notification` is
  the high-signal event.

## `soap` already implements most of this

Inspecting the binary (`soap install-hooks`, plus symbols) shows the state
machine described above **already exists**:

- `soap install-hooks` writes hooks that `add-key claude-attention` on `Stop`,
  `PermissionRequest`, and `PreToolUse`/`AskUserQuestion`, and
  `remove-key claude-attention` on `UserPromptSubmit`, `PostToolUse`, and
  `PostToolUseFailure`. That is exactly the raise/clear split.
- Symbols `Window.NeedsAttention`, `updateAttentionList`, `attentionLen`,
  `inAttentionSection` and the string `Needs your attention (%d)` mean the TUI
  already surfaces a list of panes wanting attention.
- `soap tick` re-evaluates all pane state, and the binary already reads
  `#{pane_id}` and `#{session_id}` from tmux.
- There is **no** `afplay` or `.aiff` string anywhere in the binary.

So the missing piece isn't the state machine or the event plumbing — it's only
the escalating *sound*, driven off the `claude-attention` key that soap already
maintains. Building a standalone daemon would duplicate the tracking and give
two sources of truth for the same panes.

This mostly settles the standalone-vs-soap question in favour of soap. The
remaining unknown is whether `soap tick` is already on a timer or only fires
from tmux hooks — an escalating chime needs a periodic tick, not just
event-driven ones.

## Available hook facts

- **`session_id` is in every hook payload**, `UserPromptSubmit` included —
  hooks get JSON on stdin with `session_id`, `transcript_path`, `cwd`, and
  `hook_event_name`. soap prints it (`session=e35a0053-…`), which is where the
  non-tmux fallback key would come from.
- **There is no keypress/keystroke hook event.** The events are `PreToolUse`,
  `PostToolUse`, `PostToolUseFailure`, `UserPromptSubmit`, `Notification`,
  `Stop`, `SubagentStop`, `PreCompact`, `SessionStart`, `SessionEnd`,
  `PermissionRequest`. Nothing fires per keystroke.

  Consequence for this design: "user is at the pane typing a reply but hasn't
  submitted yet" is **invisible** from the Claude side. If that case should
  suppress the chime, the signal has to come from tmux `client_activity` or
  macOS HID idle. This is the reason the tmux half of the design exists at all.

## Identity: session, not pane

Keying state on the pane breaks as soon as you answer a session from somewhere
other than the pane it started in. **Key on `session_id`; store the pane as a
mutable attribute**, refreshed on every hook.

The case that proves it: start a session in pane A, then `claude --resume <id>`
in pane B. The hooks now fire with pane B's `$TMUX_PANE` but the *same*
`session_id`. Pane-keyed state raised against A is never cleared by anything
happening in B — a stuck alert nagging about a pane whose session has moved on.

### Verified in soap's source and live state

Source at `~/github/soap` (HEAD `fa8e15c`, plus staged edits to `ticket.go`,
`tui.go`, `hooks-template.json`; installed binary is newer than HEAD).

Key markers are empty files at `/tmp/soap/keys/{paneID}.{keyName}.{sessionID}`
(`cli.go:419`). `readSessionID()` (`cli.go:401`) does read `session_id` from the
hook's stdin JSON — so state *is* session-scoped. But **removal matches on all
three components**, using the pane the hook happened to run in
(`handleRemoveKey`, `cli.go:374-387`). Session-scoping in the filename doesn't
save it: a raise on pane A and a clear on pane B target different files.

**This is happening right now**, not hypothetically:

```
%27.claude-attention.e35a0053-9ac3-4297-a498-698a90c5fb9b
```

`e35a0053…` is this very Claude session, whose hooks fire on pane **%25**. Both
panes are alive in window `0:8`. Nothing that session ever does will remove that
file — every `UserPromptSubmit` clears `%25.…`, never `%27.…`. With a sound
attached, that's a chime that never stops.

`teammateMode: "tmux"` makes this the *normal* case, not an edge case: agent
panes share the parent's `session_id` but have their own pane ids.

### Stale keys are a prerequisite, not a polish item

`cleanupStaleKeys` (`tui.go:1078`) only removes files whose **pane** is dead, or
legacy names lacking a session component. Nothing removes a file whose *session*
has ended while its pane lives on. Live state: **104 key files across 66
distinct session ids**, going back to Jul 23, on a handful of long-lived panes.

Pane `%8` is alive and carries half a dozen `claude-processing` files from dead
sessions, so `IsProcessing()` for its window is permanently true. Today that's
just a wrong badge. Add sound to `NeedsAttention()` and the same mechanism
becomes a chime with no off switch. **Fix cleanup before adding sound.**

### The fix needs both directions

`removeKeyFilesForPane(paneID, keyName)` (`tui.go:852`) already clears every
session for a pane. What's missing is its mirror:

- **clear by session, any pane** — glob `*.{keyName}.{sessionID}`, called from
  `UserPromptSubmit`. Covers answering from a dashboard, a resume in another
  pane, or an agent pane.
- **clear by pane, any session** — `removeKeyFilesForPane`, already written,
  called on pane visit.
- **expire by session liveness** — in `cleanupStaleKeys`, drop keys whose
  session has no live process (or fall back to file age).

## Clearing when you answer from a different pane

Three layered signals, most to least authoritative:

1. **`UserPromptSubmit` → clear by `session_id`.** Pane-independent, so it works
   however the input arrived: typed in pane A, `send-keys` from a dashboard, or
   a resume in pane B. This is the signal that must be correct; everything else
   is an optimisation.
2. **Pane visit → clear by pane→session lookup.** Optimistic early clear for
   when you simply walk over to the pane. Requires `focus-events on` (see
   below).
3. **Dashboard focused → mute the sound, keep the list.** If a pane displays
   the attention list, focusing it means you've been *informed*, not that you've
   *acted*. Stop the noise; leave the entries pending until actually answered.
   This separates alerting (sound, draws you in) from pending work (the list) —
   and it's the answer to "how do I silence it while I'm sitting in the
   dashboard".

`send-keys` to a pane fires **no** tmux hook at all (tested), so case 2 never
covers the drive-it-from-the-dashboard flow. Only signal 1 does.

## Tested: tmux focus hook behaviour

Measured on tmux 3.6a in an isolated server (`tmux -L`):

| Action | `focus-events off` | `focus-events on` |
| --- | --- | --- |
| `select-pane` (same window) | *nothing* | `pane-focus-in` |
| `select-window` | `session-window-changed` only | `session-window-changed` + `pane-focus-in` |
| `switch-client` (session) | `pane-focus-in` + `client-session-changed` | both |
| `send-keys` (no visit) | *nothing* | *nothing* |
| no client attached | no `pane-focus-in` at all | — |

⚠️ **`focus-events` is `off` on the live server** and is not set anywhere in
`tmux.conf`. Two consequences:

- The design needs `set -g focus-events on`, or signal 2 misses the most common
  navigation of all — moving between panes in the same window.
- **`tmux.conf:112` is effectively dead code.** `set-hook -g pane-focus-in
  "refresh-client -S"` (commented "Force pane border refresh on directory
  change") almost never fires with `focus-events off`, and `pane-focus-in`
  doesn't even appear in the live server's `show-hooks -g` output. Turning
  `focus-events on` would bring it to life — which may be a fix, or may be an
  unexpected behaviour change to watch for.

soap's own tmux hooks (`after-new-window`, `after-split-window`,
`after-kill-pane`) are pane *lifecycle* only — it installs nothing for focus or
visits, so signal 2 doesn't exist today in any form.

## Open questions

1. **Is `soap tick` already periodic?** Determines whether the chime scheduler
   can live entirely inside soap or still needs a timer alongside it. Can't tell
   from the binary; needs the source.
2. **Does focus really mean "handled"?** Glancing at a pane clears the alert
   even if you don't act. Probably correct — you've seen it — but the
   alternative is clearing only on `UserPromptSubmit`.
3. **Off-machine escalation.** Past ~5 minutes a louder Mac doesn't help. HID
   idle (`ioreg -c IOHIDSystem`) distinguishes "at the keyboard, working
   elsewhere" from "away from the desk"; the latter wants a push notification,
   not a speaker.
4. **Non-tmux sessions.** No `$TMUX_PANE` means no pane key and no clear
   signal. Fall back to a single chime, or key on `session_id` per above.

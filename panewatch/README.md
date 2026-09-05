# panewatch

Polls every pane in every running herdr session and prints the coding agents
that just went quiet. One run, one poll, then it exits. State lives in a file,
so cron can drive it with no agent in the loop.

```
panewatch -quiet -notify
```

It is the Go rewrite of a throwaway `poll.py`. The rewrite fixes eight bugs;
they are listed at the bottom because most of them are worth knowing about.

## How it decides a pane went quiet

Per pane, per run:

1. Hash the last 20 lines of the pane (`herdr pane read`).
2. Hash differs from last run: the agent produced output, so a work cycle is
   running. Re-arm the alert.
3. Hash is identical, the pane has changed at least once since panewatch
   started watching it, and herdr reports the agent as `idle` or `done`: report
   it, once.

The "changed at least once" rule stops the first run from reporting every agent
that happened to be sitting idle. The first run prints `BASELINE: tracking N
panes` and nothing else.

Two polls are needed to see a finish: one to record the last output, one to
find it unchanged. At a one minute interval you hear about an agent between one
and two minutes after it stops.

## Coverage

`herdr pane list` returns every pane of every workspace and tab in a session,
and panewatch runs it once per running session from `herdr session list
--json`, targeting each session's socket through `HERDR_SOCKET_PATH`. Nothing
is scoped to the focused workspace. On my machine that is 78 panes across 30
workspaces and 37 tabs.

Panes with no agent are listed but not read. Their `agent_status` is `unknown`
forever, so they can never go quiet, and reading them is 61 wasted subprocesses
per poll. `-all-panes` reads them too and reports them on output stability
alone.

Pane reads run concurrently, so a full poll of 17 agent panes takes about half
a second.

## Flags

| Flag | Default | Meaning |
| --- | --- | --- |
| `-state` | `~/.local/state/panewatch/state.json` | where the hashes live |
| `-lines` | `20` | lines of tail to hash and print |
| `-all-panes` | off | watch shells and editors too |
| `-skip` | `$PANEWATCH_SKIP` | comma-separated pane ids to ignore |
| `-exec` | | shell command per event, tail on stdin |
| `-say` | off | speak each event with `saythis` |
| `-notify` | off | raise a herdr notification per event |
| `-json` | off | emit events as JSON |
| `-quiet` | off | print nothing when nothing went quiet |
| `-v` | off | log the scan to stderr |
| `-reset` | off | drop the state file and re-baseline |
| `-herdr` | | path to the herdr binary |
| `-timeout` | `15s` | budget for one herdr call |
| `-workers` | CPU count, max 8 | concurrent pane reads |

The pane panewatch was launched from is skipped automatically through
`HERDR_PANE_ID`, so it never watches itself.

Exit status is 0 for a clean poll whether or not anything went quiet, and 1
only when the poll itself failed. No running herdr server is not a failure.

## The `-exec` hook

The command runs under `$SHELL -c` with the pane tail on stdin and the event in
the environment: `PANEWATCH_SESSION`, `PANEWATCH_PANE_ID`,
`PANEWATCH_WORKSPACE_ID`, `PANEWATCH_TAB_ID`, `PANEWATCH_AGENT`,
`PANEWATCH_STATUS`, `PANEWATCH_CWD`, `PANEWATCH_REPO`, `PANEWATCH_TITLE`,
`PANEWATCH_SUMMARY`.

```
panewatch -quiet -exec 'echo "$(date -Iseconds) $PANEWATCH_SUMMARY" >> ~/agents.log'
```

## Install and schedule

From the repo root:

```
just panewatch-install     # build and drop it in ~/.local/bin
just panewatch-cron        # poll every minute from crontab
just panewatch-launchd     # or poll every minute from launchd
```

Prefer launchd on macOS. `/usr/sbin/cron` needs Full Disk Access before it can
read anything under your home directory, and its environment is thin enough
that you have to spell out every path. The launchd agent runs in your GUI login
session, which is also what `-say` needs to reach the speakers.

`just panewatch-uncron` and `just panewatch-unlaunchd` undo them.

## What was wrong with poll.py

1. **Missed every short work cycle.** The alert only re-armed if a poll caught
   the pane mid-change *and* reading `agent_status == "working"` at that
   instant. An agent that started and finished between two polls stayed latched
   as already-reported and never announced itself again. Now any change to the
   tail re-arms it.
2. **`done` was not a quiet state.** Only `idle` was checked. herdr also
   reports `done`, and a pane parked there was never reported. Live counts on
   my machine: 9 `idle`, 8 `working`, 1 `done`.
3. **Errors were hashed as content.** `run()` ignored the exit status, and
   `herdr pane read` prints `{"error":{"code":"pane_not_found",...}}` on stdout
   when it fails. That JSON is byte-identical every poll, so a broken pane read
   looked like output that had settled perfectly. Failed reads now leave the
   pane's state alone.
4. **A dead herdr server crashed it.** `json.loads("")` on the pane list, with
   a traceback and no message. Now: no running session is a silent exit 0.
5. **State grew forever.** Closed panes were never dropped. The state file I
   inherited had 68 entries, 39 of them hashing the empty string, for panes
   that no longer existed. Entries not seen in a poll are now pruned.
6. **The state write was not atomic.** `json.dump(open(path,"w"))` truncates
   first, so a kill mid-write leaves JSON that never parses again and silently
   disables the watcher forever. Now: write a temp file, fsync, rename. A
   corrupt file re-baselines instead of crashing.
7. **State lived next to the script in a scratchpad temp directory**, which is
   wiped between sessions. It is under `~/.local/state` now.
8. **`WATCH_SELF_PANE` defaulted to the hardcoded `w96:p1`**, which is one
   session's pane id and meaningless anywhere else. It reads `HERDR_PANE_ID`
   now, which herdr sets itself, and is empty under cron where there is no self
   pane.

Two more that only bite under cron: overlapping runs would both read the old
state and the loser's alerts would be re-armed by the winner's write, so runs
now take an exclusive `flock` and skip if one is already going; and `herdr` was
looked up on `$PATH`, which under cron is roughly `/usr/bin:/bin`, so it is now
resolved against `~/.local/bin` and the Homebrew prefixes as well.

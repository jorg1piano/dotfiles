// panewatch polls every pane in every herdr session and reports the coding
// agents that just went quiet. It keeps its state on disk and exits, so a cron
// job can run it with no agent in the loop.
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"time"
)

type options struct {
	statePath string
	lines     int
	allPanes  bool
	skip      string
	exec      string
	say       bool
	notify    bool
	herdr     string
	timeout   time.Duration
	workers   int
	jsonOut   bool
	quiet     bool
	verbose   bool
	reset     bool
}

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, "panewatch:", err)
		os.Exit(1)
	}
}

func run() error {
	var o options
	flag.StringVar(&o.statePath, "state", filepath.Join(DefaultStateDir(), "state.json"), "path to the state file")
	flag.IntVar(&o.lines, "lines", 20, "lines of pane tail to hash and print")
	flag.BoolVar(&o.allPanes, "all-panes", false, "also watch panes with no agent, using output stability alone")
	flag.StringVar(&o.skip, "skip", os.Getenv("PANEWATCH_SKIP"), "comma-separated pane ids to ignore")
	flag.StringVar(&o.exec, "exec", "", "shell command to run per event, with the tail on stdin")
	flag.BoolVar(&o.say, "say", false, "speak each event with saythis")
	flag.BoolVar(&o.notify, "notify", false, "raise a herdr notification per event")
	flag.StringVar(&o.herdr, "herdr", "", "path to the herdr binary")
	flag.DurationVar(&o.timeout, "timeout", 15*time.Second, "timeout for one herdr call")
	flag.IntVar(&o.workers, "workers", 0, "concurrent pane reads (default: CPU count, max 8)")
	flag.BoolVar(&o.jsonOut, "json", false, "emit events as JSON")
	flag.BoolVar(&o.quiet, "quiet", false, "print nothing when nothing went quiet")
	flag.BoolVar(&o.verbose, "v", false, "log what was scanned to stderr")
	flag.BoolVar(&o.reset, "reset", false, "discard the state file and re-baseline")
	flag.Usage = usage
	flag.Parse()

	// The pane panewatch was launched from would otherwise watch itself.
	skip := map[string]bool{}
	for _, s := range strings.Split(o.skip, ",") {
		if s = strings.TrimSpace(s); s != "" {
			skip[s] = true
		}
	}
	if self := os.Getenv("HERDR_PANE_ID"); self != "" {
		skip[self] = true
	}

	if o.workers <= 0 {
		o.workers = min(runtime.NumCPU(), 8)
	}

	bin, err := findHerdr(o.herdr)
	if err != nil {
		return err
	}

	if o.reset {
		if err := os.Remove(o.statePath); err != nil && !os.IsNotExist(err) {
			return err
		}
	}

	release, got, err := Lock(filepath.Join(filepath.Dir(o.statePath), "lock"))
	if err != nil {
		return err
	}
	if !got {
		// A previous run is still going. Skipping is right: the poll interval
		// is shorter than this run, and doubling up corrupts the alert state.
		if o.verbose {
			fmt.Fprintln(os.Stderr, "panewatch: another run holds the lock, skipping")
		}
		return nil
	}
	defer release()

	sessions, err := Sessions(bin, o.timeout)
	if err != nil {
		return err
	}

	state, hadState := LoadState(o.statePath)
	var events []Event
	var scanErrs []error
	seen := map[string]bool{}
	scanned := 0

	for _, sess := range sessions {
		if !sess.Running || sess.SocketPath == "" {
			continue
		}
		scanned++
		sc := &scanner{
			client:   &Client{Bin: bin, Socket: sess.SocketPath, Timeout: o.timeout},
			state:    state,
			lines:    o.lines,
			allPanes: o.allPanes,
			skip:     skip,
			workers:  o.workers,
		}
		evs, sessionSeen, errs := sc.scan(sess.Name)
		events = append(events, evs...)
		scanErrs = append(scanErrs, errs...)
		for k := range sessionSeen {
			seen[k] = true
		}
	}

	if scanned == 0 {
		// No herdr server running is the normal state of a sleeping machine,
		// not an error worth mailing from cron every minute.
		if o.verbose {
			fmt.Fprintln(os.Stderr, "panewatch: no running herdr sessions")
		}
		return nil
	}

	dropped := prune(state, seen)

	if err := SaveState(o.statePath, state); err != nil {
		return fmt.Errorf("saving state: %w", err)
	}

	for _, e := range scanErrs {
		fmt.Fprintln(os.Stderr, "panewatch:", e)
	}
	if o.verbose {
		fmt.Fprintf(os.Stderr, "panewatch: %d session(s), %d pane(s) tracked, %d dropped, %d event(s)\n",
			scanned, len(state.Panes), dropped, len(events))
	}

	// The first run has nothing to compare against; every pane would look
	// like it had just gone quiet.
	if !hadState {
		if !o.quiet {
			fmt.Printf("BASELINE: tracking %d panes\n", len(state.Panes))
		}
		return nil
	}

	if len(events) == 0 {
		if !o.quiet {
			fmt.Println("NO_CHANGE")
		}
		return nil
	}

	report(os.Stdout, events, o)
	dispatch(events, bin, o)
	return nil
}

func report(w io.Writer, events []Event, o options) {
	if o.jsonOut {
		type jsonEvent struct {
			Session   string `json:"session"`
			PaneID    string `json:"pane_id"`
			Workspace string `json:"workspace_id"`
			Tab       string `json:"tab_id"`
			Agent     string `json:"agent"`
			Status    string `json:"agent_status"`
			Cwd       string `json:"cwd"`
			Title     string `json:"title"`
			Summary   string `json:"summary"`
			Tail      string `json:"tail"`
		}
		out := make([]jsonEvent, 0, len(events))
		for _, e := range events {
			out = append(out, jsonEvent{
				Session: e.Pane.Session, PaneID: e.Pane.PaneID,
				Workspace: e.Pane.WorkspaceID, Tab: e.Pane.TabID,
				Agent: e.Pane.Agent, Status: e.Pane.AgentStatus,
				Cwd: e.Pane.Cwd, Title: e.Pane.Title,
				Summary: e.Pane.Tokens.Summary,
				Tail:    strings.TrimRight(e.Tail, "\n"),
			})
		}
		enc := json.NewEncoder(w)
		enc.SetIndent("", "  ")
		enc.Encode(out)
		return
	}

	for _, e := range events {
		p := e.Pane
		agent := p.Agent
		if agent == "" {
			agent = "shell"
		}
		fmt.Fprintf(w, "=== WENT QUIET: %s:%s | agent=%s status=%s | %s\n",
			p.Session, p.PaneID, agent, p.AgentStatus, p.Cwd)
		if d := detail(p); d != "" {
			fmt.Fprintf(w, "    title: %s\n", d)
		}
		fmt.Fprintln(w, strings.TrimRight(e.Tail, "\n"))
		fmt.Fprintln(w)
	}
}

// dispatch fires the side effects. Every one of them is best effort: a broken
// notifier must not cost us the report we already printed.
func dispatch(events []Event, bin string, o options) {
	for _, e := range events {
		if o.notify {
			c := &Client{Bin: bin, Socket: sessionSocketFor(bin, e.Pane.Session, o.timeout), Timeout: o.timeout}
			if c.Socket != "" {
				if err := c.Notify(summary(e.Pane), detail(e.Pane)); err != nil {
					fmt.Fprintln(os.Stderr, "panewatch: notify:", err)
				}
			}
		}
		if o.say {
			if err := speak(summary(e.Pane), o.timeout); err != nil {
				fmt.Fprintln(os.Stderr, "panewatch: say:", err)
			}
		}
		if o.exec != "" {
			if err := runHook(o.exec, e, o.timeout); err != nil {
				fmt.Fprintln(os.Stderr, "panewatch: exec:", err)
			}
		}
	}
}

// sessionSocketCache avoids re-listing sessions per event.
var sessionSocketCache map[string]string

func sessionSocketFor(bin, name string, timeout time.Duration) string {
	if sessionSocketCache == nil {
		sessionSocketCache = map[string]string{}
		if sessions, err := Sessions(bin, timeout); err == nil {
			for _, s := range sessions {
				sessionSocketCache[s.Name] = s.SocketPath
			}
		}
	}
	return sessionSocketCache[name]
}

// speak shells out to saythis, the sibling tool this repo installs.
func speak(text string, timeout time.Duration) error {
	bin, err := lookPathWithFallback("saythis")
	if err != nil {
		return err
	}
	// Speaking is slower than an API call, so it gets its own budget.
	ctx, cancel := context.WithTimeout(context.Background(), timeout*4)
	defer cancel()
	cmd := exec.CommandContext(ctx, bin, text)
	cmd.Stdin = nil
	cmd.Stdout = io.Discard
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

func runHook(command string, e Event, timeout time.Duration) error {
	shell := os.Getenv("SHELL")
	if shell == "" {
		shell = "/bin/sh"
	}
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, shell, "-c", command)
	cmd.Stdin = strings.NewReader(e.Tail)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	cmd.Env = append(os.Environ(),
		"PANEWATCH_SESSION="+e.Pane.Session,
		"PANEWATCH_PANE_ID="+e.Pane.PaneID,
		"PANEWATCH_WORKSPACE_ID="+e.Pane.WorkspaceID,
		"PANEWATCH_TAB_ID="+e.Pane.TabID,
		"PANEWATCH_AGENT="+e.Pane.Agent,
		"PANEWATCH_STATUS="+e.Pane.AgentStatus,
		"PANEWATCH_CWD="+e.Pane.Cwd,
		"PANEWATCH_REPO="+e.Pane.Repo(),
		"PANEWATCH_TITLE="+detail(e.Pane),
		"PANEWATCH_SUMMARY="+summary(e.Pane),
	)
	return cmd.Run()
}

// lookPathWithFallback covers cron's minimal PATH the same way findHerdr does.
func lookPathWithFallback(name string) (string, error) {
	if p, err := exec.LookPath(name); err == nil {
		return p, nil
	}
	home, _ := os.UserHomeDir()
	for _, dir := range []string{
		filepath.Join(home, ".local", "bin"),
		"/opt/homebrew/bin",
		"/usr/local/bin",
	} {
		c := filepath.Join(dir, name)
		if fi, err := os.Stat(c); err == nil && !fi.IsDir() {
			return c, nil
		}
	}
	return "", fmt.Errorf("%s not found on PATH", name)
}

func usage() {
	fmt.Fprint(os.Stderr, `panewatch — report herdr coding agents that just went quiet.

Every run polls every pane of every running herdr session, compares each pane's
tail against the last run, and prints the agent panes whose output has settled
while the agent reports idle or done. State lives in a file, so it is meant to
be run repeatedly from cron rather than left running.

Usage:
  panewatch [flags]

Exit status is 0 for a clean poll whether or not anything went quiet, and 1
only when the poll itself failed.

Flags:
`)
	flag.PrintDefaults()
	fmt.Fprint(os.Stderr, `
Examples:
  panewatch -quiet -notify              # cron: stay silent, notify on events
  panewatch -quiet -say                 # cron: speak each finished agent
  panewatch -exec 'echo "$PANEWATCH_SUMMARY" >> ~/agents.log'
  panewatch -json | jq '.[].cwd'
`)
}

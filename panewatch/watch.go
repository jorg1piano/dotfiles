package main

import (
	"crypto/sha256"
	"encoding/hex"
	"sort"
	"strings"
	"sync"
)

// quietStatuses are the agent states that mean "not working right now".
// The Python version only checked "idle", so an agent that parked on "done"
// never produced an alert.
var quietStatuses = map[string]bool{
	"idle": true,
	"done": true,
}

// Event is one pane that just went quiet.
type Event struct {
	Pane Pane
	Tail string
}

// scan reads one session and returns the panes that went quiet since the last
// poll, mutating state in place.
type scanner struct {
	client   *Client
	state    *State
	lines    int
	allPanes bool
	skip     map[string]bool
	workers  int
}

type readResult struct {
	pane Pane
	tail string
	err  error
}

func (s *scanner) scan(session string) (events []Event, seen map[string]bool, errs []error) {
	seen = map[string]bool{}

	panes, err := s.client.Panes()
	if err != nil {
		return nil, seen, []error{err}
	}

	// Deterministic order so a run's output and its state file are stable.
	sort.Slice(panes, func(i, j int) bool { return panes[i].PaneID < panes[j].PaneID })

	var targets []Pane
	for _, p := range panes {
		p.Session = session
		if s.skip[p.PaneID] || s.skip[p.Key()] {
			continue
		}
		// A pane with no agent has agent_status "unknown" forever, so it can
		// never go quiet. Reading it is 61 wasted subprocesses on my machine.
		if p.Agent == "" && !s.allPanes {
			continue
		}
		targets = append(targets, p)
	}

	results := s.readAll(targets)

	for _, r := range results {
		if r.err != nil {
			// Keep the pane's state. A read that failed this poll says nothing
			// about whether the agent is quiet, and hashing the error message
			// would look like perfectly stable output.
			errs = append(errs, r.err)
			seen[r.pane.Key()] = true
			continue
		}
		key := r.pane.Key()
		seen[key] = true

		sum := sha256.Sum256([]byte(r.tail))
		hash := hex.EncodeToString(sum[:])

		st, known := s.state.Panes[key]
		st.Agent = r.pane.Agent
		st.Status = r.pane.AgentStatus
		st.Cwd = r.pane.Cwd

		switch {
		case !known:
			// First sighting. Record the tail and wait for it to change.
			st.Hash = hash
		case hash != st.Hash:
			// New output means a new work cycle, so re-arm the alert. The
			// Python version only re-armed when it happened to catch the pane
			// in "working" state, which lost every cycle that started and
			// finished inside one poll interval.
			st.Hash = hash
			st.Ever = true
			st.Reported = false
		case st.Ever && !st.Reported && s.isQuiet(r.pane):
			st.Reported = true
			events = append(events, Event{Pane: r.pane, Tail: r.tail})
		}

		s.state.Panes[key] = st
	}
	return events, seen, errs
}

// isQuiet decides whether a settled pane counts as finished. Agent panes go by
// the status herdr reports. With -all-panes a plain shell has no status, so
// stable output is all we have.
func (s *scanner) isQuiet(p Pane) bool {
	if p.Agent == "" {
		return s.allPanes
	}
	return quietStatuses[p.AgentStatus]
}

// readAll reads pane tails concurrently. Serially this is one subprocess per
// pane per poll, which on 78 panes is slow enough that the tails no longer
// describe the same moment.
func (s *scanner) readAll(panes []Pane) []readResult {
	results := make([]readResult, len(panes))
	workers := s.workers
	if workers < 1 {
		workers = 1
	}

	sem := make(chan struct{}, workers)
	var wg sync.WaitGroup
	for i, p := range panes {
		wg.Add(1)
		go func(i int, p Pane) {
			defer wg.Done()
			sem <- struct{}{}
			defer func() { <-sem }()
			tail, err := s.client.Read(p.PaneID, s.lines)
			results[i] = readResult{pane: p, tail: tail, err: err}
		}(i, p)
	}
	wg.Wait()
	return results
}

// prune drops panes that no longer exist. The Python state file grew forever;
// mine had 68 entries for panes that were long gone.
func prune(state *State, seen map[string]bool) int {
	dropped := 0
	for key := range state.Panes {
		if !seen[key] {
			delete(state.Panes, key)
			dropped++
		}
	}
	return dropped
}

// summary is the one line worth speaking or putting in a notification.
func summary(p Pane) string {
	who := p.Agent
	if who == "" {
		who = "shell"
	}
	where := p.Repo()
	if where == "" {
		where = p.PaneID
	}
	return who + " in " + where + " is done"
}

// detail is the notification body: whatever the pane calls itself.
func detail(p Pane) string {
	if t := strings.TrimSpace(p.Title); t != "" {
		return t
	}
	if t := strings.TrimSpace(p.Tokens.Summary); t != "" {
		return t
	}
	return p.Cwd
}

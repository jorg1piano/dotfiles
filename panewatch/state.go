package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"syscall"
)

// PaneState is what we remember about one pane between runs.
//
// Hash is the digest of the pane's tail at the last poll. Ever records that
// the pane has produced output since we started watching it, which stops a
// pane that was already idle at baseline from being reported. Reported keeps
// one quiet spell to one alert.
type PaneState struct {
	Hash     string `json:"hash"`
	Ever     bool   `json:"ever"`
	Reported bool   `json:"reported"`
	Agent    string `json:"agent,omitempty"`
	Status   string `json:"status,omitempty"`
	Cwd      string `json:"cwd,omitempty"`
}

// State is the whole file: pane key -> pane state, plus a version so a future
// format change can reset cleanly instead of misreading old data.
type State struct {
	Version int                  `json:"version"`
	Panes   map[string]PaneState `json:"panes"`
}

const stateVersion = 1

// LoadState reads the state file. A missing or unreadable file yields an empty
// state, which the caller treats as a baseline run. Corruption is not fatal:
// losing a baseline costs one poll, crashing every minute from cron costs more.
func LoadState(path string) (*State, bool) {
	s := &State{Version: stateVersion, Panes: map[string]PaneState{}}

	raw, err := os.ReadFile(path)
	if err != nil {
		return s, false
	}
	var loaded State
	if err := json.Unmarshal(raw, &loaded); err != nil {
		return s, false
	}
	if loaded.Version != stateVersion || loaded.Panes == nil {
		return s, false
	}
	s.Panes = loaded.Panes
	return s, len(s.Panes) > 0
}

// SaveState writes the state atomically. A truncating write that dies halfway
// leaves JSON that never parses again, which silently disables the watcher.
func SaveState(path string, s *State) error {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(dir, ".state-*.json")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	defer os.Remove(tmpName)

	enc := json.NewEncoder(tmp)
	enc.SetIndent("", "  ")
	if err := enc.Encode(s); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if err := os.Chmod(tmpName, 0o644); err != nil {
		return err
	}
	return os.Rename(tmpName, path)
}

// Lock takes an exclusive non-blocking lock. Two overlapping cron runs would
// otherwise both read the old state and the second would clobber the first,
// re-arming alerts that were already sent.
func Lock(path string) (func(), bool, error) {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return nil, false, err
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0o644)
	if err != nil {
		return nil, false, err
	}
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		f.Close()
		if err == syscall.EWOULDBLOCK {
			return nil, false, nil
		}
		return nil, false, fmt.Errorf("lock %s: %w", path, err)
	}
	release := func() {
		syscall.Flock(int(f.Fd()), syscall.LOCK_UN)
		f.Close()
	}
	return release, true, nil
}

// DefaultStateDir follows XDG, so state survives reboots and temp cleaners.
func DefaultStateDir() string {
	if x := os.Getenv("XDG_STATE_HOME"); x != "" {
		return filepath.Join(x, "panewatch")
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return filepath.Join(os.TempDir(), "panewatch")
	}
	return filepath.Join(home, ".local", "state", "panewatch")
}

package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// Session is one entry of `herdr session list --json`.
type Session struct {
	Name       string `json:"name"`
	Running    bool   `json:"running"`
	Default    bool   `json:"default"`
	SocketPath string `json:"socket_path"`
	SessionDir string `json:"session_dir"`
}

// Pane is the subset of `herdr pane list` we act on. The list covers every
// workspace and tab of a session, so one call per session sees everything.
type Pane struct {
	PaneID      string `json:"pane_id"`
	WorkspaceID string `json:"workspace_id"`
	TabID       string `json:"tab_id"`
	Agent       string `json:"agent"`
	AgentStatus string `json:"agent_status"`
	Cwd         string `json:"cwd"`
	Focused     bool   `json:"focused"`
	Title       string `json:"terminal_title_stripped"`
	Tokens      struct {
		Summary string `json:"summary"`
	} `json:"tokens"`

	// Filled in by the scan, not by herdr.
	Session string `json:"-"`
}

// Key identifies a pane globally. Pane ids repeat across sessions.
func (p Pane) Key() string { return p.Session + "/" + p.PaneID }

// Repo is the last path element of the cwd, which is what you actually
// recognise a pane by.
func (p Pane) Repo() string {
	if p.Cwd == "" {
		return ""
	}
	return filepath.Base(p.Cwd)
}

// apiError is the shape herdr returns on stdout when a call fails. It also
// sets a non-zero exit status, but not through every code path, so both get
// checked.
type apiError struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

type envelope struct {
	Error  *apiError       `json:"error"`
	Result json.RawMessage `json:"result"`
}

// Client runs the herdr CLI against one session's socket.
type Client struct {
	Bin     string
	Socket  string
	Timeout time.Duration
}

func (c *Client) run(args ...string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(context.Background(), c.Timeout)
	defer cancel()

	cmd := exec.CommandContext(ctx, c.Bin, args...)
	cmd.Env = append(os.Environ(), "HERDR_SOCKET_PATH="+c.Socket)
	// A herdr call must never inherit this process's terminal.
	cmd.Stdin = nil

	out, err := cmd.Output()
	if ctx.Err() == context.DeadlineExceeded {
		return nil, fmt.Errorf("herdr %s: timed out after %s", strings.Join(args, " "), c.Timeout)
	}
	if err != nil {
		// herdr reports API failures as JSON on stdout even when it exits 1,
		// so prefer that message over the raw exit status.
		if msg := apiErrorMessage(out); msg != "" {
			return nil, fmt.Errorf("herdr %s: %s", strings.Join(args, " "), msg)
		}
		if stderr := exitStderr(err); stderr != "" {
			return nil, fmt.Errorf("herdr %s: %s", strings.Join(args, " "), stderr)
		}
		return nil, fmt.Errorf("herdr %s: %w", strings.Join(args, " "), err)
	}
	if msg := apiErrorMessage(out); msg != "" {
		return nil, fmt.Errorf("herdr %s: %s", strings.Join(args, " "), msg)
	}
	return out, nil
}

// exitStderr pulls the captured stderr out of a failed exec, if there is any.
func exitStderr(err error) string {
	var ee *exec.ExitError
	if errors.As(err, &ee) {
		return strings.TrimSpace(string(ee.Stderr))
	}
	return ""
}

// apiErrorMessage returns the error message if out is a herdr error envelope.
func apiErrorMessage(out []byte) string {
	trimmed := strings.TrimSpace(string(out))
	if !strings.HasPrefix(trimmed, "{") {
		return ""
	}
	var env envelope
	if json.Unmarshal([]byte(trimmed), &env) != nil {
		return ""
	}
	if env.Error == nil {
		return ""
	}
	if env.Error.Code != "" {
		return env.Error.Code + ": " + env.Error.Message
	}
	return env.Error.Message
}

// Panes lists every pane in every workspace and tab of the session.
func (c *Client) Panes() ([]Pane, error) {
	out, err := c.run("pane", "list")
	if err != nil {
		return nil, err
	}
	var env struct {
		Result struct {
			Panes []Pane `json:"panes"`
		} `json:"result"`
	}
	if err := json.Unmarshal(out, &env); err != nil {
		return nil, fmt.Errorf("herdr pane list: bad json: %w", err)
	}
	return env.Result.Panes, nil
}

// Read returns the last n lines of a pane as plain text.
func (c *Client) Read(paneID string, lines int) (string, error) {
	out, err := c.run("pane", "read", paneID, "--lines", fmt.Sprint(lines), "--format", "text")
	if err != nil {
		return "", err
	}
	return string(out), nil
}

// Notify raises a herdr notification. Only useful when someone is looking at
// the session, so failures are the caller's to ignore.
func (c *Client) Notify(title, body string) error {
	_, err := c.run("notification", "show", title, "--body", body, "--sound", "done")
	return err
}

// Sessions lists herdr sessions. It uses the CLI's own default socket
// discovery rather than a session name, so it never starts a server.
func Sessions(bin string, timeout time.Duration) ([]Session, error) {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()

	cmd := exec.CommandContext(ctx, bin, "session", "list", "--json")
	cmd.Stdin = nil
	out, err := cmd.Output()
	if ctx.Err() == context.DeadlineExceeded {
		return nil, fmt.Errorf("herdr session list: timed out after %s", timeout)
	}
	if err != nil {
		if msg := apiErrorMessage(out); msg != "" {
			return nil, fmt.Errorf("herdr session list: %s", msg)
		}
		if stderr := exitStderr(err); stderr != "" {
			return nil, fmt.Errorf("herdr session list: %s", stderr)
		}
		return nil, fmt.Errorf("herdr session list: %w", err)
	}
	var payload struct {
		Sessions []Session `json:"sessions"`
	}
	if err := json.Unmarshal(out, &payload); err != nil {
		return nil, fmt.Errorf("herdr session list: bad json: %w", err)
	}
	return payload.Sessions, nil
}

// findHerdr resolves the herdr binary. cron runs with a PATH of roughly
// /usr/bin:/bin, so PATH lookup alone is not enough.
func findHerdr(override string) (string, error) {
	if override != "" {
		return exec.LookPath(override)
	}
	if env := os.Getenv("PANEWATCH_HERDR"); env != "" {
		return exec.LookPath(env)
	}
	if p, err := exec.LookPath("herdr"); err == nil {
		return p, nil
	}
	home, _ := os.UserHomeDir()
	candidates := []string{
		filepath.Join(home, ".local", "bin", "herdr"),
		"/opt/homebrew/bin/herdr",
		"/usr/local/bin/herdr",
	}
	for _, c := range candidates {
		if fi, err := os.Stat(c); err == nil && !fi.IsDir() {
			return c, nil
		}
	}
	return "", fmt.Errorf("herdr not found on PATH or in %s; pass -herdr or set PANEWATCH_HERDR", strings.Join(candidates, ", "))
}

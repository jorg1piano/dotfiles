package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"runtime"
)

// player is a command line audio player and the arguments it needs to play
// a file whose path is appended last.
type player struct {
	name string
	args []string
}

var players = map[string][]player{
	"darwin": {
		{name: "afplay"},
	},
	"linux": {
		{name: "ffplay", args: []string{"-nodisp", "-autoexit", "-loglevel", "error"}},
		{name: "mpv", args: []string{"--no-video", "--really-quiet"}},
		{name: "mpg123", args: []string{"-q"}},
		{name: "paplay"},
		{name: "aplay", args: []string{"-q"}},
	},
	"windows": {
		{name: "ffplay", args: []string{"-nodisp", "-autoexit", "-loglevel", "error"}},
	},
}

// play buffers the audio to a temp file and hands it to a local player.
func play(ctx context.Context, r io.Reader, format string) error {
	if format == "pcm" {
		return errors.New("pcm has no container that players can read; use -o out.pcm or pick another -format")
	}

	cmd, err := findPlayer()
	if err != nil {
		return err
	}

	f, err := os.CreateTemp("", "saythis-*."+format)
	if err != nil {
		return err
	}
	defer os.Remove(f.Name())

	if _, err := io.Copy(f, r); err != nil {
		f.Close()
		return err
	}
	if err := f.Close(); err != nil {
		return err
	}

	c := exec.CommandContext(ctx, cmd.name, append(cmd.args, f.Name())...)
	c.Stdout = os.Stderr
	c.Stderr = os.Stderr
	if err := c.Run(); err != nil {
		if ctx.Err() != nil {
			return nil // interrupted on purpose
		}
		return fmt.Errorf("%s: %w", cmd.name, err)
	}
	return nil
}

func findPlayer() (player, error) {
	candidates := players[runtime.GOOS]
	for _, p := range candidates {
		if path, err := exec.LookPath(p.name); err == nil {
			p.name = path
			return p, nil
		}
	}
	if len(candidates) == 0 {
		return player{}, fmt.Errorf("no known audio player for %s; use -o to save the audio instead", runtime.GOOS)
	}
	return player{}, fmt.Errorf("no audio player found (looked for %s); install one or use -o to save the audio", names(candidates))
}

func names(ps []player) string {
	out := ""
	for i, p := range ps {
		if i > 0 {
			out += ", "
		}
		out += p.name
	}
	return out
}

// Command saythis turns text into speech with the OpenAI audio API and plays it.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
)

const usage = `saythis - speak text out loud using the OpenAI audio API

Usage:
  saythis [flags] "text to speak"
  echo "text to speak" | saythis [flags]

Flags:
  -voice string     voice name (default "alloy")
  -model string     TTS model (default "gpt-4o-mini-tts")
  -speed float      playback rate from 0.25 to 4.0 (default 1)
  -instructions s   tone/delivery hints, gpt-4o-mini-tts only
  -o string         write audio to this file instead of playing it
  -format string    audio format: mp3, wav, opus, aac, flac, pcm (default "mp3")
  -voices           list the available voices and exit

Environment (a .env file in this or a parent directory is read too):
  T2S               your OpenAI API key
  OPENAI_API_KEY    used when T2S is unset
  OPENAI_BASE_URL   override the API host (default https://api.openai.com/v1)

Examples:
  saythis "Say this out loud"
  saythis -voice nova -speed 1.2 "Reading a little faster"
  saythis -instructions "whisper, conspiratorial" "They are listening"
  saythis -o hello.mp3 "Saved instead of played"
  cat notes.txt | saythis
`

var voices = []string{
	"alloy", "ash", "ballad", "coral", "echo",
	"fable", "onyx", "nova", "sage", "shimmer", "verse",
}

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, "saythis:", err)
		os.Exit(1)
	}
}

func run() error {
	fs := flag.NewFlagSet("saythis", flag.ContinueOnError)
	fs.SetOutput(os.Stderr)
	fs.Usage = func() { io.WriteString(os.Stderr, usage) }

	voice := fs.String("voice", envOr("SAYTHIS_VOICE", "alloy"), "voice name")
	model := fs.String("model", envOr("SAYTHIS_MODEL", "gpt-4o-mini-tts"), "TTS model")
	speed := fs.Float64("speed", 1, "playback rate, 0.25 to 4.0")
	instructions := fs.String("instructions", "", "tone and delivery hints")
	out := fs.String("o", "", "write audio to this file instead of playing it")
	format := fs.String("format", "", "audio format")
	listVoices := fs.Bool("voices", false, "list available voices")

	if err := fs.Parse(os.Args[1:]); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return nil
		}
		return err
	}

	if *listVoices {
		fmt.Println(strings.Join(voices, "\n"))
		return nil
	}

	text, err := readText(fs.Args())
	if err != nil {
		return err
	}

	if *format == "" {
		*format = formatFor(*out)
	}
	if *speed < 0.25 || *speed > 4 {
		return fmt.Errorf("speed %.2f is outside the 0.25 to 4.0 range", *speed)
	}

	loadDotEnv()

	client, err := newClient()
	if err != nil {
		return err
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	req := speechRequest{
		Model:          *model,
		Input:          text,
		Voice:          *voice,
		Speed:          *speed,
		ResponseFormat: *format,
		Instructions:   *instructions,
	}

	body, err := client.speech(ctx, req)
	if err != nil {
		return err
	}
	defer body.Close()

	if *out != "" {
		return writeFile(*out, body)
	}
	return play(ctx, body, *format)
}

// readText takes the words from argv, or from stdin when argv has none.
func readText(args []string) (string, error) {
	if len(args) > 0 {
		return strings.Join(args, " "), nil
	}

	info, err := os.Stdin.Stat()
	if err != nil {
		return "", err
	}
	if info.Mode()&os.ModeCharDevice != 0 {
		return "", errors.New("no text given; pass it as an argument or pipe it on stdin (saythis -h for help)")
	}

	b, err := io.ReadAll(os.Stdin)
	if err != nil {
		return "", fmt.Errorf("reading stdin: %w", err)
	}
	text := strings.TrimSpace(string(b))
	if text == "" {
		return "", errors.New("stdin was empty")
	}
	return text, nil
}

func writeFile(path string, r io.Reader) error {
	f, err := os.Create(path)
	if err != nil {
		return err
	}
	if _, err := io.Copy(f, r); err != nil {
		f.Close()
		return err
	}
	if err := f.Close(); err != nil {
		return err
	}
	fmt.Fprintln(os.Stderr, "wrote", path)
	return nil
}

// formatFor picks the audio format from the output file extension.
func formatFor(out string) string {
	ext := strings.TrimPrefix(strings.ToLower(filepath.Ext(out)), ".")
	switch ext {
	case "mp3", "wav", "opus", "aac", "flac", "pcm":
		return ext
	}
	return "mp3"
}

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

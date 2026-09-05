# saythis

A small Go CLI that speaks text out loud through the OpenAI audio API.

```
saythis "Say this out loud"
```

It sends the text to `POST /v1/audio/speech`, writes the returned audio to a temp
file, and plays it with the system player (`afplay` on macOS, `ffplay`/`mpv`/
`mpg123`/`paplay`/`aplay` on Linux). No third party Go dependencies.

The name avoids the `say` binary macOS already ships in `/usr/bin`.

## Install

```
just install
```

That builds the binary, drops it in `~/.local/bin`, and copies your `.env` key to
`~/.config/saythis/.env` so it works from any directory. Install somewhere else
with `BINDIR=/usr/local/bin just install`.

`just uninstall` removes the binary and leaves the key. `just purge` removes both.
`just --list` shows the rest.

## The API key

The key comes from `T2S`, falling back to `OPENAI_API_KEY`. Either works as a
shell variable or as a line in a `.env` file:

```
T2S=sk-...
```

`saythis` looks for `.env` in the working directory, then each parent up to your
home directory, then `~/.config/saythis/.env`. That last one is what makes an
installed `saythis` work anywhere, and `just install` puts it there. Shell
variables win over the file, so you can override the key for one command.
`SAYTHIS_ENV_FILE` points at a specific file. `.env` is gitignored.

## Use

```
saythis "Say this out loud"
saythis -voice nova -speed 1.2 "Reading a little faster"
saythis -instructions "whisper, conspiratorial" "They are listening"
saythis -o hello.mp3 "Saved instead of played"
cat notes.txt | saythis
saythis -voices
```

With no arguments it reads stdin, so it drops into a pipeline:

```
go test ./... 2>&1 | tail -1 | saythis
```

## Flags

| Flag | Default | What it does |
| --- | --- | --- |
| `-voice` | `alloy` | One of the names from `saythis -voices` |
| `-model` | `gpt-4o-mini-tts` | `tts-1` and `tts-1-hd` also work |
| `-speed` | `1` | 0.25 to 4.0 |
| `-instructions` | none | Tone and delivery hints, `gpt-4o-mini-tts` only |
| `-o` | none | Write the audio to this path instead of playing it |
| `-format` | from `-o`, else `mp3` | `mp3`, `wav`, `opus`, `aac`, `flac`, `pcm` |
| `-voices` | | Print the voice names and exit |

`SAYTHIS_VOICE` and `SAYTHIS_MODEL` change the defaults. `OPENAI_BASE_URL` points
at a proxy or a compatible server.

`-format pcm` returns raw samples with no header, so it only works with `-o`.

`gpt-4o-mini-tts` takes a few seconds to generate a short line before playback
starts. `-model tts-1` is quicker and cheaper if you do not need `-instructions`.

## Files

- `main.go` flags, input handling, wiring
- `env.go` reading `.env` and resolving the API key
- `openai.go` the API call and error messages
- `play.go` picking a local player and running it
- `justfile` build, install, uninstall

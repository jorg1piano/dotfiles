default:
    @just --list

# Install the tools and link every managed config into place.
setup: brew-install herdr-link git-link nvim-link ghostty-link tools-install

# Install the Homebrew formulae the configs depend on.
brew-install:
    #!/usr/bin/env bash
    set -euo pipefail

    if ! command -v brew >/dev/null; then
        echo "brew is not on PATH — install Homebrew first: https://brew.sh" >&2
        exit 1
    fi

    for formula in ripgrep; do
        if brew list --formula "$formula" >/dev/null 2>&1; then
            echo "already installed: $formula"
        else
            brew install "$formula"
        fi
    done

    for cask in fluidvoice; do
        if brew list --cask "$cask" >/dev/null 2>&1; then
            echo "already installed: $cask"
        else
            brew install --cask "$cask"
        fi
    done

# Link the herdr config and its helper scripts, then reload the running server.
herdr-link:
    #!/usr/bin/env bash
    set -euo pipefail

    link() {
        src="$1" dst="$2"
        mkdir -p "$(dirname "$dst")"
        if [ -L "$dst" ] && [ "$(readlink "$dst")" = "$src" ]; then
            echo "already linked: $dst"
            return
        fi
        if [ -e "$dst" ] && [ ! -L "$dst" ]; then
            mv "$dst" "$dst.bak.$(date +%Y%m%d%H%M%S)"
            echo "backed up existing $dst"
        fi
        ln -sfn "$src" "$dst"
        echo "linked $dst -> $src"
    }

    repo="{{justfile_directory()}}"
    chmod +x "$repo/scripts/herdr-worktree-create" "$repo/scripts/herdr-pick"
    link "$repo/herdr/config.toml" "$HOME/.config/herdr/config.toml"
    link "$repo/scripts/herdr-worktree-create" "$HOME/.local/bin/herdr-worktree-create"
    link "$repo/scripts/herdr-pick" "$HOME/.local/bin/herdr-pick"

    # Bindings of type plugin_action are dead until the plugin is registered,
    # and linking an already-linked plugin is a no-op refresh.
    for plugin in "$repo"/herdr/plugins/*/; do
        [ -f "$plugin/herdr-plugin.toml" ] || continue
        chmod +x "$plugin"/*.sh 2>/dev/null || true
        herdr plugin link "${plugin%/}" >/dev/null && echo "linked plugin: $(basename "$plugin")"
    done

    for tool in fzf jq; do
        command -v "$tool" >/dev/null || echo "warning: $tool is not on PATH — prefix+' will fail until it is" >&2
    done

    if ! command -v sdf >/dev/null; then
        echo "warning: sdf is not on PATH — prefix+shift+g will fail until it is" >&2
    fi
    command -v herdr >/dev/null && herdr server reload-config || true

# Link the repo's Neovim specs into the LazyVim config and register the import.
nvim-link:
    #!/usr/bin/env bash
    set -euo pipefail

    repo="{{justfile_directory()}}"
    config="$HOME/.config/nvim"

    if [ ! -d "$config" ]; then
        echo "no LazyVim config at $config — clone the starter first:" >&2
        echo "  git clone https://github.com/LazyVim/starter $config && rm -rf $config/.git" >&2
        exit 1
    fi

    # The specs live in the repo; the config dir only gets a symlink to them, so
    # "dotfiles.plugins" resolves off the config's own lua/ directory.
    src="$repo/nvim/lua/dotfiles"
    dst="$config/lua/dotfiles"
    if [ -L "$dst" ] && [ "$(readlink "$dst")" = "$src" ]; then
        echo "already linked: $dst"
    else
        if [ -e "$dst" ] && [ ! -L "$dst" ]; then
            mv "$dst" "$dst.bak.$(date +%Y%m%d%H%M%S)"
            echo "backed up existing $dst"
        fi
        ln -sfn "$src" "$dst"
        echo "linked $dst -> $src"
    fi

    # lazy.lua is an upstream starter file, so the import has to be patched in
    # rather than shipped. Anchor on LazyVim's own spec line to keep ordering.
    lazy="$config/lua/config/lazy.lua"
    if grep -q 'dotfiles\.plugins' "$lazy"; then
        echo "already imported: dotfiles.plugins"
    else
        cp "$lazy" "$lazy.bak.$(date +%Y%m%d%H%M%S)"
        awk '
            /{ "LazyVim\/LazyVim", import = "lazyvim.plugins" },/ {
                print
                print "    -- shared specs tracked in ~/dotfiles"
                print "    { import = \"dotfiles.plugins\" },"
                next
            }
            { print }
        ' "$lazy" > "$lazy.tmp"
        if grep -q 'dotfiles\.plugins' "$lazy.tmp"; then
            mv "$lazy.tmp" "$lazy"
            echo "imported dotfiles.plugins in $lazy"
        else
            rm -f "$lazy.tmp"
            echo "could not find the LazyVim spec line in $lazy — add this to the spec table by hand:" >&2
            echo '  { import = "dotfiles.plugins" },' >&2
            exit 1
        fi
    fi

# Link the Ghostty configuration.
ghostty-link:
    #!/usr/bin/env bash
    set -euo pipefail

    repo="{{justfile_directory()}}"
    config="$HOME/.config/ghostty"
    mkdir -p "$config"
    dst="$config/config"
    src="$repo/ghostty/config"

    if [ -L "$dst" ] && [ "$(readlink "$dst")" = "$src" ]; then
        echo "already linked: $dst"
    else
        if [ -e "$dst" ] && [ ! -L "$dst" ]; then
            mv "$dst" "$dst.bak.$(date +%Y%m%d%H%M%S)"
            echo "backed up existing $dst"
        fi
        ln -sfn "$src" "$dst"
        echo "linked $dst -> $src"
    fi

# Point git's global excludes at the repo's gitignore_global.
git-link:
    #!/usr/bin/env bash
    set -euo pipefail

    repo="{{justfile_directory()}}"
    want="$repo/git/gitignore_global"
    have=$(git config --global --get core.excludesfile || true)

    if [ "$have" = "$want" ]; then
        echo "already set: core.excludesfile -> $want"
    else
        [ -n "$have" ] && echo "replacing core.excludesfile (was $have)"
        git config --global core.excludesfile "$want"
        echo "set core.excludesfile -> $want"
    fi

# Where the Go tools in this repo get installed, and how the poller is scheduled.
bindir := env("BINDIR", env("HOME") / ".local/bin")
panewatch_flags := env("PANEWATCH_FLAGS", "-quiet -notify")
panewatch_schedule := env("PANEWATCH_SCHEDULE", "* * * * *")
panewatch_label := "com.jorgen.panewatch"

# Build and install the Go tools in this repo: panewatch and saythis.
tools-install: panewatch-install saythis-install

# Build panewatch and put it on your PATH.
panewatch-install:
    #!/usr/bin/env bash
    set -euo pipefail

    command -v go >/dev/null || { echo "go is not on PATH — brew install go" >&2; exit 1; }

    repo="{{justfile_directory()}}"
    mkdir -p "{{bindir}}"
    cd "$repo/panewatch"
    go build -o "$repo/panewatch/panewatch" .
    install -m 0755 "$repo/panewatch/panewatch" "{{bindir}}/panewatch"
    rm -f "$repo/panewatch/panewatch"
    echo "installed {{bindir}}/panewatch"

    case ":$PATH:" in
        *":{{bindir}}:"*) ;;
        *) echo "{{bindir}} is not on your PATH. Add to ~/.zshrc:"; \
           echo "  export PATH=\"{{bindir}}:\$PATH\"" ;;
    esac

# Build saythis and put it on your PATH. The API key stays in ~/.config/saythis.
saythis-install:
    #!/usr/bin/env bash
    set -euo pipefail

    command -v go >/dev/null || { echo "go is not on PATH — brew install go" >&2; exit 1; }

    repo="{{justfile_directory()}}"
    mkdir -p "{{bindir}}"
    cd "$repo/saythis"
    go build -o "$repo/saythis/saythis" .
    install -m 0755 "$repo/saythis/saythis" "{{bindir}}/saythis"
    rm -f "$repo/saythis/saythis"
    echo "installed {{bindir}}/saythis"

    # The key never lives in this repo. saythis reads T2S or OPENAI_API_KEY from
    # the environment first, then ~/.config/saythis/.env.
    conf="$HOME/.config/saythis/.env"
    if [ -f "$conf" ]; then
        chmod 600 "$conf"
        echo "using the key already in $conf"
    elif [ -n "${T2S:-}${OPENAI_API_KEY:-}" ]; then
        echo "using the key from your environment"
    else
        echo "no API key yet. Write one to $conf:" >&2
        echo "  mkdir -p \"\$(dirname \"$conf\")\" && echo 'T2S=sk-...' > \"$conf\" && chmod 600 \"$conf\"" >&2
    fi

# Poll for quiet agents every minute from crontab. Prefer panewatch-launchd on macOS.
panewatch-cron: panewatch-install
    #!/usr/bin/env bash
    set -euo pipefail

    bin="{{bindir}}/panewatch"
    line="{{panewatch_schedule}} $bin {{panewatch_flags}} # {{panewatch_label}}"

    # crontab -l exits 1 when there is no crontab yet, which is not an error here.
    current=$(crontab -l 2>/dev/null || true)
    kept=$(printf '%s\n' "$current" | grep -v "{{panewatch_label}}" || true)
    printf '%s\n%s\n' "$kept" "$line" | grep -v '^$' | crontab -
    echo "scheduled: $line"
    echo
    echo "macOS: give /usr/sbin/cron Full Disk Access, or cron cannot read your"
    echo "state file. System Settings > Privacy & Security > Full Disk Access."

# Remove the crontab entry.
panewatch-uncron:
    #!/usr/bin/env bash
    set -euo pipefail

    current=$(crontab -l 2>/dev/null || true)
    if ! printf '%s\n' "$current" | grep -q "{{panewatch_label}}"; then
        echo "no panewatch entry in crontab"
        exit 0
    fi
    printf '%s\n' "$current" | grep -v "{{panewatch_label}}" | grep -v '^$' | crontab - || crontab -r
    echo "removed the panewatch crontab entry"

# Poll for quiet agents every minute from launchd. This is the one that works on macOS.
panewatch-launchd: panewatch-install
    #!/usr/bin/env bash
    set -euo pipefail

    bin="{{bindir}}/panewatch"
    plist="$HOME/Library/LaunchAgents/{{panewatch_label}}.plist"
    logdir="$HOME/.local/state/panewatch"
    mkdir -p "$(dirname "$plist")" "$logdir"

    # Each flag is its own ProgramArguments entry, so build the array from the
    # flag string rather than interpolating it as one string.
    args=""
    for flag in {{panewatch_flags}}; do
        args="$args        <string>$flag</string>"$'\n'
    done

    cat > "$plist" <<PLIST
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>Label</key>
        <string>{{panewatch_label}}</string>
        <key>ProgramArguments</key>
        <array>
            <string>$bin</string>
    $args    </array>
        <key>StartInterval</key>
        <integer>60</integer>
        <key>RunAtLoad</key>
        <false/>
        <key>StandardOutPath</key>
        <string>$logdir/panewatch.log</string>
        <key>StandardErrorPath</key>
        <string>$logdir/panewatch.err</string>
        <key>EnvironmentVariables</key>
        <dict>
            <key>PATH</key>
            <string>{{bindir}}:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
        </dict>
    </dict>
    </plist>
    PLIST

    # The heredoc above is indented to match the recipe, so strip it back out.
    sed -i '' 's/^    //' "$plist"
    plutil -lint "$plist" >/dev/null

    launchctl bootout "gui/$(id -u)/{{panewatch_label}}" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$plist"
    echo "loaded {{panewatch_label}}, polling every 60s"
    echo "logs: $logdir/panewatch.log and panewatch.err"

# Unload and remove the launchd agent.
panewatch-unlaunchd:
    #!/usr/bin/env bash
    set -euo pipefail

    plist="$HOME/Library/LaunchAgents/{{panewatch_label}}.plist"
    launchctl bootout "gui/$(id -u)/{{panewatch_label}}" 2>/dev/null || true
    rm -f "$plist"
    echo "removed {{panewatch_label}}"

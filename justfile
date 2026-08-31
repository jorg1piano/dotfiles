default:
    @just --list

# Install the tools and link every managed config into place.
setup: brew-install herdr-link git-link nvim-link ghostty-link

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

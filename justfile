default:
    @just --list

# Install the tools and link every managed config into place.
setup: brew-install herdr-link git-link

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

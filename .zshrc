# Open config files
alias aliases='code ~/.zshrc'
alias dotfiles='code ~/dotfiles'
alias config-zshrc='code ~/dotfiles/.zshrc'
alias config-tmux='code ~/dotfiles/tmux.conf'
alias config-hammerspoon='code ~/dotfiles/hammerspoon/init.lua'

# Mac OS
alias clip='pbcopy'
alias past='pbpaste'

killPort() {
    kill -9 $(lsof -t -i:$1)
}

# Git aliases
alias WIP='git add -A && git commit -m "WIP"'
alias gc='git checkout '
alias status='git status'
alias s='git status'
alias add='git add -p'
alias staged="git diff --cached"
alias diff="git diff"
alias ss='git diff --name-only "$(git show-ref --verify --quiet refs/heads/master && echo master || echo main)..HEAD"'
alias c='git commit'
alias gca='git commit --amend'
alias l="git log"
alias ll="git log --oneline"
alias files="git status --short --untracked-files=all | grep '^??' | awk '{print \$NF}' | fzf | pbcopy"
cn() {
    local diff msg
    diff=$(git diff --cached)
    if [[ -z "$diff" ]]; then
        echo "cn: nothing staged" >&2
        return 1
    fi
    msg=$(printf '%s' "$diff" | claude -p "Write a concise git commit message for this staged diff. Output only the message, no quotes or code fences.") || return 1
    [[ -z "$msg" ]] && { echo "cn: empty message from claude" >&2; return 1; }
    git commit --no-verify -m "$msg"
}

gcb() {
    selected=$(git --no-pager branch --sort=-committerdate | sed 's/^..//' | fzf)
}

alias_add() {
    local def="$*"
    local name="${def%%=*}"
    local cmd="${def#*=}"
    name="${name// /}"
    cmd="${cmd# }"
    echo "alias ${name}=\"${cmd}\"" >> ~/.zshrc
    source ~/.zshrc
    echo "added: alias ${name}=\"${cmd}\""
}


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
alias staged="git diff --cached"
alias diff="git diff"
alias c='git commit'
alias gca='git commit --amend'
alias l="git log"
alias ll="git log --oneline"
alias files="git status --short --untracked-files=all | grep '^??' | awk '{print \$NF}' | fzf | pbcopy"
gcb() {
    selected=$(git --no-pager branch --sort=-committerdate | sed 's/^..//' | fzf)
}


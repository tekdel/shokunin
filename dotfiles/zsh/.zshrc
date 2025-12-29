# .zshrc - Zsh configuration with Oh My Zsh

# Path to Oh My Zsh installation
export ZSH="$HOME/.oh-my-zsh"

# Theme
ZSH_THEME="robbyrussell"  # Change to your preferred theme
# Popular themes: robbyrussell, agnoster, powerlevel10k/powerlevel10k, af-magic

# Plugins
plugins=(
    zsh-autosuggestions
    zsh-syntax-highlighting
    fast-syntax-highlighting
    docker
    sudo
    colored-man-pages
    command-not-found
    copypath
    copyfile
    dirhistory
    history
)

# Oh My Zsh configuration
CASE_SENSITIVE="false"
HYPHEN_INSENSITIVE="true"
DISABLE_AUTO_UPDATE="false"
DISABLE_UPDATE_PROMPT="false"
export UPDATE_ZSH_DAYS=7
ENABLE_CORRECTION="true"
COMPLETION_WAITING_DOTS="true"
HIST_STAMPS="yyyy-mm-dd"

# Load Oh My Zsh
source $ZSH/oh-my-zsh.sh

# ============================================================================
# User Configuration
# ============================================================================

# History configuration
HISTSIZE=10000
SAVEHIST=10000
setopt HIST_IGNORE_ALL_DUPS
setopt HIST_FIND_NO_DUPS
setopt SHARE_HISTORY

# Modern replacements (if installed)
if command -v eza >/dev/null 2>&1; then
    alias ls='eza --icons'
    alias ll='eza -lah --icons'
    alias la='eza -A --icons'
    alias lt='eza --tree --level=2 --icons'
else
    alias ll='ls -lah'
    alias la='ls -A'
fi

if command -v bat >/dev/null 2>&1; then
    alias cat='bat'
    export MANPAGER="sh -c 'col -bx | bat -l man -p'"
fi

# Common aliases
alias l='ls -CF'
alias ..='cd ..'
alias ...='cd ../..'
alias ....='cd ../../..'

# Git aliases (additional to Oh My Zsh git plugin)
alias gs='git status'
alias ga='git add'
alias gc='git commit'
alias gp='git push'
alias gpl='git pull'
alias gl='git log --oneline --graph --decorate'
alias gd='git diff'
alias gco='git checkout'

# Safety aliases
alias rm='rm -i'
alias cp='cp -i'
alias mv='mv -i'

# Package management
alias update='sudo pacman -Syu'
alias install='sudo pacman -S'
alias remove='sudo pacman -Rns'
alias search='pacman -Ss'
alias orphans='sudo pacman -Rns $(pacman -Qtdq)'

# Docker aliases
alias dps='docker ps'
alias dpsa='docker ps -a'
alias di='docker images'
alias dex='docker exec -it'
alias dlog='docker logs -f'
alias dcu='docker-compose up -d'
alias dcd='docker-compose down'
alias dcl='docker-compose logs -f'

# System info
alias sysinfo='fastfetch'
alias cpu='btop'
alias disk='duf'
alias space='dust'

# Quick edit
alias zshrc='${=EDITOR} ~/.zshrc'
alias zshreload='source ~/.zshrc'

# ============================================================================
# Tool Integrations
# ============================================================================

# tmux-sessionizer keybinding (Ctrl+f)
bindkey -s '^f' "tmux-sessionizer\n"

# Starship prompt (comment out if using Oh My Zsh theme)
# if command -v starship >/dev/null 2>&1; then
#     eval "$(starship init zsh)"
# fi

# Zoxide (smart cd)
if command -v zoxide >/dev/null 2>&1; then
    eval "$(zoxide init zsh)"
    alias cd='z'
fi

# Mise (version manager for languages)
if command -v mise >/dev/null 2>&1; then
    eval "$(mise activate zsh)"
fi

# fzf
if command -v fzf >/dev/null 2>&1; then
    source /usr/share/fzf/key-bindings.zsh
    source /usr/share/fzf/completion.zsh

    # fzf configuration
    export FZF_DEFAULT_OPTS="
        --height 40%
        --layout=reverse
        --border
        --inline-info
        --color=fg:#cdd6f4,bg:#1e1e2e,hl:#f38ba8
        --color=fg+:#cdd6f4,bg+:#313244,hl+:#f38ba8
        --color=info:#cba6f7,prompt:#cba6f7,pointer:#f5e0dc
        --color=marker:#f5e0dc,spinner:#f5e0dc,header:#f38ba8"

    # Use fd instead of find for fzf
    if command -v fd >/dev/null 2>&1; then
        export FZF_DEFAULT_COMMAND='fd --type f --hidden --follow --exclude .git'
        export FZF_CTRL_T_COMMAND="$FZF_DEFAULT_COMMAND"
    fi
fi

# ============================================================================
# PATH
# ============================================================================

# Add local bin to PATH
export PATH="$HOME/.local/bin:$PATH"
export PATH="$HOME/bin:$PATH"

# Go
export GOPATH="$HOME/go"
export PATH="$GOPATH/bin:$PATH"

# Rust
export PATH="$HOME/.cargo/bin:$PATH"

# ============================================================================
# Environment Variables
# ============================================================================

# Editor
export EDITOR='nvim'
export VISUAL='nvim'

# Language
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

# Less
export LESS='-R -F -X'

# ============================================================================
# Custom Functions
# ============================================================================

# Create directory and cd into it
mkcd() {
    mkdir -p "$1" && cd "$1"
}

# Extract archives
extract() {
    if [ -f "$1" ]; then
        case "$1" in
            *.tar.bz2)   tar xjf "$1"    ;;
            *.tar.gz)    tar xzf "$1"    ;;
            *.bz2)       bunzip2 "$1"    ;;
            *.rar)       unrar x "$1"    ;;
            *.gz)        gunzip "$1"     ;;
            *.tar)       tar xf "$1"     ;;
            *.tbz2)      tar xjf "$1"    ;;
            *.tgz)       tar xzf "$1"    ;;
            *.zip)       unzip "$1"      ;;
            *.Z)         uncompress "$1" ;;
            *.7z)        7z x "$1"       ;;
            *)           echo "'$1' cannot be extracted via extract()" ;;
        esac
    else
        echo "'$1' is not a valid file"
    fi
}

# Quick file content search
findin() {
    ripgrep "$1" . 2>/dev/null || grep -r "$1" .
}

# ============================================================================
# Welcome Message
# ============================================================================

# Show system info on new terminal (comment out if not wanted)
# fastfetch 2>/dev/null || neofetch 2>/dev/null || echo "Welcome to $(hostname)!"

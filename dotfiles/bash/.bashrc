# .bashrc - Bash configuration

# If not running interactively, don't do anything
[[ $- != *i* ]] && return

# History configuration
HISTSIZE=10000
HISTFILESIZE=20000
HISTCONTROL=ignoredups:erasedups
shopt -s histappend

# Check window size after each command
shopt -s checkwinsize

# Enable color support
alias ls='ls --color=auto'
alias grep='grep --color=auto'
alias diff='diff --color=auto'

# Modern replacements (if installed)
command -v eza >/dev/null && alias ls='eza --icons'
command -v bat >/dev/null && alias cat='bat'

# Common aliases
alias ll='ls -lah'
alias la='ls -A'
alias l='ls -CF'
alias ..='cd ..'
alias ...='cd ../..'

# Git aliases
alias gs='git status'
alias ga='git add'
alias gc='git commit'
alias gp='git push'
alias gl='git log --oneline --graph --decorate'

# Safety aliases
alias rm='rm -i'
alias cp='cp -i'
alias mv='mv -i'

# Package management
alias update='sudo pacman -Syu'
alias install='sudo pacman -S'
alias remove='sudo pacman -Rns'
alias search='pacman -Ss'

# System info
alias sysinfo='fastfetch'

# Starship prompt (if installed)
if command -v starship >/dev/null; then
    eval "$(starship init bash)"
else
    PS1='[\u@\h \W]\$ '
fi

# Zoxide (if installed)
command -v zoxide >/dev/null && eval "$(zoxide init bash)"

# fzf (if installed)
if command -v fzf >/dev/null; then
    source /usr/share/fzf/key-bindings.bash
    source /usr/share/fzf/completion.bash
fi

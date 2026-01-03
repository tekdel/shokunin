#!/bin/sh
# .zprofile - Zsh login shell configuration

# Default programs
export EDITOR="nvim"
export TERMINAL="alacritty"
export BROWSER="zen-browser"

# XDG Base Directory
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_DATA_HOME="$HOME/.local/share"
export XDG_CACHE_HOME="$HOME/.cache"

# Add local bin to PATH
export PATH="$HOME/.local/bin:$PATH"

# Mise (version manager)
if command -v mise >/dev/null 2>&1; then
    eval "$(mise activate zsh)"
fi

# Go
if command -v go >/dev/null 2>&1; then
    export PATH="$PATH:$(go env GOPATH)/bin"
fi

# Wayland-specific
export MOZ_ENABLE_WAYLAND=1
export QT_QPA_PLATFORM=wayland
export SDL_VIDEODRIVER=wayland
export _JAVA_AWT_WM_NONREPARENTING=1

# Auto-start Hyprland on TTY1 if not already running
if [ "$(tty)" = "/dev/tty1" ] && ! pgrep -x Hyprland >/dev/null 2>&1; then
    exec start-hyprland
fi

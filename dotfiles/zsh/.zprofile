#!/bin/sh
# .zprofile - Zsh login shell configuration

# Default programs
export EDITOR="nvim"
export VISUAL="nvim"
export TERMINAL="alacritty"
export BROWSER="google-chrome-canary"

# Language
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

# Less
export LESS='-R -F -X'

# XDG Base Directory
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_DATA_HOME="$HOME/.local/share"
export XDG_CACHE_HOME="$HOME/.cache"

# Add local bin to PATH
export PATH="$HOME/.local/bin:$PATH"

# Java
export JAVA_HOME=/usr/lib/jvm/java-17-openjdk

# Go
export GOPATH="$HOME/go"
export PATH="$GOPATH/bin:$PATH"

# Rust
export PATH="$HOME/.cargo/bin:$PATH"

# Android
export ANDROID_AVD_HOME="$HOME/.config/.android/avd"

# Wayland-specific
export MOZ_ENABLE_WAYLAND=1
export QT_QPA_PLATFORM=xcb
export SDL_VIDEODRIVER=wayland
export _JAVA_AWT_WM_NONREPARENTING=1

# Auto-start Hyprland on TTY1 if not already running
if [ "$(tty)" = "/dev/tty1" ] && ! pgrep -x Hyprland >/dev/null 2>&1; then
    exec start-hyprland
fi

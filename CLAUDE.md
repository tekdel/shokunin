# CLAUDE.md - Project Guide for AI Assistants

This document provides context for AI assistants working on the Shokunin project.

## Project Overview

**Shokunin** is an automated Arch Linux installer that provides a complete, ready-to-use system from bare metal. It features full-disk LUKS2 encryption, Hyprland window manager, and a modular package installation system.

**Reference**: This project is inspired by [Omarchy Linux](https://github.com/basecamp/omarchy) by DHH/Basecamp. When implementing new features or fixing issues, check how Omarchy handles similar functionality.

## Architecture

```
shokunin/
├── boot.sh                 # Main entry point - orchestrates entire installation
├── run                     # Package manager - executes scripts in runs/
├── update                  # System update script for existing installations
├── VERSION                 # Version tracking (bump with every commit)
│
├── install/                # Phase 1: Core system installation (runs in chroot)
│   ├── 01-disk.sh          # Disk partitioning, LUKS encryption
│   ├── 02-base.sh          # Pacstrap base packages, microcode, graphics drivers
│   ├── 02.5-initramfs.sh   # mkinitcpio with encrypt hook
│   ├── 03-bootloader.sh    # Limine bootloader setup
│   ├── 04-users.sh         # User creation, sudo, locale, timezone
│   └── 05-plymouth.sh      # Plymouth boot splash theme
│
├── runs/                   # Phase 2: Package installation (runs via ./run)
│   ├── 00-essential        # Core packages, graphics drivers, network config
│   ├── 10-hyprland         # Window manager, Waybar, Walker launcher
│   ├── 20-terminal         # Alacritty, Zsh, tmux, CLI tools
│   ├── 30-dev              # Development tools, mise, languages
│   ├── 40-apps             # Applications (zen-browser, nautilus, etc.)
│   ├── 50-docker           # Container runtime
│   ├── 60-audio            # Audio system (pipewire/pulseaudio)
│   ├── 70-cups             # Printing support
│   ├── 80-fonts            # Font packages
│   ├── 90-dotfiles         # Copy configs, bootstrap lazy.nvim
│   └── 99-fixes            # Final system fixes and configurations
│
├── dotfiles/               # User configuration files
│   ├── hypr/               # Hyprland, hyprlock, hypridle configs
│   ├── waybar/             # Status bar config and styling
│   ├── alacritty/          # Terminal emulator config
│   ├── nvim/               # Neovim config (kickstart-based)
│   ├── zsh/                # .zshrc, .zprofile
│   ├── tmux/               # tmux.conf
│   ├── git/                # .gitconfig, .gitignore_global
│   ├── kanshi/             # Monitor hotplug configuration
│   └── bin/                # Custom scripts (tmux-sessionizer, etc.)
│
├── plymouth/               # Custom boot splash theme
│   └── shokunin/           # Theme files (shokunin.plymouth, shokunin.script)
│
├── lib/                    # Shared utilities
│   └── common.sh           # Bash functions, logging, colors
│
├── config/                 # Default configuration
│   └── system.conf         # Default values (overridden during install)
│
└── scripts/                # Standalone fix scripts (legacy)
```

## Installation Flow

1. **boot.sh** downloads/verifies repo, prompts for config (disk, passwords, etc.)
2. **install/01-disk.sh** - Partitions disk, sets up LUKS encryption
3. **install/02-base.sh** - Runs pacstrap with base packages + drivers
4. **install/02.5-initramfs.sh** - Configures mkinitcpio with encrypt hook
5. **install/03-bootloader.sh** - Installs Limine bootloader
6. **install/04-users.sh** - Creates user, sets passwords, configures sudo
7. **install/05-plymouth.sh** - Installs Plymouth theme, SDDM drop-in
8. **boot.sh** enables multilib, installs paru (AUR helper)
9. **./run** executes all scripts in runs/ directory (alphabetically by filename)
10. **boot.sh** clones repo to ~/projects/shokunin, cleans up

## Key Components

### Run Scripts (runs/)

Scripts are prefixed with numbers to control execution order. They run as the target user with sudo access.

| Script | Purpose |
|--------|---------|
| 00-essential | Graphics drivers, network (iwd, systemd-networkd), polkit rules |
| 10-hyprland | Hyprland, Waybar, Walker, SDDM, xdg-desktop-portal |
| 20-terminal | Alacritty, Zsh, Oh-My-Zsh, fzf, ripgrep, tmux |
| 30-dev | Build tools, mise, Node.js, Python, Rust, Go |
| 40-apps | zen-browser, nautilus, mpv, keepassxc |
| 50-docker | Docker, docker-compose, lazydocker |
| 60-audio | Audio packages |
| 70-cups | Printing support |
| 80-fonts | Nerd fonts, system fonts |
| 90-dotfiles | Copy configs to ~/.config, bootstrap lazy.nvim |
| 99-fixes | Final fixes, service enablement, Plymouth config |

### Fixes Script (runs/99-fixes)

The fixes script handles:
- Multilib repository enablement
- Graphics driver installation
- Locale generation
- Polkit rules for iwd/bluetooth
- iwd DHCP configuration
- systemd-networkd for ethernet
- Console font configuration
- Pacman keyring fixes
- Plymouth theme and SDDM smooth transition
- Service enablement (iwd, bluetooth, power-profiles-daemon)

### Install Scripts (install/)

These run as root during the chroot phase:
- **01-disk.sh**: LUKS2 encryption, partitioning, swap with keyfile
- **02-base.sh**: pacstrap with base, drivers, microcode
- **02.5-initramfs.sh**: mkinitcpio HOOKS configuration
- **03-bootloader.sh**: Limine with encryption parameters
- **04-users.sh**: User setup, sudo, locale, timezone
- **05-plymouth.sh**: Plymouth theme, SDDM plymouth-quit-wait drop-in

## Hardware Support

Currently optimized for:
- **Lenovo ThinkPad Z13** (AMD Ryzen, Radeon graphics)
- **Framework Laptop** (Intel or AMD variants)

Graphics drivers installed:
- mesa, vulkan-radeon, vulkan-intel
- libva-mesa-driver, intel-media-driver
- amd-ucode, intel-ucode

## Key Design Decisions

1. **Limine over GRUB/systemd-boot**: Simpler, supports encryption natively
2. **iwd + systemd-networkd**: Lightweight alternative to NetworkManager
3. **Plymouth with SDDM drop-in**: Smooth boot transition
4. **Hyprland**: Modern Wayland compositor, minimal dependencies
5. **Walker + elephant**: App launcher (same as Omarchy)
6. **mise**: Language version manager (Node.js, Python)
7. **Paru**: AUR helper for community packages

## Development Guidelines

### Commits
- **Always bump version** in BOTH files with every commit:
  - `VERSION`
  - `boot.sh` (VERSION variable)
- **No Claude references** in commit messages - do not mention AI assistance
- Write clear, descriptive commit messages focused on what changed

### Testing
Use `test-vm.sh` for VM testing:
```bash
./test-vm.sh setup    # Create VM disk
./test-vm.sh install  # Boot installer
./test-vm.sh boot     # Boot installed system
./test-vm.sh clean    # Clean up
```

### Adding New Packages
1. Add to appropriate runs/ script
2. Use `sudo pacman -S --needed --noconfirm` for official packages
3. Use `paru -S --needed --noconfirm --skipreview` for AUR packages

### Adding System Fixes
1. Add fix to `runs/99-fixes` for existing systems
2. If needed during install, also add to appropriate `install/*.sh` script

## Common Issues

- **"module lazy not found"**: lazy.nvim not bootstrapped - run `runs/90-dotfiles`
- **No ethernet**: systemd-networkd not configured - run `runs/99-fixes`
- **Plymouth shows rectangles**: Font issue - use ASCII characters in theme
- **Flash before login**: SDDM needs plymouth-quit-wait drop-in

## Reference Projects

- **Omarchy**: https://github.com/basecamp/omarchy
  - Check their install scripts for implementation patterns
  - Walker/elephant launcher configuration
  - Plymouth and SDDM integration approaches

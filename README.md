# Shokunin

Automated Arch Linux installer with Hyprland, full-disk encryption, and a complete development environment.

**One command takes you from bare metal to a fully configured system.**

## Features

- **Full-disk LUKS2 encryption** with encrypted swap
- **Hyprland** tiling window manager (Wayland)
- **Complete development environment** out of the box
- **Laptop optimized** - lid close, power management, brightness
- **Network printer discovery** via Avahi/mDNS
- **USB automounting** with NTFS/exFAT support
- **Screenshot & screen recording** built-in
- **Modular design** - easy to customize

## Quick Start

### Fresh Installation (From Arch ISO)

```bash
# 1. Boot Arch ISO and connect to internet
# 2. Run:
curl -fsSL https://raw.githubusercontent.com/tekdel/shokunin/master/boot.sh | bash
```

You'll be prompted for:
- Disk to install on
- Hostname, username, passwords
- Encryption password
- Timezone and swap size

Installation takes ~20-30 minutes. Reboot and enjoy!

### Update Existing System

```bash
cd ~/projects/shokunin
git pull
./update           # Update everything
./update dotfiles  # Update configs only
./update --dry     # Preview changes
```

## What's Installed

### Desktop Environment

| Tool | Description | Keybinding |
|------|-------------|------------|
| **Hyprland** | Tiling Wayland compositor | - |
| **Waybar** | Status bar | - |
| **Walker** | Application launcher | `Super+R` |
| **Mako** | Notifications | - |
| **Hyprlock** | Screen locker | `Super+L` |
| **Hypridle** | Idle manager (auto-lock, suspend) | - |
| **Kanshi** | Monitor hotplug | - |

### Terminal & Shell

| Tool | Description |
|------|-------------|
| **Alacritty** | GPU-accelerated terminal |
| **Zsh** | Shell with Oh-My-Zsh |
| **tmux** | Terminal multiplexer |
| **Starship** | Shell prompt |
| **fzf** | Fuzzy finder |
| **ripgrep** | Fast grep |
| **fd** | Fast find |
| **bat** | cat with syntax highlighting |
| **eza** | Modern ls |
| **zoxide** | Smart cd |

### Development

| Tool | Description |
|------|-------------|
| **Neovim** | Editor (Kickstart + lazy.nvim) |
| **mise** | Version manager (Node.js, Python) |
| **Docker** | Containers + docker-compose |
| **lazydocker** | Docker TUI |
| **lazygit** | Git TUI |
| **Git** | Version control |
| **GCC/Clang** | C/C++ compilers |
| **Rust** | Via rustup |
| **Go** | Golang |

### Applications

| Tool | Description |
|------|-------------|
| **Zen Browser** | Privacy-focused browser |
| **Nautilus** | File manager |
| **mpv** | Video player |
| **imv** | Image viewer |
| **Zathura** | PDF viewer |
| **KeePassXC** | Password manager |
| **Spotify** | Music |
| **DBeaver** | Database client |

### System

| Feature | Implementation |
|---------|----------------|
| **Bootloader** | Limine with Plymouth splash |
| **Networking** | systemd-networkd (Ethernet) |
| **DNS** | systemd-resolved (1.1.1.1, 8.8.8.8) |
| **Audio** | PipeWire + WirePlumber |
| **Bluetooth** | BlueZ + bluetui (TUI) |
| **WiFi** | iwd + impala (TUI) |
| **Printing** | CUPS + Avahi (network discovery) |
| **USB** | udisks2 + gvfs (automount) |
| **Filesystems** | NTFS, exFAT support |
| **Thumbnails** | ffmpegthumbnailer |

## Keybindings

### Window Management

| Key | Action |
|-----|--------|
| `Super+Return` | Open terminal |
| `Super+Q` | Close window |
| `Super+R` | App launcher |
| `Super+E` | File manager |
| `Super+F` | Fullscreen |
| `Super+V` | Toggle floating |
| `Super+1-0` | Switch workspace |
| `Super+Shift+1-0` | Move window to workspace |
| `Super+H/J/K/L` | Move focus (vim keys) |

### System

| Key | Action |
|-----|--------|
| `Super+L` | Lock screen |
| `Super+Shift+E` | Power menu |
| `Super+Shift+B` | Open browser |
| `Super+Shift+A` | Audio mixer |
| `Super+C` | Clipboard history |

### Media

| Key | Action |
|-----|--------|
| `Print` | Screenshot (select area) |
| `Shift+Print` | Screenshot (fullscreen) |
| `Super+Print` | Screenshot to clipboard |
| `Super+Shift+R` | Toggle screen recording |
| `XF86Audio*` | Volume controls |
| `XF86MonBrightness*` | Brightness controls |

### Files

| Location | Content |
|----------|---------|
| `~/pictures/screenshots/` | Screenshots |
| `~/videos/recordings/` | Screen recordings |

## Hardware Support

Optimized for:
- **Lenovo ThinkPad Z13** (AMD Ryzen)
- **Framework Laptop** (Intel/AMD)

Includes drivers for:
- AMD graphics (mesa, vulkan-radeon)
- Intel graphics (vulkan-intel, intel-media-driver)
- 32-bit libraries for Steam/Wine

## System Behavior

| Event | Action |
|-------|--------|
| Lid close | Suspend |
| Idle 5 min | Lock screen |
| Idle 6 min | Display off |
| Idle 15 min | Suspend |
| Shutdown | 5 second timeout |
| CapsLock | Remapped to Escape |

## Customization

### Adding Packages

```bash
# Edit the appropriate script
vim runs/40-apps

# Add your package and run
./run
```

### Modifying Configs

```bash
# Edit dotfiles
vim dotfiles/hypr/hyprland.conf

# Apply changes
./update dotfiles

# Reload Hyprland
hyprctl reload
```

### Creating New Categories

```bash
cat > runs/45-gaming <<'EOF'
#!/bin/bash
sudo pacman -S --needed --noconfirm steam lutris
EOF
chmod +x runs/45-gaming
./run
```

## Repository Structure

```
shokunin/
├── boot.sh           # Main installer
├── run               # Package manager
├── update            # System updater
├── install/          # Installation scripts (disk, base, bootloader, users)
├── runs/             # Package scripts (00-essential, 10-hyprland, etc.)
├── dotfiles/         # Configuration files
│   ├── hypr/         # Hyprland config
│   ├── waybar/       # Status bar
│   ├── alacritty/    # Terminal
│   ├── nvim/         # Neovim
│   ├── swappy/       # Screenshot config
│   └── bin/          # Custom scripts
└── plymouth/         # Boot splash theme
```

## Testing in VM

```bash
./test-vm.sh install  # Create VM and boot ISO
./test-vm.sh boot     # Boot installed system
./test-vm.sh clean    # Clean up
```

## Troubleshooting

| Problem | Solution |
|---------|----------|
| Installation fails | Check disk with `lsblk`, verify UEFI mode |
| No WiFi | Run `iwctl` to connect manually |
| Hyprland won't start | Check `journalctl -xe` |
| No sound | Run `systemctl --user restart pipewire` |
| USB not mounting | Check `systemctl status udisks2` |

## Credits

This project draws inspiration from:
- **Omarchy** by DHH/Basecamp - for the opinionated Arch + Hyprland approach
- **ThePrimeagen** - for tmux-sessionizer and terminal workflow ideas

## License

MIT

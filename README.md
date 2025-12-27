# Arch Linux Minimal Installer

A modular, maintainable Arch Linux installation system with Hyprland. Inspired by [Omarchy](https://omarchy.org/) and [ThePrimeagen's dev setup](https://github.com/ThePrimeagen/dev).

**One command installs everything:** disk partitioning, base Arch, Hyprland, your dotfiles, and all your packages.

## Features

- ✅ **Automated installation** - One command from bare metal to working system
- ✅ **Modular design** - Each component in its own script
- ✅ **Easy to maintain** - Add packages by editing simple scripts
- ✅ **Your dotfiles included** - Everything in one repository
- ✅ **Safe testing** - VM testing script included
- ✅ **Minimal bloat** - Only ~50-70 packages (vs Omarchy's 144+)
- ✅ **No complex migrations** - Simple git-based updates

## What's Included

- **Window Manager:** Hyprland with full ecosystem
- **Terminal:** Alacritty + modern CLI tools (bat, eza, fzf, ripgrep, etc.)
- **Shell:** Zsh with Oh My Zsh
- **Browser:** Zen Browser
- **Boot:** Limine bootloader + Plymouth splash screen (Omarchy-style)
- **Security:** LUKS2 full-disk encryption (required)
- **Services:** Docker, CUPS (printing)
- **Development:** Git, Neovim, mise, multiple language toolchains
- **Your dotfiles:** Hyprland, Waybar, Alacritty, tmux configs included

## Repository Structure

```
.
├── boot.sh                      # Entry point - run this to install
├── run                          # Package installer/updater
├── test-vm.sh                   # VM testing helper
│
├── config/
│   └── system.conf             # System settings (timezone, hostname, etc.)
│
├── install/                     # Fresh installation scripts
│   ├── 01-disk.sh              # Disk partitioning
│   ├── 02-base.sh              # Base Arch installation
│   ├── 03-bootloader.sh        # Bootloader setup
│   └── 04-users.sh             # User creation
│
├── runs/                        # Modular package scripts
│   ├── essential               # Core system packages
│   ├── hyprland                # Hyprland window manager
│   ├── terminal                # Terminal tools
│   ├── docker                  # Docker setup
│   ├── cups                    # Printing support
│   ├── dev                     # Development tools
│   ├── apps                    # Applications
│   └── fonts                   # Fonts
│
├── dotfiles/                    # Your configuration files
│   ├── hypr/                   # Hyprland config
│   ├── waybar/                 # Status bar config
│   ├── alacritty/              # Terminal config
│   ├── bash/                   # Shell config
│   └── git/                    # Git config
│
└── lib/
    └── common.sh               # Shared utilities
```

## Quick Start

### Fresh Installation (From Arch ISO)

1. **Boot Arch ISO**
2. **Connect to internet** (if needed)
3. **Run installer:**

```bash
# One command - works on both real hardware and VM:
curl -L https://raw.githubusercontent.com/tekdel/shokunin/main/boot.sh | bash
```

The script will automatically:
- Try to clone from GitHub (if repository is public)
- Fall back to local HTTP server (for VM testing)
- Download and extract the full repository
- Start the installation process

4. **Answer prompts:**
   - Which disk to use
   - Hostname
   - Username & password
   - Timezone
   - Swap size (default: 32GB)

5. **Wait 20-30 minutes**
6. **Reboot into your new system!**

### On Existing System

```bash
# Clone repository
git clone https://github.com/tekdel/shokunin ~/shokunin
cd ~/shokunin

# Install everything
./run

# Or install specific components
./run hyprland terminal
./run --dry              # Dry run to see what would install
```

## Testing in VM (Recommended!)

Before installing on real hardware, test in a virtual machine:

```bash
# Terminal 1: Prepare tarball and start HTTP server
cd /path/to/shokunin
./prepare-vm-test.sh
cd /tmp && python -m http.server 8000

# Terminal 2: Start VM from Arch ISO
./test-vm.sh install

# Inside VM: Run the same command as real hardware
curl -L http://10.0.2.2:8000/boot.sh | bash

# After installation, boot into the system
./test-vm.sh boot

# Clean up when done
./test-vm.sh clean
```

**Same command works everywhere** - the script automatically detects whether to download from GitHub (real hardware) or local HTTP server (VM testing).

## Managing Your System

### Adding Packages

Edit the appropriate script in `runs/`:

```bash
# Want to add a terminal tool?
vim runs/terminal

# Add to the list:
#   neofetch \

# Install it
./run terminal
```

### Removing Packages

```bash
# Remove from the script
vim runs/apps

# Remove from system
sudo pacman -Rns package-name
```

### Creating New Categories

```bash
# Create new script
cat > runs/gaming <<'EOF'
#!/bin/bash
sudo pacman -S --needed --noconfirm steam lutris
EOF

chmod +x runs/gaming

# Install
./run gaming
```

### Updating Dotfiles

```bash
# Edit dotfiles
vim dotfiles/hypr/hyprland.conf

# Apply changes
cp -r dotfiles/hypr ~/.config/

# Reload Hyprland
hyprctl reload

# Commit changes
git add dotfiles/hypr/hyprland.conf
git commit -m "Update Hyprland config"
git push
```

### System Updates

```bash
# Regular Arch updates
sudo pacman -Syu

# Update this installer
cd ~/shokunin
git pull
```

## Customization

### Before Installation

1. **Fork this repository**
2. **Edit `config/system.conf`** - Set your preferences
3. **Edit `runs/*` scripts** - Add/remove packages
4. **Add your dotfiles** - Put your configs in `dotfiles/`
5. **Update `boot.sh`** - Change REPO_URL to your fork
6. **Test in VM!**

### Package Categories

| Script | Purpose | Key Packages |
|--------|---------|--------------|
| `essential` | Core system | base-devel, git, vim, neovim, plymouth |
| `hyprland` | Window manager | hyprland, waybar, rofi, mako |
| `terminal` | CLI tools | alacritty, zsh, oh-my-zsh, bat, eza, fzf, ripgrep, tmux |
| `docker` | Containers | docker, docker-compose, lazydocker |
| `cups` | Printing | cups, system-config-printer |
| `dev` | Development | python, nodejs, rust, go, mise |
| `apps` | Applications | zen-browser, nautilus, mpv, keepassxc |
| `fonts` | Fonts | JetBrains Mono, Nerd Fonts |

## What Makes This Different

### vs Omarchy

| Feature | Omarchy | This Installer |
|---------|---------|----------------|
| Packages | 144+ packages | ~60-80 packages (minimal) |
| Customization | Complex theme system | Simple dotfiles |
| Updates | Custom migration system | Standard git + pacman |
| Maintenance | Update through Omarchy system | Edit scripts directly |
| Bloat | Many apps pre-installed | Only essentials |
| Control | Opinionated defaults | Full control |
| Plymouth | ✅ bgrt theme | ✅ Same (bgrt theme) |
| Shell | Zsh | ✅ Zsh + Oh My Zsh |

### vs ThePrimeagen's Setup

| Feature | ThePrimeagen | This Installer |
|---------|--------------|----------------|
| Scope | Assumes system exists | Full system install |
| Disk setup | N/A | Automated partitioning |
| Bootloader | N/A | Automated |
| User creation | N/A | Automated |
| Design | Modular runs/ pattern | Same modular pattern ✅ |

## Usage Examples

### Example 1: Minimal Desktop

```bash
./run essential hyprland terminal fonts
```

### Example 2: Development Machine

```bash
./run essential hyprland terminal dev docker fonts
```

### Example 3: Full Setup

```bash
./run  # Installs everything
```

### Example 4: Dry Run

```bash
./run --dry docker  # See what docker script does
```

## Troubleshooting

### Installation fails during disk setup

- Check disk path is correct (`lsblk`)
- Make sure disk is not mounted
- Verify UEFI vs BIOS mode

### Package installation fails

- Check internet connection
- Update mirrors: `reflector --latest 20 --protocol https --sort rate --save /etc/pacman.d/mirrorlist`
- Try again: `./run <category>`

### Hyprland won't start

- Check if installed: `pacman -Q hyprland`
- Check logs: `journalctl -xe`
- Verify dotfiles are in place: `ls ~/.config/hypr/`

### AUR helper (paru) issues

- Reinstall: `cd /tmp && git clone https://aur.archlinux.org/paru.git && cd paru && makepkg -si`

## Contributing

This is your personal installer! Customize it however you want.

1. Fork the repository
2. Make your changes
3. Test in VM
4. Use it!

## Credits

- Inspired by [Omarchy](https://omarchy.org/) by DHH
- Modular design from [ThePrimeagen's dev setup](https://github.com/ThePrimeagen/dev)
- Built for minimal, maintainable Arch Linux installations

## License

MIT - Do whatever you want with it!

---

**Happy installing!** 🚀

For questions or issues, check the scripts - they're simple bash and well-commented.

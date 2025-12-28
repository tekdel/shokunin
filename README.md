# Arch Linux Minimal Installer

Automated Arch Linux installation with Hyprland, full-disk encryption, and your dotfiles.

**One command installs everything:** disk partitioning, base system, Hyprland, and all your packages.

## Features

- **Automated installation** - One command from bare metal to working system
- **Modular design** - Each component in its own script
- **Full-disk encryption** - LUKS2 encryption (required)
- **Your dotfiles included** - Everything in one repository
- **Easy to maintain** - Add packages by editing simple scripts
- **VM testing** - Test safely before installing on real hardware

## What's Included

- **Window Manager:** Hyprland with Waybar, Rofi, and Mako
- **Terminal:** Alacritty with modern CLI tools
- **Shell:** Zsh with Oh My Zsh
- **Browser:** Zen Browser
- **Boot:** Limine bootloader with Plymouth splash screen
- **Kernels:** Both stable and LTS kernels
- **Development:** Neovim, mise, Git, Docker
- **Your dotfiles:** Hyprland, Waybar, Alacritty, tmux, and more

## Quick Start

### Installation (From Arch ISO)

1. **Boot Arch ISO**
2. **Connect to internet** (if needed)
3. **Run installer:**

```bash
curl -fsSL https://raw.githubusercontent.com/tekdel/shokunin/master/boot.sh | bash
```

4. **Answer prompts:**
   - Disk to use (auto-detected)
   - Hostname
   - Username & password
   - Encryption password
   - Timezone (default: America/Los_Angeles)
   - Swap size (default: 32GB)

5. **Wait 20-30 minutes**
6. **Reboot and enjoy!**

### On Existing System

```bash
git clone https://github.com/tekdel/shokunin ~/shokunin
cd ~/shokunin

# Install everything
./run

# Or install specific components
./run hyprland terminal
```

### Updating an Existing System

After installing via `boot.sh`, use the `update` script to keep your system synchronized with the repository:

```bash
cd ~/projects/shokunin
git pull  # Get latest changes

# Preview what would change
./update --dry

# Update everything (packages + dotfiles)
./update

# Update only packages
./update packages

# Update only dotfiles
./update dotfiles
```

The `update` script safely:
- ✅ Updates packages via `./run`
- ✅ Synchronizes dotfiles from `dotfiles/` to `~/.config/` and `~/`
- ✅ Is idempotent and safe to run multiple times
- ❌ Never touches UEFI, bootloader, disk partitioning, or encryption

## Testing in VM

Before installing on real hardware, test in a VM:

```bash
# Install UEFI firmware
sudo pacman -S edk2-ovmf

# Start VM
./test-vm.sh install

# Inside VM - same command as real hardware
curl -fsSL https://raw.githubusercontent.com/tekdel/shokunin/master/boot.sh | bash

# After installation
./test-vm.sh boot

# Clean up
./test-vm.sh clean
```

## Managing Your System

### Adding Packages

```bash
# Edit the appropriate script
vim runs/terminal

# Add your package
# Install it
./run terminal
```

### Creating New Categories

```bash
# Create new script
cat > runs/gaming <<'EOF'
#!/bin/bash
sudo pacman -S --needed --noconfirm steam
EOF

chmod +x runs/gaming
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

# Commit
git add dotfiles/
git commit -m "Update config"
git push
```

## Package Categories

| Script | Purpose |
|--------|---------|
| `essential` | Core system packages |
| `hyprland` | Window manager and components |
| `terminal` | CLI tools and shell |
| `docker` | Container tools |
| `cups` | Printing support |
| `dev` | Development tools |
| `apps` | Applications |
| `fonts` | Fonts |

## Customization

### Before Installation

1. Fork this repository
2. Edit `config/system.conf` for defaults
3. Edit `runs/*` scripts to add/remove packages
4. Add your dotfiles to `dotfiles/`
5. Update REPO_URL in `boot.sh` to your fork
6. Test in VM

## Repository Structure

```
.
├── boot.sh              # Installation entry point
├── run                  # Package manager
├── test-vm.sh           # VM testing
│
├── config/
│   └── system.conf      # System defaults
│
├── install/             # Installation scripts
│   ├── 01-disk.sh       # Disk partitioning
│   ├── 02-base.sh       # Base system
│   ├── 03-bootloader.sh # Bootloader
│   └── 04-users.sh      # User creation
│
├── runs/                # Package scripts
│   ├── essential
│   ├── hyprland
│   ├── terminal
│   └── ...
│
└── dotfiles/            # Your configs
    ├── hypr/
    ├── waybar/
    ├── nvim/
    └── ...
```

## Troubleshooting

**Installation fails:**
- Check disk path with `lsblk`
- Verify UEFI firmware for VM: `sudo pacman -S edk2-ovmf`

**Package installation fails:**
- Check internet connection
- Update mirrors: `sudo pacman -Sy`

**Hyprland won't start:**
- Check logs: `journalctl -xe`
- Verify config: `ls ~/.config/hypr/`

## License

MIT

---

**Questions?** The scripts are simple bash - just read them!

# Dotfiles

This directory contains your personal dotfiles that will be copied to your home directory during installation.

## Structure

```
dotfiles/
├── hypr/           → ~/.config/hypr/
├── waybar/         → ~/.config/waybar/
├── alacritty/      → ~/.config/alacritty/
├── nvim/           → ~/.config/nvim/
├── bash/           → ~/
└── git/            → ~/
```

## Usage

### During Installation

The `boot.sh` script automatically copies these dotfiles to your home directory.

### After Installation

To update your dotfiles on an existing system:

```bash
cd ~/arch-minimal

# Copy specific config
cp -r dotfiles/hypr ~/.config/

# Or copy all configs
cp -r dotfiles/hypr ~/.config/
cp -r dotfiles/waybar ~/.config/
cp -r dotfiles/alacritty ~/.config/
cp dotfiles/bash/.bashrc ~/
```

## Customization

Add your own dotfiles here! The installer will copy everything from this directory.

**Examples:**
- `hypr/hyprland.conf` - Hyprland keybindings and settings
- `waybar/config` - Waybar modules and layout
- `waybar/style.css` - Waybar styling
- `alacritty/alacritty.toml` - Terminal configuration
- `bash/.bashrc` - Bash shell configuration
- `git/.gitconfig` - Git configuration

## Tips

- Keep your dotfiles in version control
- Use this repo as your dotfiles repo
- Commit changes and push to keep them synced
- Test changes in the VM before applying to your main system

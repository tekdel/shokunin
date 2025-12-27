#!/bin/bash
# boot.sh - Main entry point for fresh Arch Linux installation
# Usage (real hardware): curl -L https://raw.githubusercontent.com/tekdel/shokunin/main/boot.sh | bash
# Usage (VM testing):    curl -L http://10.0.2.2:8000/boot.sh | bash

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log() { echo -e "${GREEN}[+]${NC} $1"; }
error() { echo -e "${RED}[!]${NC} $1" >&2; exit 1; }
warn() { echo -e "${YELLOW}[*]${NC} $1"; }
success() { echo -e "${GREEN}[✓]${NC} $1"; }

# Banner
echo -e "${CYAN}"
cat << "EOF"
╔═══════════════════════════════════════════════════════════╗
║                                                           ║
║           Arch Linux Minimal Installer                   ║
║                                                           ║
╚═══════════════════════════════════════════════════════════╝
EOF
echo -e "${NC}"

# Check if running from Arch ISO
if [ ! -f /etc/arch-release ]; then
    error "This script must be run from Arch Linux installation media!"
fi

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    error "This script must be run as root"
fi

# Check internet connection
log "Checking internet connection..."
if ! ping -c 1 8.8.8.8 >/dev/null 2>&1; then
    error "No internet connection. Please connect to the internet first."
fi

# Repository configuration
REPO_URL="https://github.com/tekdel/shokunin.git"
TARBALL_URL_GITHUB="https://github.com/tekdel/shokunin/archive/refs/heads/master.tar.gz"
TARBALL_URL_LOCAL="http://10.0.2.2:8000/shokunin.tar.gz"
INSTALL_DIR="/root/shokunin"

# Check if already in repository directory
if [ -f "./config/system.conf" ] && [ -f "./lib/common.sh" ]; then
    INSTALL_DIR="$(pwd)"
    log "Running from local directory: $INSTALL_DIR"
elif [ -d "$INSTALL_DIR" ] && [ -f "$INSTALL_DIR/config/system.conf" ]; then
    log "Repository already exists at $INSTALL_DIR"
    cd "$INSTALL_DIR"
else
    # Need to download the repository
    log "Downloading repository..."

    # Try git clone first (for real hardware with GitHub access)
    if git clone "$REPO_URL" "$INSTALL_DIR" 2>/dev/null; then
        success "Repository cloned from GitHub"
        cd "$INSTALL_DIR"
    # Try downloading GitHub tarball
    elif curl -fsSL "$TARBALL_URL_GITHUB" -o /tmp/shokunin.tar.gz 2>/dev/null; then
        log "Downloading from GitHub as tarball..."
        mkdir -p "$INSTALL_DIR"
        tar xzf /tmp/shokunin.tar.gz -C "$INSTALL_DIR" --strip-components=1
        rm /tmp/shokunin.tar.gz
        success "Repository downloaded from GitHub"
        cd "$INSTALL_DIR"
    # Try local HTTP server (for VM testing)
    elif curl -fsSL "$TARBALL_URL_LOCAL" -o /tmp/shokunin.tar.gz 2>/dev/null; then
        log "Downloading from local HTTP server (VM testing mode)..."
        mkdir -p "$INSTALL_DIR"
        tar xzf /tmp/shokunin.tar.gz -C "$INSTALL_DIR"
        rm /tmp/shokunin.tar.gz
        success "Repository downloaded from local HTTP server"
        cd "$INSTALL_DIR"
    else
        error "Failed to download repository. Please either:

  1. Push your repository to GitHub and make it public

  2. For VM testing, start HTTP server:
     Terminal 1 (on host):
       cd /path/to/shokunin
       ./prepare-vm-test.sh
       cd /tmp && python -m http.server 8000

     Terminal 2 (on host):
       ./test-vm.sh install

     Inside VM:
       curl -L http://10.0.2.2:8000/boot.sh | bash

  3. Manually copy repository to $INSTALL_DIR and run ./boot.sh"
    fi
fi

# Source configuration
source ./config/system.conf
source ./lib/common.sh

# Interactive configuration
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}System Configuration${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Disk selection - auto-detect VM (vda) vs real hardware (sda)
warn "Available disks:"
lsblk -d -n -o NAME,SIZE,TYPE | grep disk
echo ""

# Auto-detect disk device
if [ -b "/dev/vda" ]; then
    # Running in VM (QEMU/KVM)
    DISK="/dev/vda"
    DISK_EXAMPLE="/dev/vda"
elif [ -b "/dev/sda" ]; then
    # Real hardware
    DISK="/dev/sda"
    DISK_EXAMPLE="/dev/sda"
elif [ -b "/dev/nvme0n1" ]; then
    # NVMe disk
    DISK="/dev/nvme0n1"
    DISK_EXAMPLE="/dev/nvme0n1"
else
    # Fallback - let user specify
    DISK_EXAMPLE="/dev/sda or /dev/vda"
fi

DISK=$(prompt "Enter disk to install to (e.g., $DISK_EXAMPLE)" "$DISK")

# Verify disk
if [ ! -b "$DISK" ]; then
    error "Disk $DISK not found!"
fi

# Hostname
HOSTNAME=$(prompt "Enter hostname" "$HOSTNAME")

# Username
USERNAME=$(prompt "Enter username" "$USERNAME")

# User password
USER_PASSWORD=$(prompt_password "Enter password for $USERNAME")

# Root password
ROOT_PASSWORD=$(prompt_password "Enter root password")

# Timezone
TIMEZONE=$(prompt "Enter timezone (e.g., Europe/Bucharest)" "$TIMEZONE")

# Swap size
echo ""
info "Swap partition configuration"
info "Recommended: 32G for systems with 16-32GB RAM"
info "Set to 0 to disable swap"
SWAP_SIZE=$(prompt "Enter swap size (e.g., 32G, 16G, or 0 for no swap)" "$SWAP_SIZE")

# Export for use in scripts
export DISK HOSTNAME USERNAME USER_PASSWORD ROOT_PASSWORD TIMEZONE SWAP_SIZE

echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}Configuration Summary${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "Disk:       ${GREEN}$DISK${NC}"
echo -e "Swap:       ${GREEN}$SWAP_SIZE${NC}"
echo -e "Encryption: ${GREEN}LUKS2 (required)${NC}"
echo -e "Hostname:   ${GREEN}$HOSTNAME${NC}"
echo -e "Username:   ${GREEN}$USERNAME${NC}"
echo -e "Timezone:   ${GREEN}$TIMEZONE${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

warn "This will ERASE ALL DATA on $DISK!"
warn "Full-disk encryption will be enabled"
warn "You will set an encryption password during installation"
warn "Press Ctrl+C now to cancel, or press Enter to continue..."
read -r

# Update system clock
sync_time

# Run installation scripts
log "Starting installation process..."
echo ""

# Phase 1: Disk setup and base system (run outside chroot)
run_script "./install/01-disk.sh"
run_script "./install/02-base.sh"

# Phase 2: System configuration (run inside chroot)
log "Entering chroot environment..."
arch-chroot /mnt /bin/bash <<CHROOT_EOF
set -e

cd /root/installer
source ./lib/common.sh
source ./config/system.conf

export HOSTNAME="$HOSTNAME"
export USERNAME="$USERNAME"
export USER_PASSWORD="$USER_PASSWORD"
export ROOT_PASSWORD="$ROOT_PASSWORD"
export TIMEZONE="$TIMEZONE"

run_script "./install/03-bootloader.sh"
run_script "./install/04-users.sh"

# Install paru (AUR helper)
install_aur_helper "$USERNAME"

# Run all package installation scripts as the user
log "Installing packages..."
sudo -u "$USERNAME" bash -c 'cd /root/installer && ./run'

# Copy dotfiles
if [ -d "/root/installer/dotfiles" ]; then
    log "Copying dotfiles..."
    cp -r /root/installer/dotfiles/. /home/$USERNAME/

    # Create .config if it doesn't exist
    mkdir -p /home/$USERNAME/.config

    # Copy config directories
    if [ -d "/root/installer/dotfiles/hypr" ]; then
        cp -r /root/installer/dotfiles/hypr /home/$USERNAME/.config/
    fi
    if [ -d "/root/installer/dotfiles/waybar" ]; then
        cp -r /root/installer/dotfiles/waybar /home/$USERNAME/.config/
    fi
    if [ -d "/root/installer/dotfiles/alacritty" ]; then
        cp -r /root/installer/dotfiles/alacritty /home/$USERNAME/.config/
    fi
    if [ -d "/root/installer/dotfiles/nvim" ]; then
        cp -r /root/installer/dotfiles/nvim /home/$USERNAME/.config/
    fi

    # Copy home directory files
    if [ -f "/root/installer/dotfiles/bash/.bashrc" ]; then
        cp /root/installer/dotfiles/bash/.bashrc /home/$USERNAME/
    fi
    if [ -f "/root/installer/dotfiles/bash/.bash_profile" ]; then
        cp /root/installer/dotfiles/bash/.bash_profile /home/$USERNAME/
    fi
    if [ -f "/root/installer/dotfiles/zsh/.zshrc" ]; then
        cp /root/installer/dotfiles/zsh/.zshrc /home/$USERNAME/
    fi
    if [ -f "/root/installer/dotfiles/git/.gitconfig" ]; then
        cp /root/installer/dotfiles/git/.gitconfig /home/$USERNAME/
    fi
    if [ -f "/root/installer/dotfiles/tmux/.tmux.conf" ]; then
        cp /root/installer/dotfiles/tmux/.tmux.conf /home/$USERNAME/
    fi
    if [ -f "/root/installer/dotfiles/.mise.toml" ]; then
        cp /root/installer/dotfiles/.mise.toml /home/$USERNAME/
    fi
    if [ -f "/root/installer/dotfiles/zsh/.zprofile" ]; then
        cp /root/installer/dotfiles/zsh/.zprofile /home/$USERNAME/
    fi

    # Copy bin directory to .local/bin
    if [ -d "/root/installer/dotfiles/bin" ]; then
        mkdir -p /home/$USERNAME/.local/bin
        cp -r /root/installer/dotfiles/bin/* /home/$USERNAME/.local/bin/
        chmod +x /home/$USERNAME/.local/bin/*
    fi

    # Configure tmux to use .config directory
    if [ -f "/home/$USERNAME/.tmux.conf" ]; then
        mkdir -p /home/$USERNAME/.config/tmux
        mv /home/$USERNAME/.tmux.conf /home/$USERNAME/.config/tmux/tmux.conf
    fi

    # Setup global gitignore
    if [ -f "/root/installer/dotfiles/git/.gitignore_global" ]; then
        cp /root/installer/dotfiles/git/.gitignore_global /home/$USERNAME/
        git config --global core.excludesfile ~/.gitignore_global
    fi

    # Fix permissions
    chown -R $USERNAME:$USERNAME /home/$USERNAME
    success "Dotfiles installed"
fi

# Configure Plymouth if installed
if pacman -Q plymouth >/dev/null 2>&1; then
    run_script "./install/05-plymouth.sh"
fi

# Enable services
for service in "\${ENABLE_SERVICES[@]}"; do
    if systemctl list-unit-files | grep -q "^\$service"; then
        log "Enabling \$service..."
        systemctl enable "\$service" || warn "Could not enable \$service"
    fi
done

# Copy installer to user's home for future use
log "Copying installer to /home/$USERNAME/shokunin..."
cp -r /root/installer /home/$USERNAME/shokunin
chown -R $USERNAME:$USERNAME /home/$USERNAME/shokunin

success "Installation complete!"

CHROOT_EOF

# Unmount
log "Unmounting filesystems..."
umount -R /mnt

echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}Installation Complete!${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "You can now reboot into your new system:"
echo -e "  ${GREEN}reboot${NC}"
echo ""
echo -e "After reboot:"
echo -e "  1. Log in with username: ${GREEN}$USERNAME${NC}"
echo -e "  2. Start Hyprland: ${GREEN}Hyprland${NC}"
echo -e "  3. Manage packages: ${GREEN}cd ~/shokunin && ./run${NC}"
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

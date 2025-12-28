#!/bin/bash
# boot.sh - Main entry point for fresh Arch Linux installation
# Usage: curl -fsSL https://raw.githubusercontent.com/tekdel/shokunin/master/boot.sh | bash

# If stdin is not a terminal (being piped from curl), re-exec with proper stdin
if [ ! -t 0 ]; then
    # Save script to temp file and re-exec with /dev/tty as stdin
    TEMP_SCRIPT=$(mktemp)
    cat > "$TEMP_SCRIPT"
    exec bash "$TEMP_SCRIPT" < /dev/tty
fi

set -e

# Version - increment with every commit
VERSION="1.3.5"

# Check for minimal install flag (bootloader test mode)
# Can be set via: ./boot.sh --minimal OR MINIMAL_INSTALL=true curl ... | bash
MINIMAL_INSTALL="${MINIMAL_INSTALL:-false}"
if [[ "$1" == "--minimal" ]] || [[ "$1" == "-m" ]]; then
    MINIMAL_INSTALL=true
fi

# Check for resume checkpoint
RESUME_FROM=""
if [[ "$1" == "--resume-from" ]] && [[ -n "$2" ]]; then
    RESUME_FROM="$2"
    log "Resuming from checkpoint: $RESUME_FROM"
fi

# Checkpoint helper function
checkpoint() {
    local name=$1
    echo "$name" > /mnt/root/.install_checkpoint
    log "Checkpoint: $name"
}

# Check if we should skip a step
should_skip() {
    local step=$1
    case "$RESUME_FROM" in
        "")
            return 1  # Don't skip, no resume point
            ;;
        "bootloader")
            [[ "$step" == "disk" || "$step" == "base" ]] && return 0 || return 1
            ;;
        "users")
            [[ "$step" == "disk" || "$step" == "base" || "$step" == "bootloader" ]] && return 0 || return 1
            ;;
        "packages")
            [[ "$step" == "disk" || "$step" == "base" || "$step" == "bootloader" || "$step" == "users" ]] && return 0 || return 1
            ;;
        *)
            return 1
            ;;
    esac
}

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
echo -e "${GREEN}Version: ${VERSION}${NC}"
echo ""

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
INSTALL_DIR="/root/shokunin"

# Check if already in repository directory
if [ -f "./config/system.conf" ] && [ -f "./lib/common.sh" ]; then
    INSTALL_DIR="$(pwd)"
    log "Running from local directory: $INSTALL_DIR"
elif [ -d "$INSTALL_DIR" ] && [ -f "$INSTALL_DIR/config/system.conf" ]; then
    log "Repository already exists at $INSTALL_DIR"
    cd "$INSTALL_DIR"
else
    # Need to download the repository from GitHub
    log "Downloading repository from GitHub..."

    # Try git clone first
    if git clone "$REPO_URL" "$INSTALL_DIR" 2>/dev/null; then
        success "Repository cloned from GitHub"
        cd "$INSTALL_DIR"
    # Try downloading GitHub tarball (fallback when git not available)
    elif curl -fsSL "$TARBALL_URL_GITHUB" -o /tmp/shokunin.tar.gz 2>/dev/null; then
        log "Downloading from GitHub as tarball..."
        mkdir -p "$INSTALL_DIR"
        tar xzf /tmp/shokunin.tar.gz -C "$INSTALL_DIR" --strip-components=1
        rm /tmp/shokunin.tar.gz
        success "Repository downloaded from GitHub"
        cd "$INSTALL_DIR"
    else
        error "Failed to download repository from GitHub.

Please ensure:
  1. Repository is public: https://github.com/tekdel/shokunin
  2. You have internet access
  3. The branch 'master' exists

Or manually copy repository to $INSTALL_DIR and run ./boot.sh"
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

# Encryption password
echo ""
CRYPT_PASSWORD=$(prompt_password "Enter disk encryption password")

# User password
echo ""
read -p "Use same password for user account? (Y/n): " same_password </dev/tty
if [[ "$same_password" =~ ^[Nn]$ ]]; then
    USER_PASSWORD=$(prompt_password "Enter password for $USERNAME")
else
    USER_PASSWORD="$CRYPT_PASSWORD"
    success "Using same password for user account"
fi

# Root password
echo ""
read -p "Use same password for root? (Y/n): " same_root </dev/tty
if [[ "$same_root" =~ ^[Nn]$ ]]; then
    ROOT_PASSWORD=$(prompt_password "Enter root password")
else
    ROOT_PASSWORD="$CRYPT_PASSWORD"
    success "Using same password for root"
fi

# Timezone
TIMEZONE=$(prompt "Enter timezone (e.g., America/Los_Angeles)" "$TIMEZONE")

# Export encryption password for disk script
export CRYPT_PASSWORD

# Swap size
echo ""
info "Swap partition configuration"
info "Recommended: 32G for systems with 16-32GB RAM"
info "Set to 0 to disable swap"
SWAP_SIZE=$(prompt "Enter swap size (e.g., 32G, 16G, or 0 for no swap)" "$SWAP_SIZE")

# Export for use in scripts
export DISK HOSTNAME USERNAME USER_PASSWORD ROOT_PASSWORD TIMEZONE SWAP_SIZE CRYPT_PASSWORD

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
warn "Full-disk encryption will be enabled (password already set)"
warn "Press Ctrl+C now to cancel, or press Enter to continue..."
read -r </dev/tty

# Update system clock
sync_time

# Run installation scripts
log "Starting installation process..."
echo ""

# Phase 1: Disk setup and base system (run outside chroot)
if ! should_skip "disk"; then
    # Ensure encryption password is exported for disk script
    export CRYPT_PASSWORD
    run_script "./install/01-disk.sh"
    checkpoint "disk"
fi

if ! should_skip "base"; then
    run_script "./install/02-base.sh"
    checkpoint "base"
fi

# Save passwords to files for chroot (env vars don't reliably pass through)
echo -n "$USER_PASSWORD" > /mnt/root/installer/.user_password
echo -n "$ROOT_PASSWORD" > /mnt/root/installer/.root_password
chmod 600 /mnt/root/installer/.user_password /mnt/root/installer/.root_password

# Phase 2: System configuration (run inside chroot)
log "Entering chroot environment..."
arch-chroot /mnt /bin/bash <<'CHROOT_EOF'
set -e

cd /root/installer
source ./lib/common.sh
source ./config/system.conf

# Import variables from parent environment
export HOSTNAME="$HOSTNAME"
export USERNAME="$USERNAME"
export TIMEZONE="$TIMEZONE"
export MINIMAL_INSTALL="$MINIMAL_INSTALL"

# Read passwords from files (more reliable than env vars)
export USER_PASSWORD="$(cat /root/installer/.user_password)"
export ROOT_PASSWORD="$(cat /root/installer/.root_password)"

# Configure initramfs with encryption support BEFORE bootloader
if ! should_skip "bootloader"; then
    run_script "./install/02.5-initramfs.sh"
    run_script "./install/03-bootloader.sh"
    echo "bootloader" > /root/.install_checkpoint
fi

if ! should_skip "users"; then
    run_script "./install/04-users.sh"
    echo "users" > /root/.install_checkpoint
fi

# Check if minimal install mode (stop here for bootloader testing)
if [ "\$MINIMAL_INSTALL" = "true" ]; then
    success "Minimal installation complete (bootloader only)!"
    echo ""
    echo "System ready for boot testing."
    echo "To complete full installation later, run: ./boot.sh --continue"
    exit 0
fi

# Install paru (AUR helper)
if ! should_skip "packages"; then
    # Enable passwordless sudo temporarily for package installation
    log "Configuring temporary passwordless sudo for installation..."
    echo "$USERNAME ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/temp-install
    chmod 440 /etc/sudoers.d/temp-install

    install_aur_helper "$USERNAME"

    # Run all package installation scripts as the user
    log "Installing packages..."
    sudo -u "$USERNAME" bash -c 'cd /root/installer && ./run'

    # Remove temporary passwordless sudo
    rm -f /etc/sudoers.d/temp-install
    log "Removed temporary passwordless sudo"

    echo "packages" > /root/.install_checkpoint
fi

# Copy dotfiles
if [ -d "/root/installer/dotfiles" ]; then
    log "Copying dotfiles..."

    # Create .config directory structure
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

# Install Hyprland session file for SDDM
log "Installing Hyprland session file for SDDM..."
if [ -f "/root/installer/dotfiles/hyprland.desktop" ]; then
    cp /root/installer/dotfiles/hyprland.desktop /usr/share/wayland-sessions/
fi

# Copy installer to user's projects folder
log "Creating projects directory..."
mkdir -p /home/$USERNAME/projects
cp -r /root/installer /home/$USERNAME/projects/shokunin
chown -R $USERNAME:$USERNAME /home/$USERNAME/projects

# Clean up password files
rm -f /root/installer/.user_password /root/installer/.root_password

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

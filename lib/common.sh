#!/bin/bash
# lib/common.sh - Shared utilities and functions

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Logging functions
log() {
    echo -e "${GREEN}[+]${NC} $1"
}

error() {
    echo -e "${RED}[!]${NC} $1" >&2
    exit 1
}

warn() {
    echo -e "${YELLOW}[*]${NC} $1"
}

info() {
    echo -e "${BLUE}[i]${NC} $1"
}

success() {
    echo -e "${GREEN}[✓]${NC} $1"
}

# Run a script and handle errors
run_script() {
    local script=$1
    local name=$(basename "$script")

    if [ ! -f "$script" ]; then
        error "Script not found: $script"
    fi

    log "Running: $name"
    if bash "$script"; then
        success "$name completed"
    else
        error "$name failed"
    fi
}

# Check if running as root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        error "This script must be run as root"
    fi
}

# Check if NOT running as root
check_not_root() {
    if [ "$EUID" -eq 0 ]; then
        error "This script should NOT be run as root"
    fi
}

# Check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Install package if not already installed
install_if_missing() {
    local pkg=$1
    if ! pacman -Q "$pkg" >/dev/null 2>&1; then
        log "Installing $pkg..."
        pacman -S --noconfirm "$pkg"
    else
        info "$pkg already installed"
    fi
}

# Prompt for user input with default value
prompt() {
    local prompt_text=$1
    local default_value=$2
    local result

    if [ -n "$default_value" ]; then
        read -p "$prompt_text [$default_value]: " result </dev/tty
        echo "${result:-$default_value}"
    else
        read -p "$prompt_text: " result </dev/tty
        echo "$result"
    fi
}

# Prompt for password (hidden input)
prompt_password() {
    local prompt_text=$1
    local password
    local password_confirm

    while true; do
        read -s -p "$prompt_text: " password </dev/tty
        echo
        read -s -p "Confirm password: " password_confirm </dev/tty
        echo

        if [ "$password" = "$password_confirm" ]; then
            echo "$password"
            return 0
        else
            warn "Passwords do not match. Try again."
        fi
    done
}

# Check if running in chroot
in_chroot() {
    [ "$(stat -c %d:%i /)" != "$(stat -c %d:%i /proc/1/root/.)" ]
}

# Check if we're on Arch Linux
check_arch() {
    if [ ! -f /etc/arch-release ]; then
        error "This script is designed for Arch Linux only"
    fi
}

# Sync time (important for package installation)
sync_time() {
    log "Syncing system time..."
    timedatectl set-ntp true
}

# Update pacman mirrorlist
update_mirrors() {
    log "Updating pacman mirrors..."
    reflector --latest 20 --protocol https --sort rate --save /etc/pacman.d/mirrorlist || warn "reflector not available, skipping mirror update"
}

# Enable multilib repository
enable_multilib() {
    log "Enabling multilib repository..."
    if ! grep -q "^\[multilib\]" /etc/pacman.conf; then
        cat >> /etc/pacman.conf <<EOF

[multilib]
Include = /etc/pacman.d/mirrorlist
EOF
        pacman -Sy
        success "Multilib enabled"
    else
        info "Multilib already enabled"
    fi
}

# Install AUR helper (paru)
install_aur_helper() {
    local user=$1

    if command_exists paru; then
        info "paru already installed"
        return 0
    fi

    log "Installing paru (AUR helper)..."

    # Install as regular user, not root
    sudo -u "$user" bash <<'EOF'
set -e
cd /tmp
git clone https://aur.archlinux.org/paru.git
cd paru
makepkg -si --noconfirm
cd ..
rm -rf paru
EOF

    success "paru installed"
}

# Export all functions
export -f log error warn info success
export -f run_script check_root check_not_root command_exists
export -f install_if_missing prompt prompt_password
export -f in_chroot check_arch sync_time update_mirrors
export -f enable_multilib install_aur_helper

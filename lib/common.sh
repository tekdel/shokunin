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
        echo "" >&2
        read -s -p "$prompt_text: " password </dev/tty
        echo >&2
        read -s -p "Confirm password: " password_confirm </dev/tty
        echo >&2

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

    if [ -z "$user" ]; then
        error "install_aur_helper: username not provided"
    fi

    log "Checking if paru is already installed..."
    if command_exists paru; then
        info "paru already installed, skipping"
        return 0
    fi

    log "Installing paru (AUR helper) for user: $user"

    # Pre-install build dependencies to avoid sudo prompts during makepkg
    log "Installing paru build dependencies..."
    pacman -S --needed --noconfirm rust git base-devel

    # Clean up any previous failed attempts
    rm -rf /tmp/paru

    # Install as regular user, not root
    log "Cloning paru from AUR..."
    if ! sudo -u "$user" git clone https://aur.archlinux.org/paru.git /tmp/paru; then
        error "Failed to clone paru repository"
    fi

    log "Building and installing paru (this may take a few minutes)..."
    # Note: "Failed to connect to bus/scope" warnings are expected in chroot (no systemd)
    # We check if paru is installed after regardless of makepkg exit code
    # Using -i only (not -s) since deps are pre-installed
    sudo -u "$user" bash -c 'cd /tmp/paru && makepkg -i --noconfirm' || true

    # Clean up
    rm -rf /tmp/paru

    # Verify installation
    if command_exists paru; then
        success "paru installed successfully"
    else
        error "paru installation failed - command not found after install"
    fi
}

# Wait for a block device to appear (with timeout)
wait_for_device() {
    local device=$1
    local timeout=${2:-30}
    local elapsed=0

    log "Waiting for device $device..."
    while [ ! -b "$device" ] && [ $elapsed -lt $timeout ]; do
        sleep 1
        elapsed=$((elapsed + 1))
    done

    if [ ! -b "$device" ]; then
        error "Device $device did not appear after ${timeout}s"
    fi
    success "Device $device is ready"
}

# Wait for device mapper device to appear
wait_for_mapper() {
    local name=$1
    local timeout=${2:-30}
    wait_for_device "/dev/mapper/$name" "$timeout"
}

# Validate timezone exists
validate_timezone() {
    local tz=$1
    if [ ! -f "/usr/share/zoneinfo/$tz" ]; then
        error "Invalid timezone: $tz (file not found: /usr/share/zoneinfo/$tz)"
    fi
}

# Validate locale format
validate_locale() {
    local locale=$1
    if [ -z "$locale" ]; then
        warn "LOCALE not set, defaulting to en_US.UTF-8"
        echo "en_US.UTF-8"
        return
    fi
    echo "$locale"
}

# Safe sed with verification
safe_sed() {
    local pattern=$1
    local file=$2
    local description=$3

    if [ ! -f "$file" ]; then
        error "File not found for sed: $file"
    fi

    local before=$(cat "$file")
    sed -i "$pattern" "$file"
    local after=$(cat "$file")

    if [ "$before" = "$after" ]; then
        warn "sed pattern '$pattern' made no changes to $file"
        if [ -n "$description" ]; then
            warn "Expected to: $description"
        fi
        return 1
    fi
    return 0
}

# Export all functions
export -f log error warn info success
export -f run_script check_root check_not_root command_exists
export -f install_if_missing prompt prompt_password
export -f in_chroot check_arch sync_time update_mirrors
export -f enable_multilib install_aur_helper
export -f wait_for_device wait_for_mapper validate_timezone validate_locale safe_sed

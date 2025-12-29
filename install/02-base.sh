#!/bin/bash
# install/02-base.sh - Install base Arch system

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

check_root

log "Installing base system..."

# Verify /mnt is mounted
if ! mountpoint -q /mnt; then
    error "/mnt is not mounted - run 01-disk.sh first"
fi

# Update mirrorlist if reflector is available
if command_exists reflector; then
    update_mirrors
else
    warn "reflector not available - using default mirrors"
fi

# Sync time
sync_time

# Install base system
log "Running pacstrap (this may take a while)..."
PACKAGES=(
    base
    linux
    linux-firmware
    base-devel
    git
    vim
    sudo
    reflector
    efibootmgr
    cryptsetup
    terminus-font
)

log "Installing packages: ${PACKAGES[*]}"
if ! pacstrap /mnt "${PACKAGES[@]}"; then
    error "pacstrap failed - check internet connection and package names"
fi
success "Base packages installed"

# Generate fstab
log "Generating fstab..."
if ! genfstab -U /mnt >> /mnt/etc/fstab; then
    error "Failed to generate fstab"
fi

# Verify fstab has content
if [ ! -s /mnt/etc/fstab ]; then
    error "fstab is empty - something went wrong with genfstab"
fi

# Show generated fstab for debugging
log "Generated fstab:"
cat /mnt/etc/fstab

# Copy installer to new system
log "Copying installer to new system..."
if ! cp -r "$SCRIPT_DIR/.." /mnt/root/installer; then
    error "Failed to copy installer to /mnt/root/installer"
fi

success "Base system installed!"

#!/bin/bash
# install/02-base.sh - Install base Arch system

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
source "$SCRIPT_DIR/../config/system.conf"

check_root

log "Installing base system..."

# Update mirrorlist if reflector is available
if command_exists reflector; then
    update_mirrors
fi

# Sync time
sync_time

# Install base system
log "Running pacstrap (this may take a while)..."
pacstrap /mnt \
    base \
    linux \
    linux-firmware \
    base-devel \
    networkmanager \
    git \
    vim \
    sudo \
    reflector

# Generate fstab
log "Generating fstab..."
genfstab -U /mnt >> /mnt/etc/fstab

# Copy installer to new system
log "Copying installer to new system..."
cp -r "$SCRIPT_DIR/.." /mnt/root/installer

success "Base system installed!"

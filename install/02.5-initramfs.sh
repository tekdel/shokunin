#!/bin/bash
# install/02.5-initramfs.sh - Configure initramfs for encryption
# This MUST run before bootloader installation

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

check_root

log "Configuring initramfs for encryption..."

# Verify mkinitcpio.conf exists
if [ ! -f /etc/mkinitcpio.conf ]; then
    error "/etc/mkinitcpio.conf not found - is base system installed?"
fi

# Backup original mkinitcpio.conf
if [ ! -f /etc/mkinitcpio.conf.original ]; then
    log "Backing up original mkinitcpio.conf..."
    cp /etc/mkinitcpio.conf /etc/mkinitcpio.conf.original
fi

# Configure HOOKS for encrypted system
# encrypt hook MUST be included for LUKS encryption support
log "Adding encryption support to initramfs..."

# Define the required hooks
REQUIRED_HOOKS="HOOKS=(base udev keyboard autodetect microcode modconf kms keymap consolefont block encrypt filesystems fsck)"

# Check if HOOKS line exists
if ! grep -q "^HOOKS=" /etc/mkinitcpio.conf; then
    warn "No HOOKS= line found in mkinitcpio.conf - adding it"
    echo "$REQUIRED_HOOKS" >> /etc/mkinitcpio.conf
else
    # Replace existing HOOKS line
    if ! sed -i "s/^HOOKS=.*/$REQUIRED_HOOKS/" /etc/mkinitcpio.conf; then
        error "Failed to update HOOKS in mkinitcpio.conf"
    fi
fi

# Verify the change was made
if ! grep -q "encrypt" /etc/mkinitcpio.conf; then
    error "Failed to add encrypt hook to mkinitcpio.conf"
fi

log "Current HOOKS configuration:"
grep "^HOOKS=" /etc/mkinitcpio.conf

# Regenerate initramfs with encryption support
log "Regenerating initramfs (this may take a moment)..."
if ! mkinitcpio -P; then
    error "mkinitcpio failed - check configuration"
fi

# Verify initramfs files were created
if [ ! -f /boot/initramfs-linux.img ]; then
    error "initramfs-linux.img was not created"
fi
if [ ! -f /boot/initramfs-linux-fallback.img ]; then
    warn "Fallback initramfs was not created"
fi

success "Initramfs configured with encryption support!"
log "Created:"
ls -lh /boot/initramfs-*.img

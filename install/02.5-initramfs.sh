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

# Note: NVIDIA modules are NOT added to MODULES= here.
# Early loading conflicts with Plymouth's LUKS password prompt.
# The kms hook + nvidia_drm.modeset=1 kernel param handle NVIDIA KMS instead.

# Ensure USB keyboard works at LUKS password prompt
# xhci_hcd and usbhid must be explicitly included - the keyboard hook
# alone may not pull them in reliably on all systems
log "Ensuring USB keyboard modules are in initramfs..."
if grep -q "^MODULES=" /etc/mkinitcpio.conf; then
    # Add USB modules if not already present
    if ! grep -q "usbhid" /etc/mkinitcpio.conf; then
        sed -i 's/^MODULES=(\(.*\))/MODULES=(\1 xhci_hcd usbhid)/' /etc/mkinitcpio.conf
        # Clean up double spaces if MODULES was empty
        sed -i 's/^MODULES=( /MODULES=(/' /etc/mkinitcpio.conf
    fi
fi

# Configure HOOKS for encrypted system
# encrypt hook MUST be included for LUKS encryption support
log "Adding encryption support to initramfs..."

# Define the required hooks
# Note: plymouth and plymouth-encrypt hooks are added by 05-plymouth.sh
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

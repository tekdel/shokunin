#!/bin/bash
# install/02.5-initramfs.sh - Configure initramfs for encryption
# This MUST run before bootloader installation

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

check_root

log "Configuring initramfs for encryption..."

# Backup original mkinitcpio.conf
if [ ! -f /etc/mkinitcpio.conf.original ]; then
    cp /etc/mkinitcpio.conf /etc/mkinitcpio.conf.original
fi

# Configure HOOKS for encrypted system
# encrypt hook MUST be included for LUKS encryption support
log "Adding encryption support to initramfs..."
sed -i 's/^HOOKS=.*/HOOKS=(base udev keyboard autodetect microcode modconf kms keymap consolefont block encrypt filesystems fsck)/' /etc/mkinitcpio.conf

# Regenerate initramfs with encryption support
log "Regenerating initramfs..."
mkinitcpio -P

success "Initramfs configured with encryption support!"

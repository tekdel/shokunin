#!/bin/bash
# install/05-plymouth.sh - Configure Plymouth boot splash (Omarchy-style)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

check_root

# Check if plymouth is installed
if ! pacman -Q plymouth >/dev/null 2>&1; then
    warn "Plymouth not installed, skipping configuration"
    exit 0
fi

log "Configuring Plymouth boot splash (Omarchy-style)..."

# Backup mkinitcpio.conf
cp /etc/mkinitcpio.conf /etc/mkinitcpio.conf.backup

# Configure HOOKS following Omarchy's approach
# HOOKS order: base udev plymouth keyboard autodetect microcode modconf kms keymap consolefont block filesystems fsck
# Plymouth must come BEFORE encrypt if using encryption, and AFTER udev
log "Configuring mkinitcpio hooks..."
sed -i 's/^HOOKS=.*/HOOKS=(base udev plymouth keyboard autodetect microcode modconf kms keymap consolefont block filesystems fsck)/' /etc/mkinitcpio.conf

# Set Plymouth theme (bgrt shows UEFI manufacturer logo)
log "Setting Plymouth theme..."
plymouth-set-default-theme -R bgrt 2>/dev/null || plymouth-set-default-theme bgrt

# Regenerate initramfs
log "Regenerating initramfs..."
mkinitcpio -P

success "Plymouth configured!"
log "Plymouth will display UEFI manufacturer logo during boot"

#!/bin/bash
# install/05-plymouth.sh - Configure Plymouth boot splash with custom Shokunin theme

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

check_root

# Check if plymouth is installed
if ! pacman -Q plymouth >/dev/null 2>&1; then
    warn "Plymouth not installed, skipping configuration"
    exit 0
fi

log "Installing custom Shokunin Plymouth theme..."

# Install required fonts for password prompt
pacman -S --needed --noconfirm ttf-dejavu 2>/dev/null || true

# Copy custom theme to system
THEME_DIR="/usr/share/plymouth/themes/shokunin"
mkdir -p "$THEME_DIR"

if [ -d "/root/installer/plymouth/shokunin" ]; then
    cp /root/installer/plymouth/shokunin/shokunin.plymouth "$THEME_DIR/"
    cp /root/installer/plymouth/shokunin/shokunin.script "$THEME_DIR/"
    success "Custom Shokunin theme installed"
else
    warn "Custom theme files not found, using default bgrt theme"
    plymouth-set-default-theme -R bgrt 2>/dev/null || plymouth-set-default-theme bgrt
    exit 0
fi

# Backup mkinitcpio.conf
cp /etc/mkinitcpio.conf /etc/mkinitcpio.conf.backup

# Add Plymouth hooks for graphical boot
# - plymouth must come AFTER udev but BEFORE encrypt
# - plymouth-encrypt replaces encrypt for graphical password prompt
log "Adding Plymouth to mkinitcpio hooks..."
sed -i 's/^HOOKS=(base udev /HOOKS=(base udev plymouth /' /etc/mkinitcpio.conf
sed -i 's/ encrypt / plymouth-encrypt /' /etc/mkinitcpio.conf

# Set custom Plymouth theme and rebuild initramfs
log "Setting Shokunin Plymouth theme..."
plymouth-set-default-theme -R shokunin 2>/dev/null || {
    warn "Failed to set theme with -R, trying without rebuild..."
    plymouth-set-default-theme shokunin
    mkinitcpio -P
}

success "Plymouth configured with custom Shokunin theme!"
log "Minimal password prompt will be displayed during boot"

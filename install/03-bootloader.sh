#!/bin/bash
# install/03-bootloader.sh - Install and configure bootloader

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
source "$SCRIPT_DIR/../config/system.conf"

check_root

log "Installing systemd-boot..."

# Install bootloader
bootctl --path=/boot install

# Get root partition UUID
ROOT_UUID=$(blkid -s UUID -o value $(findmnt -n -o SOURCE /))

# Create bootloader entry
log "Creating bootloader entry..."
cat > /boot/loader/entries/arch.conf <<EOF
title   Arch Linux
linux   /vmlinuz-linux
initrd  /initramfs-linux.img
options root=UUID=$ROOT_UUID rw quiet loglevel=3 rd.udev.log_level=3 vt.global_cursor_default=0 splash
EOF

# Configure bootloader
cat > /boot/loader/loader.conf <<EOF
default arch.conf
timeout 0
console-mode keep
editor  no
EOF

success "Bootloader installed!"

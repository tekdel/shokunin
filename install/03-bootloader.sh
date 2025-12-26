#!/bin/bash
# install/03-bootloader.sh - Install and configure Limine bootloader

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
source "$SCRIPT_DIR/../config/system.conf"

check_root

log "Installing Limine bootloader..."

# Install Limine package
pacman -S --needed --noconfirm limine

# Get root partition UUID and device
ROOT_PART=$(findmnt -n -o SOURCE /)
ROOT_UUID=$(blkid -s UUID -o value "$ROOT_PART")
DISK=$(lsblk -no PKNAME "$ROOT_PART")

# Get kernel command line parameters
CMDLINE="root=UUID=$ROOT_UUID rw quiet loglevel=3 rd.udev.log_level=3 vt.global_cursor_default=0 splash"

# Create Limine configuration
log "Creating Limine configuration..."
cat > /boot/limine.cfg <<EOF
# Limine Configuration

# Global settings
timeout: 0
graphics: yes
theme_margin_gradient: 0
theme_margin: 0

# Default boot entry
/Arch Linux
    protocol: linux
    kernel_path: boot():/vmlinuz-linux
    cmdline: $CMDLINE
    module_path: boot():/initramfs-linux.img

# Fallback entry
/Arch Linux (Fallback)
    protocol: linux
    kernel_path: boot():/vmlinuz-linux
    cmdline: $CMDLINE
    module_path: boot():/initramfs-linux-fallback.img
EOF

# Install Limine to disk
log "Installing Limine to disk /dev/$DISK..."
if [ -d /sys/firmware/efi ]; then
    # UEFI installation
    log "UEFI system detected"

    # Copy Limine EFI file
    mkdir -p /boot/EFI/BOOT
    cp /usr/share/limine/BOOTX64.EFI /boot/EFI/BOOT/

    # Create EFI boot entry
    if command -v efibootmgr >/dev/null 2>&1; then
        # Remove old Limine entries
        efibootmgr | grep "Limine" | cut -d' ' -f1 | sed 's/Boot//;s/*//' | xargs -I {} efibootmgr -b {} -B 2>/dev/null || true

        # Add new Limine entry
        efibootmgr --create --disk "/dev/$DISK" --part 1 --label "Limine" --loader '\EFI\BOOT\BOOTX64.EFI'
    fi
else
    # BIOS installation
    log "BIOS system detected"

    # Deploy Limine BIOS files
    mkdir -p /boot/limine
    cp /usr/share/limine/limine-bios.sys /boot/limine/

    # Install Limine to MBR
    limine bios-install "/dev/$DISK"
fi

success "Limine bootloader installed!"
log "Boot timeout: 0 (instant boot)"
log "Press Shift during boot to show menu"

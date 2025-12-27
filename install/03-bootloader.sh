#!/bin/bash
# install/03-bootloader.sh - Install and configure Limine bootloader

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

check_root

log "Installing Limine bootloader..."

# Install Limine package
pacman -S --needed --noconfirm limine

# Get root partition device and UUID
# If encrypted, we need the underlying physical partition
if [ -e /dev/mapper/cryptroot ]; then
    # Encrypted system
    CRYPT_PART=$(cryptsetup status cryptroot | grep device: | awk '{print $2}')
    CRYPT_UUID=$(blkid -s UUID -o value "$CRYPT_PART")

    # Get the disk device (e.g., vda from /dev/vda3)
    # Remove partition number and /dev/ prefix
    DISK=$(echo "$CRYPT_PART" | sed 's/[0-9]*$//' | sed 's|/dev/||')

    # Kernel command line with encryption
    CMDLINE="cryptdevice=UUID=$CRYPT_UUID:cryptroot root=/dev/mapper/cryptroot rw quiet loglevel=3 rd.udev.log_level=3 vt.global_cursor_default=0 splash"
else
    # Non-encrypted system (shouldn't happen with our setup)
    ROOT_PART=$(findmnt -n -o SOURCE /)
    ROOT_UUID=$(blkid -s UUID -o value "$ROOT_PART")

    # Get the disk device
    DISK=$(echo "$ROOT_PART" | sed 's/[0-9]*$//' | sed 's|/dev/||')

    CMDLINE="root=UUID=$ROOT_UUID rw quiet loglevel=3 rd.udev.log_level=3 vt.global_cursor_default=0 splash"
fi

log "Using disk: $DISK"

# Create Limine configuration
log "Creating Limine configuration..."
cat > /boot/limine.cfg <<EOF
# Limine Configuration

# Global settings
timeout: 5
graphics: yes
theme_margin_gradient: 0
theme_margin: 0

# Default boot entry
/Arch Linux
    protocol: linux
    kernel_path: boot():/vmlinuz-linux
    cmdline: $CMDLINE
    module_path: boot():/initramfs-linux.img

# LTS kernel
/Arch Linux LTS
    protocol: linux
    kernel_path: boot():/vmlinuz-linux-lts
    cmdline: $CMDLINE
    module_path: boot():/initramfs-linux-lts.img

# Fallback entries
/Arch Linux (Fallback)
    protocol: linux
    kernel_path: boot():/vmlinuz-linux
    cmdline: $CMDLINE
    module_path: boot():/initramfs-linux-fallback.img

/Arch Linux LTS (Fallback)
    protocol: linux
    kernel_path: boot():/vmlinuz-linux-lts
    cmdline: $CMDLINE
    module_path: boot():/initramfs-linux-lts-fallback.img
EOF

# Install Limine to disk
log "Installing Limine to disk /dev/$DISK..."
if [ -d /sys/firmware/efi ]; then
    # UEFI installation
    log "UEFI system detected"

    # Copy Limine EFI file
    mkdir -p /boot/EFI/BOOT
    cp /usr/share/limine/BOOTX64.EFI /boot/EFI/BOOT/

    # Copy config to EFI directory (Limine looks for it next to BOOTX64.EFI)
    cp /boot/limine.cfg /boot/EFI/BOOT/limine.cfg

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

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

    # Get the disk device using lsblk (handles NVMe, MMC, etc.)
    DISK=$(lsblk -no PKNAME "$CRYPT_PART" | head -1)

    # Kernel command line with encryption (silent boot with Plymouth)
    CMDLINE="cryptdevice=UUID=$CRYPT_UUID:cryptroot root=/dev/mapper/cryptroot rw quiet loglevel=3 rd.udev.log_level=3 vt.global_cursor_default=0 splash plymouth.nolog"
else
    # Non-encrypted system (shouldn't happen with our setup)
    ROOT_PART=$(findmnt -n -o SOURCE /)
    ROOT_UUID=$(blkid -s UUID -o value "$ROOT_PART")

    # Get the disk device using lsblk
    DISK=$(lsblk -no PKNAME "$ROOT_PART" | head -1)

    CMDLINE="root=UUID=$ROOT_UUID rw quiet loglevel=3 rd.udev.log_level=3 vt.global_cursor_default=0 splash plymouth.nolog"
fi

log "Using disk: $DISK"

# Validate disk was detected
if [ -z "$DISK" ]; then
    error "Failed to detect disk device"
fi

if [ ! -b "/dev/$DISK" ]; then
    error "Disk device /dev/$DISK does not exist"
fi

# Create Limine configuration
log "Creating Limine configuration..."
cat > /boot/limine.conf <<EOF
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

# Fallback initramfs (for recovery)
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

    # Copy config to EFI directory (Limine looks for it next to BOOTX64.EFI)
    cp /boot/limine.conf /boot/EFI/BOOT/limine.conf

    # Create EFI boot entry
    if command -v efibootmgr >/dev/null 2>&1; then
        # Ensure efivars is mounted (required for efibootmgr in chroot)
        if [ -d /sys/firmware/efi/efivars ] && ! mountpoint -q /sys/firmware/efi/efivars; then
            log "Mounting efivars filesystem..."
            if ! mount -t efivarfs efivarfs /sys/firmware/efi/efivars; then
                warn "Failed to mount efivars - EFI boot entry will not be created"
                warn "System will still boot via fallback BOOTX64.EFI"
            fi
        fi

        # Only attempt efibootmgr if efivars is accessible
        if mountpoint -q /sys/firmware/efi/efivars 2>/dev/null; then
            # Remove old Limine entries
            efibootmgr | grep "Limine" | cut -d' ' -f1 | sed 's/Boot//;s/\*//' | xargs -I {} efibootmgr -b {} -B 2>/dev/null || true

            # Add new Limine entry
            log "Creating EFI boot entry for disk: /dev/$DISK partition 1"
            if efibootmgr --create --disk "/dev/$DISK" --part 1 --label "Limine" --loader '\EFI\BOOT\BOOTX64.EFI'; then
                success "EFI boot entry created"
            else
                warn "Failed to create EFI boot entry - system should still boot via fallback"
            fi
        else
            warn "efivars not mounted - skipping EFI boot entry creation"
            warn "System will boot via fallback BOOTX64.EFI in EFI/BOOT/"
        fi
    else
        warn "efibootmgr not found - skipping EFI boot entry creation"
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

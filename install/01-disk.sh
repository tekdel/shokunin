#!/bin/bash
# install/01-disk.sh - Partition and format disk with LUKS encryption

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

# Don't source system.conf - we use exported variables from boot.sh
check_root

log "Starting disk partitioning on $DISK with LUKS encryption"

# Warn user
warn "This will ERASE ALL DATA on $DISK"
warn "Full-disk encryption will be enabled (Omarchy-style)"
warn "Press Ctrl+C to cancel, or press Enter to continue..."
read -r

# Unmount if mounted
umount -R /mnt 2>/dev/null || true
cryptsetup close cryptroot 2>/dev/null || true
cryptsetup close cryptswap 2>/dev/null || true

# Wipe disk
log "Wiping disk..."
wipefs -af "$DISK"
sgdisk --zap-all "$DISK"

# Create GPT partition table
log "Creating partition table..."
parted "$DISK" --script mklabel gpt

# Create EFI partition (1GB - Omarchy standard)
log "Creating EFI partition (1GB)..."
parted "$DISK" --script mkpart ESP fat32 1MiB 1025MiB
parted "$DISK" --script set 1 esp on

# Create swap partition (if enabled)
if [ "$SWAP_SIZE" != "0" ]; then
    log "Creating encrypted swap partition ($SWAP_SIZE)..."
    SWAP_END="$((1025 + ${SWAP_SIZE%G} * 1024))MiB"
    parted "$DISK" --script mkpart primary 1025MiB "$SWAP_END"
    ROOT_START="$SWAP_END"
else
    ROOT_START="1025MiB"
fi

# Create root partition (rest of disk)
log "Creating encrypted root partition..."
parted "$DISK" --script mkpart primary "$ROOT_START" 100%

# Determine partition names
if [[ "$DISK" =~ "nvme" ]]; then
    EFI_PART="${DISK}p1"
    if [ "$SWAP_SIZE" != "0" ]; then
        SWAP_PART="${DISK}p2"
        ROOT_PART="${DISK}p3"
    else
        ROOT_PART="${DISK}p2"
    fi
else
    EFI_PART="${DISK}1"
    if [ "$SWAP_SIZE" != "0" ]; then
        SWAP_PART="${DISK}2"
        ROOT_PART="${DISK}3"
    else
        ROOT_PART="${DISK}2"
    fi
fi

# Format EFI partition (unencrypted)
log "Formatting EFI partition..."
mkfs.fat -F32 "$EFI_PART"

# Set up LUKS encryption
log "Setting up LUKS encryption..."
info "You will be prompted to enter an encryption password"
info "This password will be required at every boot"
warn "DO NOT FORGET THIS PASSWORD - there is no recovery!"
echo ""

# Encrypt root partition
log "Encrypting root partition..."
cryptsetup luksFormat --type luks2 "$ROOT_PART"

log "Opening encrypted root partition..."
cryptsetup open "$ROOT_PART" cryptroot

# Format encrypted root
log "Formatting encrypted root partition..."
mkfs.ext4 /dev/mapper/cryptroot

# Set up encrypted swap (if enabled)
if [ "$SWAP_SIZE" != "0" ]; then
    log "Encrypting swap partition..."
    echo "Swap" | cryptsetup luksFormat --type luks2 "$SWAP_PART" -

    log "Opening encrypted swap..."
    echo "Swap" | cryptsetup open "$SWAP_PART" cryptswap -

    log "Formatting swap..."
    mkswap /dev/mapper/cryptswap
    swapon /dev/mapper/cryptswap
fi

# Mount partitions
log "Mounting partitions..."
mount /dev/mapper/cryptroot /mnt
mkdir -p /mnt/boot
mount "$EFI_PART" /mnt/boot

# Export partition info for other scripts
export ROOT_PART
export SWAP_PART
export EFI_PART

success "Disk partitioning with LUKS encryption complete!"
lsblk "$DISK"
echo ""
info "Encrypted partitions:"
info "  Root: $ROOT_PART -> /dev/mapper/cryptroot"
if [ "$SWAP_SIZE" != "0" ]; then
    info "  Swap: $SWAP_PART -> /dev/mapper/cryptswap"
fi

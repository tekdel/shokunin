#!/bin/bash
# install/01-disk.sh - Partition and format disk

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
source "$SCRIPT_DIR/../config/system.conf"

check_root

log "Starting disk partitioning on $DISK"

# Warn user
warn "This will ERASE ALL DATA on $DISK"
warn "Press Ctrl+C to cancel, or press Enter to continue..."
read -r

# Unmount if mounted
umount -R /mnt 2>/dev/null || true

# Wipe disk
log "Wiping disk..."
wipefs -af "$DISK"
sgdisk --zap-all "$DISK"

# Create GPT partition table
log "Creating partition table..."
parted "$DISK" --script mklabel gpt

# Create EFI partition (512MB)
log "Creating EFI partition..."
parted "$DISK" --script mkpart ESP fat32 1MiB 513MiB
parted "$DISK" --script set 1 esp on

# Create swap partition (if enabled)
if [ "$SWAP_SIZE" != "0" ]; then
    log "Creating swap partition ($SWAP_SIZE)..."
    SWAP_END="$((513 + ${SWAP_SIZE%G} * 1024))MiB"
    parted "$DISK" --script mkpart primary linux-swap 513MiB "$SWAP_END"
    ROOT_START="$SWAP_END"
else
    ROOT_START="513MiB"
fi

# Create root partition (rest of disk)
log "Creating root partition..."
parted "$DISK" --script mkpart primary ext4 "$ROOT_START" 100%

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

# Format partitions
log "Formatting EFI partition..."
mkfs.fat -F32 "$EFI_PART"

if [ "$SWAP_SIZE" != "0" ]; then
    log "Setting up swap..."
    mkswap "$SWAP_PART"
    swapon "$SWAP_PART"
fi

log "Formatting root partition..."
mkfs.ext4 -F "$ROOT_PART"

# Mount partitions
log "Mounting partitions..."
mount "$ROOT_PART" /mnt
mkdir -p /mnt/boot
mount "$EFI_PART" /mnt/boot

success "Disk partitioning complete!"
lsblk "$DISK"

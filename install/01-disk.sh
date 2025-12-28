#!/bin/bash
# install/01-disk.sh - Partition and format disk with LUKS encryption

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

# Don't source system.conf - we use exported variables from boot.sh
check_root

log "Starting disk partitioning on $DISK with LUKS encryption"

# Thorough cleanup before partitioning
log "Cleaning up existing mounts and devices..."

# Unmount everything
if mountpoint -q /mnt 2>/dev/null; then
    log "Unmounting /mnt..."
    umount -R /mnt || warn "Failed to unmount /mnt (may not be mounted)"
fi
swapoff -a 2>/dev/null && log "Swap disabled" || true

# Close all LUKS devices
if [ -e /dev/mapper/cryptroot ]; then
    log "Closing existing cryptroot..."
    cryptsetup close cryptroot || warn "Failed to close cryptroot"
fi
if [ -e /dev/mapper/cryptswap ]; then
    log "Closing existing cryptswap..."
    cryptsetup close cryptswap || warn "Failed to close cryptswap"
fi

# Force remove any remaining device mapper devices
if dmsetup ls | grep -q .; then
    log "Removing remaining device mapper devices..."
    dmsetup remove_all || warn "Some device mapper devices could not be removed"
fi

# Wait for devices to settle
log "Waiting for devices to settle..."
udevadm settle --timeout=10 || sleep 2

# Thoroughly wipe disk and all LUKS headers
log "Wiping disk and removing all signatures..."
if ! wipefs -af "$DISK"; then
    warn "wipefs failed - disk may have active partitions"
fi

log "Destroying GPT/MBR data structures..."
if ! sgdisk --zap-all "$DISK"; then
    warn "sgdisk zap failed - continuing anyway"
fi

log "Zeroing first 10MB of disk..."
dd if=/dev/zero of="$DISK" bs=1M count=10 conv=fsync 2>/dev/null || warn "dd zero failed"

# Force kernel to re-read partition table
log "Updating kernel partition table..."
if command -v blockdev >/dev/null; then
    blockdev --rereadpt "$DISK" || warn "blockdev --rereadpt failed"
fi
partprobe "$DISK" || warn "partprobe failed"
udevadm settle --timeout=10 || sleep 2

# Create GPT partition table
log "Creating partition table..."
parted "$DISK" --script mklabel gpt

# Create EFI partition (1GB - Omarchy standard)
log "Creating EFI partition (1GB)..."
parted "$DISK" --script mkpart ESP fat32 1MiB 1025MiB
parted "$DISK" --script set 1 esp on

# Create swap partition (if enabled)
if [ "$SWAP_SIZE" != "0" ] && [ -n "$SWAP_SIZE" ]; then
    log "Creating encrypted swap partition ($SWAP_SIZE)..."
    # Parse swap size - handle G, GB, GiB suffixes
    SWAP_GB=$(echo "$SWAP_SIZE" | sed 's/[^0-9]//g')
    if [ -z "$SWAP_GB" ] || [ "$SWAP_GB" -eq 0 ]; then
        warn "Invalid SWAP_SIZE format: $SWAP_SIZE - skipping swap"
        ROOT_START="1025MiB"
        SWAP_SIZE="0"
    else
        SWAP_END="$((1025 + SWAP_GB * 1024))MiB"
        log "Swap partition: 1025MiB to $SWAP_END (${SWAP_GB}GB)"
        parted "$DISK" --script mkpart primary 1025MiB "$SWAP_END"
        ROOT_START="$SWAP_END"
    fi
else
    ROOT_START="1025MiB"
    SWAP_SIZE="0"
fi

# Create root partition (rest of disk)
log "Creating encrypted root partition..."
parted "$DISK" --script mkpart primary "$ROOT_START" 100%

# Inform kernel of partition changes
log "Updating kernel with new partition table..."
partprobe "$DISK"
sleep 2

# Determine partition names
# NVMe, MMC, and loop devices use 'p' prefix for partition numbers
if [[ "$DISK" =~ (nvme|mmcblk|loop) ]]; then
    PART_PREFIX="${DISK}p"
else
    PART_PREFIX="${DISK}"
fi

EFI_PART="${PART_PREFIX}1"
if [ "$SWAP_SIZE" != "0" ]; then
    SWAP_PART="${PART_PREFIX}2"
    ROOT_PART="${PART_PREFIX}3"
else
    ROOT_PART="${PART_PREFIX}2"
fi

log "Partition layout:"
log "  EFI:  $EFI_PART"
[ "$SWAP_SIZE" != "0" ] && log "  Swap: $SWAP_PART"
log "  Root: $ROOT_PART"

# Wait for partitions to appear
log "Waiting for partitions to be ready..."
wait_for_device "$EFI_PART" 30
wait_for_device "$ROOT_PART" 30
if [ "$SWAP_SIZE" != "0" ]; then
    wait_for_device "$SWAP_PART" 30
fi

# Wipe partitions before use
log "Wiping partition signatures..."
wipefs -af "$EFI_PART" || warn "Failed to wipe $EFI_PART"
wipefs -af "$ROOT_PART" || warn "Failed to wipe $ROOT_PART"
if [ "$SWAP_SIZE" != "0" ]; then
    wipefs -af "$SWAP_PART" || warn "Failed to wipe $SWAP_PART"
fi

# Format EFI partition (unencrypted)
log "Formatting EFI partition as FAT32..."
if ! mkfs.fat -F32 "$EFI_PART"; then
    error "Failed to format EFI partition $EFI_PART"
fi

# Set up LUKS encryption
log "Setting up LUKS encryption..."

# Use encryption password from boot.sh (already confirmed there)
if [ -z "$CRYPT_PASSWORD" ]; then
    error "Encryption password not set! This should be passed from boot.sh"
fi
log "Using encryption password from setup..."

# Encrypt root partition with the password
log "Encrypting root partition with LUKS2..."
if ! echo -n "$CRYPT_PASSWORD" | cryptsetup luksFormat --type luks2 "$ROOT_PART" -; then
    error "Failed to encrypt root partition $ROOT_PART"
fi
success "Root partition encrypted"

log "Opening encrypted root partition..."
if ! echo -n "$CRYPT_PASSWORD" | cryptsetup open "$ROOT_PART" cryptroot -; then
    error "Failed to open encrypted root partition"
fi
wait_for_mapper "cryptroot" 30

# Format encrypted root
log "Formatting encrypted root partition as ext4..."
if ! mkfs.ext4 -F /dev/mapper/cryptroot; then
    error "Failed to format /dev/mapper/cryptroot"
fi

# Mount root first so we can store keyfile on it
log "Mounting root partition to /mnt..."
if ! mount /dev/mapper/cryptroot /mnt; then
    error "Failed to mount /dev/mapper/cryptroot to /mnt"
fi

log "Mounting EFI partition to /mnt/boot..."
mkdir -p /mnt/boot
if ! mount "$EFI_PART" /mnt/boot; then
    error "Failed to mount $EFI_PART to /mnt/boot"
fi

# Set up encrypted swap (if enabled)
if [ "$SWAP_SIZE" != "0" ]; then
    log "Setting up encrypted swap partition..."

    # Generate random keyfile for swap (stored on encrypted root)
    log "Generating keyfile for swap..."
    mkdir -p /mnt/root
    if ! dd if=/dev/urandom of=/mnt/root/swap.key bs=1024 count=4 2>/dev/null; then
        error "Failed to generate swap keyfile"
    fi
    chmod 000 /mnt/root/swap.key
    success "Swap keyfile generated"

    log "Encrypting swap partition with keyfile..."
    if ! cryptsetup luksFormat --type luks2 "$SWAP_PART" --key-file /mnt/root/swap.key; then
        error "Failed to encrypt swap partition $SWAP_PART"
    fi
    success "Swap partition encrypted"

    log "Opening encrypted swap..."
    if ! cryptsetup open "$SWAP_PART" cryptswap --key-file /mnt/root/swap.key; then
        error "Failed to open encrypted swap partition"
    fi
    wait_for_mapper "cryptswap" 30

    log "Formatting and enabling swap..."
    if ! mkswap /dev/mapper/cryptswap; then
        error "Failed to format swap"
    fi
    if ! swapon /dev/mapper/cryptswap; then
        warn "Failed to enable swap (non-fatal)"
    fi

    # Configure crypttab for automatic swap unlock at boot
    log "Configuring /etc/crypttab for encrypted swap..."
    SWAP_UUID=$(blkid -s UUID -o value "$SWAP_PART")
    if [ -z "$SWAP_UUID" ]; then
        error "Failed to get UUID for swap partition $SWAP_PART"
    fi

    mkdir -p /mnt/etc
    cat > /mnt/etc/crypttab <<EOF
# /etc/crypttab: encrypted partitions
# See crypttab(5) for format

# Encrypted swap - automatically unlocked with keyfile after root is mounted
cryptswap UUID=$SWAP_UUID /root/swap.key luks
EOF
    success "Crypttab configured - swap will auto-unlock after root"
fi

# Clear password from memory
unset CRYPT_PASSWORD
unset CRYPT_PASSWORD_CONFIRM

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

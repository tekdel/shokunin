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
umount -R /mnt 2>/dev/null || true
swapoff -a 2>/dev/null || true

# Close all LUKS devices
cryptsetup close cryptroot 2>/dev/null || true
cryptsetup close cryptswap 2>/dev/null || true

# Force remove any device mapper devices
dmsetup remove_all 2>/dev/null || true

# Wait for devices to settle
sleep 2

# Thoroughly wipe disk and all LUKS headers
log "Wiping disk and removing all signatures..."
wipefs -af "$DISK"
sgdisk --zap-all "$DISK"
dd if=/dev/zero of="$DISK" bs=1M count=10 conv=fsync 2>/dev/null || true

# Force kernel to re-read partition table
log "Updating kernel partition table..."
blockdev --rereadpt "$DISK" 2>/dev/null || true
partprobe "$DISK" 2>/dev/null || true
sleep 2

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

# Inform kernel of partition changes
log "Updating kernel with new partition table..."
partprobe "$DISK"
sleep 2

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

# Wipe partitions before use
log "Wiping partition signatures..."
wipefs -af "$EFI_PART"
wipefs -af "$ROOT_PART"
if [ "$SWAP_SIZE" != "0" ]; then
    wipefs -af "$SWAP_PART"
fi

# Format EFI partition (unencrypted)
log "Formatting EFI partition..."
mkfs.fat -F32 "$EFI_PART"

# Set up LUKS encryption
log "Setting up LUKS encryption..."
info "You will be prompted to enter an encryption password"
info "This password will be used for ALL encrypted partitions (root + swap)"
info "This password will be required at every boot"
warn "DO NOT FORGET THIS PASSWORD - there is no recovery!"
echo ""

# Ask for encryption password once
MAX_RETRIES=3
RETRY_COUNT=0
CRYPT_PASSWORD=""

while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    echo "Enter encryption password:" >&2
    read -s CRYPT_PASSWORD </dev/tty
    echo "" >&2

    echo "Confirm encryption password:" >&2
    read -s CRYPT_PASSWORD_CONFIRM </dev/tty
    echo "" >&2

    if [ "$CRYPT_PASSWORD" = "$CRYPT_PASSWORD_CONFIRM" ]; then
        success "Password confirmed!"
        break
    else
        warn "Passwords do not match. Try again."
        RETRY_COUNT=$((RETRY_COUNT + 1))

        if [ $RETRY_COUNT -ge $MAX_RETRIES ]; then
            error "Failed to confirm password after $MAX_RETRIES attempts"
        fi
    fi
done

# Encrypt root partition with the password
log "Encrypting root partition..."
echo -n "$CRYPT_PASSWORD" | cryptsetup luksFormat --type luks2 "$ROOT_PART" -

log "Opening encrypted root partition..."
echo -n "$CRYPT_PASSWORD" | cryptsetup open "$ROOT_PART" cryptroot -

# Format encrypted root
log "Formatting encrypted root partition..."
mkfs.ext4 /dev/mapper/cryptroot

# Mount root first so we can store keyfile on it
log "Mounting root partition..."
mount /dev/mapper/cryptroot /mnt
mkdir -p /mnt/boot
mount "$EFI_PART" /mnt/boot

# Set up encrypted swap (if enabled)
if [ "$SWAP_SIZE" != "0" ]; then
    log "Setting up encrypted swap partition..."

    # Generate random keyfile for swap (stored on encrypted root)
    log "Generating keyfile for swap..."
    mkdir -p /mnt/root
    dd if=/dev/urandom of=/mnt/root/swap.key bs=1024 count=4
    chmod 000 /mnt/root/swap.key

    log "Encrypting swap partition with keyfile..."
    echo -n "$CRYPT_PASSWORD" | cryptsetup luksFormat --type luks2 "$SWAP_PART" /mnt/root/swap.key -

    log "Opening encrypted swap..."
    cryptsetup open "$SWAP_PART" cryptswap --key-file /mnt/root/swap.key

    log "Formatting swap..."
    mkswap /dev/mapper/cryptswap
    swapon /dev/mapper/cryptswap

    # Configure crypttab for automatic swap unlock at boot
    log "Configuring /etc/crypttab for encrypted swap..."
    SWAP_UUID=$(blkid -s UUID -o value "$SWAP_PART")

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

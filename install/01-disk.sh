#!/bin/bash
# install/01-disk.sh - Partition and format disk with LUKS encryption

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

# Don't source system.conf - we use exported variables from boot.sh
check_root

log "Starting disk partitioning on $DISK with LUKS encryption"

# Unmount if mounted (no need to ask again - already confirmed in boot.sh)
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

# Encrypt root partition with retry logic
MAX_RETRIES=3
RETRY_COUNT=0

while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    log "Encrypting root partition... (attempt $((RETRY_COUNT + 1))/$MAX_RETRIES)"

    if cryptsetup luksFormat --type luks2 "$ROOT_PART"; then
        log "Opening encrypted root partition..."

        if cryptsetup open "$ROOT_PART" cryptroot; then
            success "Root partition encrypted and opened successfully!"
            break
        else
            warn "Failed to open partition - password mismatch?"
            RETRY_COUNT=$((RETRY_COUNT + 1))

            if [ $RETRY_COUNT -lt $MAX_RETRIES ]; then
                warn "Let's try again. Please enter the SAME password twice."
                # Wipe the failed LUKS header and retry
                wipefs -af "$ROOT_PART"
            else
                error "Failed to encrypt root partition after $MAX_RETRIES attempts"
            fi
        fi
    else
        error "Failed to format LUKS partition"
    fi
done

# Format encrypted root
log "Formatting encrypted root partition..."
mkfs.ext4 /dev/mapper/cryptroot

# Set up encrypted swap (if enabled)
if [ "$SWAP_SIZE" != "0" ]; then
    log "Setting up encrypted swap partition..."

    # Wipe any existing LUKS header first
    wipefs -af "$SWAP_PART"

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

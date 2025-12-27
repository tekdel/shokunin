#!/bin/bash
# test-vm.sh - Test the installer in a QEMU virtual machine
# This script helps you test the Arch Linux installer safely in a VM

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

log() { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[*]${NC} $1"; }
error() { echo -e "${RED}[!]${NC} $1" >&2; exit 1; }
info() { echo -e "${BLUE}[i]${NC} $1"; }

# Configuration
VM_NAME="arch-test"
VM_DIR="$HOME/.local/share/vms/$VM_NAME"
DISK_IMAGE="$VM_DIR/arch-test.qcow2"
DISK_SIZE="20G"
ISO_PATH="$HOME/Downloads/archlinux.iso"
MEMORY="4G"
CPUS="4"

# Banner
echo -e "${CYAN}"
cat << "EOF"
╔═══════════════════════════════════════════════════════════╗
║                                                           ║
║           VM Testing Environment Setup                   ║
║                                                           ║
╚═══════════════════════════════════════════════════════════╝
EOF
echo -e "${NC}"

# Check if QEMU is installed
if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
    error "QEMU is not installed. Install with: sudo pacman -S qemu-full"
fi

# Function to show usage
show_usage() {
    echo "Usage: $0 [COMMAND]"
    echo ""
    echo "Commands:"
    echo "  setup       - Create VM disk and download Arch ISO"
    echo "  install     - Boot VM from ISO to test installation"
    echo "  boot        - Boot the installed system"
    echo "  clean       - Remove VM disk and ISO"
    echo "  help        - Show this help message"
    echo ""
    echo "Configuration:"
    echo "  VM Directory: $VM_DIR"
    echo "  Disk Size:    $DISK_SIZE"
    echo "  Memory:       $MEMORY"
    echo "  CPUs:         $CPUS"
    echo ""
}

# Setup VM
setup_vm() {
    log "Setting up VM environment..."

    # Create VM directory
    mkdir -p "$VM_DIR"

    # Create disk image if it doesn't exist
    if [ -f "$DISK_IMAGE" ]; then
        warn "Disk image already exists: $DISK_IMAGE"
        read -p "Recreate disk image? This will DELETE all data! (y/N): " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            rm "$DISK_IMAGE"
        else
            info "Using existing disk image"
            return 0
        fi
    fi

    log "Creating $DISK_SIZE disk image..."
    qemu-img create -f qcow2 "$DISK_IMAGE" "$DISK_SIZE"

    # Download Arch ISO if not present
    if [ ! -f "$ISO_PATH" ]; then
        warn "Arch ISO not found at: $ISO_PATH"
        echo ""
        echo "Please download the Arch Linux ISO:"
        echo "  1. Visit: https://archlinux.org/download/"
        echo "  2. Download to: $ISO_PATH"
        echo "  3. Or specify custom path when running this script"
        echo ""
        read -p "Enter path to Arch ISO (or press Enter to skip): " custom_iso
        if [ -n "$custom_iso" ]; then
            ISO_PATH="$custom_iso"
        else
            warn "Skipping ISO download. You'll need to provide it manually."
        fi
    fi

    if [ -f "$ISO_PATH" ]; then
        info "Using ISO: $ISO_PATH"
    fi

    echo ""
    echo -e "${GREEN}✓${NC} VM setup complete!"
    echo ""
    echo "Next steps:"
    echo "  1. $0 install  - Boot from ISO and run the installer"
    echo "  2. $0 boot     - Boot into installed system"
}

# Boot from ISO for installation
install_mode() {
    if [ ! -f "$DISK_IMAGE" ]; then
        error "Disk image not found. Run: $0 setup"
    fi

    if [ ! -f "$ISO_PATH" ]; then
        error "Arch ISO not found at: $ISO_PATH"
    fi

    log "Starting VM in installation mode..."
    echo ""
    info "The VM will boot from the Arch ISO"
    info "Inside the VM, you can:"
    echo "  1. Connect to internet (if needed)"
    echo "  2. Run the installer: curl -L <your-repo>/boot.sh | bash"
    echo "  3. Or test locally by copying the installer directory"
    echo ""
    warn "Press Enter to start VM..."
    read -r

    qemu-system-x86_64 \
        -enable-kvm \
        -m "$MEMORY" \
        -cpu host \
        -smp "$CPUS" \
        -drive file="$DISK_IMAGE",format=qcow2,if=virtio \
        -cdrom "$ISO_PATH" \
        -boot d \
        -nic user,model=virtio-net-pci \
        -vga virtio \
        -device virtio-serial-pci \
        -device virtserialport,chardev=spicechannel0,name=com.redhat.spice.0 \
        -chardev spicevmc,id=spicechannel0,name=vdagent \
        -spice port=5930,disable-ticketing=on \
        -device qxl-vga \
        -display gtk,gl=on \
        -audiodev pa,id=snd0 \
        -device intel-hda \
        -device hda-output,audiodev=snd0
}

# Boot installed system
boot_mode() {
    if [ ! -f "$DISK_IMAGE" ]; then
        error "Disk image not found. Run: $0 setup"
    fi

    log "Starting installed system..."
    warn "Press Enter to boot VM..."
    read -r

    qemu-system-x86_64 \
        -enable-kvm \
        -m "$MEMORY" \
        -cpu host \
        -smp "$CPUS" \
        -drive file="$DISK_IMAGE",format=qcow2,if=virtio \
        -boot c \
        -nic user,model=virtio-net-pci \
        -vga virtio \
        -device virtio-serial-pci \
        -device virtserialport,chardev=spicechannel0,name=com.redhat.spice.0 \
        -chardev spicevmc,id=spicechannel0,name=vdagent \
        -spice port=5930,disable-ticketing=on \
        -device qxl-vga \
        -display gtk,gl=on \
        -audiodev pa,id=snd0 \
        -device intel-hda \
        -device hda-output,audiodev=snd0
}

# Clean up VM
clean_vm() {
    warn "This will delete the VM disk image and all data!"
    read -p "Are you sure? (y/N): " confirm

    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        log "Cleaning up VM..."
        rm -rf "$VM_DIR"
        info "VM directory removed: $VM_DIR"

        read -p "Also delete Arch ISO at $ISO_PATH? (y/N): " iso_confirm
        if [[ "$iso_confirm" =~ ^[Yy]$ ]]; then
            rm -f "$ISO_PATH"
            info "ISO removed"
        fi

        echo -e "${GREEN}✓${NC} Cleanup complete!"
    else
        info "Cleanup cancelled"
    fi
}

# Main script logic
case "${1:-help}" in
    setup)
        setup_vm
        ;;
    install)
        install_mode
        ;;
    boot)
        boot_mode
        ;;
    clean)
        clean_vm
        ;;
    help|--help|-h)
        show_usage
        ;;
    *)
        error "Unknown command: $1\n$(show_usage)"
        ;;
esac

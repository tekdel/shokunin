#!/bin/bash
# Fix MT7925 WiFi by installing linux-lts kernel
# The mt7925e driver has a firmware loading bug in kernel 6.19.x
# LTS kernel (6.18.x) works correctly

set -e

echo "Installing linux-lts kernel and headers..."
sudo pacman -S --needed --noconfirm linux-lts linux-lts-headers

echo "Rebuilding initramfs for LTS kernel..."
sudo mkinitcpio -p linux-lts

# Find the active limine config
LIMINE_CONF=""
if [ -f /boot/EFI/BOOT/limine.conf ]; then
    LIMINE_CONF="/boot/EFI/BOOT/limine.conf"
elif [ -f /boot/limine/limine.conf ]; then
    LIMINE_CONF="/boot/limine/limine.conf"
elif [ -f /boot/limine.conf ]; then
    LIMINE_CONF="/boot/limine.conf"
fi

if [ -z "$LIMINE_CONF" ]; then
    echo "ERROR: Could not find limine.conf"
    exit 1
fi

# Extract the cmdline from the existing config
CMDLINE=$(grep '^\s*cmdline:' "$LIMINE_CONF" | head -1 | sed 's/^\s*cmdline:\s*//')

echo "Updating limine config at $LIMINE_CONF..."
sudo tee "$LIMINE_CONF" > /dev/null << EOF
# Limine Configuration

# Global settings
timeout: 5
graphics: yes
theme_margin_gradient: 0
theme_margin: 0

# Default boot entry (LTS kernel - stable, MT7925 WiFi works)
/Arch Linux (LTS)
    protocol: linux
    kernel_path: boot():/vmlinuz-linux-lts
    cmdline: ${CMDLINE}
    module_path: boot():/initramfs-linux-lts.img

# Latest kernel (MT7925 WiFi broken on 6.19.x)
/Arch Linux
    protocol: linux
    kernel_path: boot():/vmlinuz-linux
    cmdline: ${CMDLINE}
    module_path: boot():/initramfs-linux.img

# Fallback initramfs (for recovery)
/Arch Linux (Fallback)
    protocol: linux
    kernel_path: boot():/vmlinuz-linux-lts
    cmdline: ${CMDLINE}
    module_path: boot():/initramfs-linux-lts-fallback.img
EOF

# Sync both limine config locations
if [ -f /boot/limine.conf ] && [ "$LIMINE_CONF" != "/boot/limine.conf" ]; then
    sudo cp "$LIMINE_CONF" /boot/limine.conf
    echo "Synced /boot/limine.conf"
fi

echo ""
echo "Done! LTS kernel is now the default boot entry."
echo ""
echo "IMPORTANT: Do a full power off (not reboot) so the MT7925 chip resets:"
echo "  systemctl poweroff"
echo "Wait 30 seconds, then power on."

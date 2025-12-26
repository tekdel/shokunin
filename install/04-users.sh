#!/bin/bash
# install/04-users.sh - Configure system and create user

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
source "$SCRIPT_DIR/../config/system.conf"

check_root

log "Configuring system..."

# Set timezone
log "Setting timezone to $TIMEZONE..."
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc

# Set locale
log "Setting locale to $LOCALE..."
echo "$LOCALE UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=$LOCALE" > /etc/locale.conf

# Set keymap
echo "KEYMAP=$KEYMAP" > /etc/vconsole.conf

# Set hostname
log "Setting hostname to $HOSTNAME..."
echo "$HOSTNAME" > /etc/hostname

# Configure hosts file
cat > /etc/hosts <<EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME.localdomain $HOSTNAME
EOF

# Create user
log "Creating user $USERNAME..."
useradd -m -G $USER_GROUPS -s /bin/bash $USERNAME

# Set user password
log "Setting password for $USERNAME..."
echo "$USERNAME:$USER_PASSWORD" | chpasswd

# Set root password
log "Setting root password..."
echo "root:$ROOT_PASSWORD" | chpasswd

# Configure sudo
log "Configuring sudo..."
echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/wheel
chmod 440 /etc/sudoers.d/wheel

# Enable NetworkManager
log "Enabling NetworkManager..."
systemctl enable NetworkManager

success "System configured and user created!"

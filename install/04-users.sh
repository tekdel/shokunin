#!/bin/bash
# install/04-users.sh - Configure system and create user

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

check_root

log "Configuring system..."

# Set timezone
if [ -z "$TIMEZONE" ]; then
    warn "TIMEZONE not set, defaulting to UTC"
    TIMEZONE="UTC"
fi
log "Setting timezone to $TIMEZONE..."
if [ ! -f "/usr/share/zoneinfo/$TIMEZONE" ]; then
    warn "Timezone $TIMEZONE not found, using UTC"
    TIMEZONE="UTC"
fi
ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
if ! hwclock --systohc; then
    warn "Failed to sync hardware clock (may be normal in VM)"
fi

# Set locale
LOCALE="${LOCALE:-en_US.UTF-8}"
log "Setting locale to $LOCALE..."
# Avoid duplicates in locale.gen
if ! grep -q "^$LOCALE" /etc/locale.gen; then
    echo "$LOCALE UTF-8" >> /etc/locale.gen
fi
if ! locale-gen; then
    error "Failed to generate locales"
fi
echo "LANG=$LOCALE" > /etc/locale.conf

# Set keymap
KEYMAP="${KEYMAP:-us}"
log "Setting keymap to $KEYMAP..."
echo "KEYMAP=$KEYMAP" > /etc/vconsole.conf

# Set hostname
if [ -z "$HOSTNAME" ]; then
    error "HOSTNAME not set"
fi
log "Setting hostname to $HOSTNAME..."
echo "$HOSTNAME" > /etc/hostname

# Configure hosts file
log "Configuring /etc/hosts..."
cat > /etc/hosts <<EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME.localdomain $HOSTNAME
EOF

# Verify required variables
if [ -z "$USERNAME" ]; then
    error "USERNAME not set"
fi
if [ -z "$USER_PASSWORD" ]; then
    error "USER_PASSWORD not set"
fi
if [ -z "$ROOT_PASSWORD" ]; then
    error "ROOT_PASSWORD not set"
fi

# Check if zsh is installed, fall back to bash if not
if command -v zsh >/dev/null 2>&1; then
    USER_SHELL="/bin/zsh"
else
    warn "zsh not installed, using bash as default shell"
    USER_SHELL="/bin/bash"
fi

# Create user
log "Creating user $USERNAME with shell $USER_SHELL..."
# Only add to basic groups that exist in base system
# Docker and other groups will be added later when packages are installed
if id "$USERNAME" &>/dev/null; then
    warn "User $USERNAME already exists, skipping creation"
else
    if ! useradd -m -G wheel,audio,video,input -s "$USER_SHELL" "$USERNAME"; then
        error "Failed to create user $USERNAME"
    fi
    success "User $USERNAME created"
fi

# Set user password
log "Setting password for $USERNAME..."
if ! echo "$USERNAME:$USER_PASSWORD" | chpasswd; then
    error "Failed to set password for $USERNAME"
fi

# Set root password
log "Setting root password..."
if ! echo "root:$ROOT_PASSWORD" | chpasswd; then
    error "Failed to set root password"
fi

# Configure sudo
log "Configuring sudo for wheel group..."
echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/wheel
chmod 440 /etc/sudoers.d/wheel

# Verify sudoers syntax
if command -v visudo >/dev/null 2>&1; then
    if ! visudo -c -f /etc/sudoers.d/wheel >/dev/null 2>&1; then
        error "Invalid sudoers configuration"
    fi
fi

success "System configured and user $USERNAME created!"

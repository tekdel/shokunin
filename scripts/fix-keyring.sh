#!/bin/bash
# scripts/fix-keyring.sh - Fix pacman PGP keyring issues

set -e

echo "Fixing pacman keyring..."

# Remove lock file if exists
sudo rm -f /var/lib/pacman/db.lck

# Reinitialize keyring
sudo rm -rf /etc/pacman.d/gnupg
sudo pacman-key --init
sudo pacman-key --populate archlinux

# Update keyring package
sudo pacman -Sy --noconfirm archlinux-keyring

echo "Keyring fixed! Try your command again."

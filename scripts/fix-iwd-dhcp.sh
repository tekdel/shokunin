#!/bin/bash
# scripts/fix-iwd-dhcp.sh - Enable DHCP in iwd for automatic IP assignment
# Run this if WiFi connects but doesn't get an IP address

set -e

echo "Configuring iwd for automatic IP assignment..."

sudo mkdir -p /etc/iwd
sudo tee /etc/iwd/main.conf > /dev/null << 'EOF'
[General]
EnableNetworkConfiguration=true

[Network]
NameResolvingService=systemd
EOF

echo "Enabling systemd-resolved for DNS..."
sudo systemctl enable --now systemd-resolved

echo "Restarting iwd..."
sudo systemctl restart iwd

echo "Done! Reconnect to WiFi to get an IP address."
echo "Use 'impala' to manage WiFi connections."

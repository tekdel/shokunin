#!/bin/bash
# scripts/fix-polkit.sh - Fix polkit rules for iwd and bluetooth access
# Run this if impala or bluetui require sudo

set -e

echo "Configuring polkit rules for iwd and bluetooth..."

sudo mkdir -p /etc/polkit-1/rules.d

sudo tee /etc/polkit-1/rules.d/50-net-wifi-bluetooth.rules > /dev/null << 'EOF'
// Allow wheel group members to control iwd (WiFi) without password
polkit.addRule(function(action, subject) {
    if (action.id.indexOf("net.connman.iwd.") == 0 &&
        subject.isInGroup("wheel")) {
        return polkit.Result.YES;
    }
});

// Allow wheel group members to control bluetooth without password
polkit.addRule(function(action, subject) {
    if (action.id.indexOf("org.bluez.") == 0 &&
        subject.isInGroup("wheel")) {
        return polkit.Result.YES;
    }
});
EOF

echo "Polkit rules installed!"
echo "Please log out and back in for changes to take effect."

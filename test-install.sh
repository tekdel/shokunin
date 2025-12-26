#!/bin/bash
# test-install.sh - Quick test script for VM installation

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}Quick VM Test Installation${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "This script helps you test the installer in a VM"
echo ""
echo "Steps:"
echo "  1. Boot the VM with: ./test-vm.sh install"
echo "  2. Inside the VM, run these commands:"
echo ""
echo -e "${YELLOW}# In the Arch ISO environment:${NC}"
echo ""
echo "# 1. Create a temporary directory and copy installer"
echo "mkdir -p /root/installer"
echo "cd /root/installer"
echo ""
echo "# 2. Download or create installer files"
echo "# Since we're testing locally, you'll need to manually create the files"
echo "# Or use a simple HTTP server:"
echo ""
echo -e "${GREEN}On your host machine (in another terminal):${NC}"
echo "  cd /home/andrei/projects/shokunin"
echo "  python -m http.server 8000"
echo ""
echo -e "${YELLOW}Then in the VM:${NC}"
echo "  curl -L http://10.0.2.2:8000/boot.sh -o boot.sh"
echo "  chmod +x boot.sh"
echo "  ./boot.sh"
echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

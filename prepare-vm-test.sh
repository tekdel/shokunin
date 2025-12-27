#!/bin/bash
# prepare-vm-test.sh - Prepare tarball for VM testing

set -e

GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}Creating tarball for VM testing...${NC}"

cd "$(dirname "$0")"

# Create tarball
tar czf /tmp/shokunin.tar.gz \
    --exclude='.git' \
    --exclude='*.qcow2' \
    --exclude='.local' \
    .

# Copy boot.sh to /tmp for HTTP serving
cp boot.sh /tmp/boot.sh

echo -e "${GREEN}✓${NC} Tarball created: /tmp/shokunin.tar.gz"
echo -e "${GREEN}✓${NC} boot.sh copied to: /tmp/boot.sh"
echo ""
echo "Now run these commands:"
echo ""
echo -e "${BLUE}Terminal 1 - Start HTTP server:${NC}"
echo "  cd /tmp"
echo "  python -m http.server 8000"
echo ""
echo -e "${BLUE}Terminal 2 - Boot VM:${NC}"
echo "  ./test-vm.sh install"
echo ""
echo -e "${BLUE}Inside VM - Same command as real hardware:${NC}"
echo "  curl -L http://10.0.2.2:8000/boot.sh | bash"
echo ""

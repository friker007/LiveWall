#!/bin/bash
set -e

# Color codes for premium console styling
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${BLUE}Checking for latest LiveWall installer on GitHub...${NC}"

# Fetch latest release JSON from GitHub API
RELEASE_JSON=$(curl -s "https://api.github.com/repos/friker007/LiveWall/releases/latest")

# Parse tag name and download URL for DMG
TAG_NAME=$(echo "$RELEASE_JSON" | grep -m 1 '"tag_name":' | sed -E 's/.*"tag_name": "([^"]+)".*/\1/')
DOWNLOAD_URL=$(echo "$RELEASE_JSON" | grep -o 'https://github.com/friker007/LiveWall/releases/download/[^"]*\.dmg' | head -n 1)

if [ -z "$TAG_NAME" ] || [ -z "$DOWNLOAD_URL" ]; then
    echo -e "${YELLOW}No precompiled DMG release found on GitHub. Building locally instead...${NC}"
    SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
    "$SCRIPT_DIR/create_installer.sh"
    exit 0
fi

echo -e "${GREEN}Found latest version: ${TAG_NAME}${NC}"
echo -e "${BLUE}Downloading latest LiveWall_Installer.dmg...${NC}"

curl -L -o "LiveWall_Installer.dmg" "$DOWNLOAD_URL"

echo -e "${GREEN}🎉 Success! Downloaded latest installer to current directory: ${YELLOW}LiveWall_Installer.dmg${NC}"
open "LiveWall_Installer.dmg"

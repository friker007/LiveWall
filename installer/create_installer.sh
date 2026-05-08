#!/bin/bash

# --- Elegant macOS DMG Installer Packager ---
# This script builds the latest LiveWall app and packages it into a premium, 
# standard macOS drag-and-drop DMG (Disk Image) installer inside /installer.

set -e

# Color codes for premium console styling
GREEN='\033[0;32m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${PURPLE}====================================================${NC}"
echo -e "${PURPLE}          Building Premium macOS DMG Installer      ${NC}"
echo -e "${PURPLE}====================================================${NC}"

# Step 1: Rebuild the application to ensure we have the latest binaries
echo -e "${BLUE}[1/5] Compiling latest LiveWall.app...${NC}"
./build.sh

# Step 2: Set up installer directories
echo -e "${BLUE}[2/5] Creating installer directories...${NC}"
mkdir -p installer
STAGING_DIR="installer/staging"
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"

# Step 3: Copy App Bundle and create Applications symlink
echo -e "${BLUE}[3/5] Staging App Bundle and /Applications Symlink...${NC}"
cp -R LiveWall.app "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"

# Set a custom volume icon if available (can use the app's icon)
# We copy the icon to the root of the staging folder as .VolumeIcon.icns
if [ -f "LiveWall.app/Contents/Resources/AppIcon.icns" ]; then
    cp "LiveWall.app/Contents/Resources/AppIcon.icns" "$STAGING_DIR/.VolumeIcon.icns"
fi

# Step 4: Build the read-only compressed DMG using native hdiutil
DMG_PATH="installer/LiveWall_Installer.dmg"
rm -f "$DMG_PATH"

echo -e "${BLUE}[4/5] Packaging into Compressed DMG Disk Image...${NC}"
# UDZO format creates a highly compressed read-only disk image
hdiutil create -volname "LiveWall Installer" -srcfolder "$STAGING_DIR" -ov -format UDZO "$DMG_PATH"

# Make the volume icon show up
if [ -f "$STAGING_DIR/.VolumeIcon.icns" ]; then
    hdiutil asr -source "$DMG_PATH" -target "$DMG_PATH" --erase --noprompt 2>/dev/null || true
fi

# Step 5: Clean up staging area
echo -e "${BLUE}[5/5] Cleaning up temporary files...${NC}"
rm -rf "$STAGING_DIR"

echo -e "${GREEN}====================================================${NC}"
echo -e "${GREEN}🎉 Success! DMG Installer Created: ${YELLOW}$DMG_PATH${NC}"
echo -e "${GREEN}====================================================${NC}"

# Open the generated DMG immediately so the user can see their gorgeous new installer!
echo -e "${CYAN}Opening LiveWall_Installer.dmg...${NC}"
open "$DMG_PATH"

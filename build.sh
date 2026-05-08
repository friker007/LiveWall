#!/bin/bash
set -e

APP_NAME="LiveWall"
BUNDLE_DIR="${APP_NAME}.app"
CONTENTS_DIR="${BUNDLE_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

echo "Creating App Bundle structure..."
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"

echo "Compiling Swift code..."
swiftc *.swift -o "${MACOS_DIR}/${APP_NAME}"

echo "Copying Info.plist..."
cp Info.plist "${CONTENTS_DIR}/"

if [ -f "video.mp4" ]; then
    echo "Copying video.mp4..."
    cp video.mp4 "${RESOURCES_DIR}/"
else
    echo "Warning: video.mp4 not found. Please place a video.mp4 in this directory before running the app."
fi

echo "Done! You can now run 'open ${BUNDLE_DIR}'"

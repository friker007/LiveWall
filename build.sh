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

echo "Compiling Swift code for Apple Silicon (arm64)..."
swiftc -target arm64-apple-macos14.0 *.swift -o "${MACOS_DIR}/${APP_NAME}_arm64"

echo "Compiling Swift code for Intel (x86_64)..."
swiftc -target x86_64-apple-macos14.0 *.swift -o "${MACOS_DIR}/${APP_NAME}_x86"

echo "Merging architectures into a Universal 2 Binary..."
lipo -create "${MACOS_DIR}/${APP_NAME}_arm64" "${MACOS_DIR}/${APP_NAME}_x86" -output "${MACOS_DIR}/${APP_NAME}"
rm "${MACOS_DIR}/${APP_NAME}_arm64" "${MACOS_DIR}/${APP_NAME}_x86"

echo "Copying Info.plist..."
cp Info.plist "${CONTENTS_DIR}/"

if [ -f "video.mp4" ]; then
    echo "Copying video.mp4..."
    cp video.mp4 "${RESOURCES_DIR}/"
else
    echo "Warning: video.mp4 not found. Please place a video.mp4 in this directory before running the app."
fi

echo "Codesigning application bundle (ad-hoc)..."
codesign --force --deep --sign - "${BUNDLE_DIR}"

echo "Done! You can now run 'open ${BUNDLE_DIR}'"

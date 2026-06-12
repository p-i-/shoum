#!/bin/bash
# Builds SpeakApp.app with swiftc directly — no Xcode required, only the
# Command Line Tools (swiftc, codesign, plutil).
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$SCRIPT_DIR/SpeakApp/SpeakApp"
BUILD_DIR="$SCRIPT_DIR/build"
APP="$BUILD_DIR/SpeakApp.app"

if [ "$1" = "--clean" ]; then
    echo "Cleaning build directory..."
    rm -rf "$BUILD_DIR"
fi

mkdir -p "$APP/Contents/MacOS"

echo "Compiling SpeakApp..."
swiftc \
    -O \
    -target arm64-apple-macos13.0 \
    -o "$APP/Contents/MacOS/SpeakApp" \
    "$SRC_DIR"/*.swift

# Info.plist: substitute the variables Xcode used to expand
sed -e 's/\$(EXECUTABLE_NAME)/SpeakApp/g' \
    -e 's/\$(PRODUCT_NAME)/SpeakApp/g' \
    -e 's/\$(PRODUCT_BUNDLE_IDENTIFIER)/com.local.SpeakApp/g' \
    -e 's/\$(MACOSX_DEPLOYMENT_TARGET)/13.0/g' \
    "$SRC_DIR/Info.plist" > "$APP/Contents/Info.plist"
plutil -lint -s "$APP/Contents/Info.plist"

printf 'APPL????' > "$APP/Contents/PkgInfo"

# Ad-hoc signature; locally-built means no quarantine, so Gatekeeper is happy
codesign --force --sign - \
    --entitlements "$SRC_DIR/SpeakApp.entitlements" \
    "$APP"

echo "Build complete: $APP"

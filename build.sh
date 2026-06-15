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
    -target arm64-apple-macos14.0 \
    -o "$APP/Contents/MacOS/SpeakApp" \
    "$SRC_DIR"/*.swift

# Stamp the build with its git commit (short hash, +"-dirty" if the working tree
# has uncommitted changes). The app reads this (Info.plist → SpeakGitCommit) for
# the About pane and the update check; "unknown"/"-dirty" marks a dev build that
# skips the update check.
GIT_COMMIT=$(git -C "$SCRIPT_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")
if [ "$GIT_COMMIT" != "unknown" ] && ! git -C "$SCRIPT_DIR" diff --quiet 2>/dev/null; then
    GIT_COMMIT="$GIT_COMMIT-dirty"
fi
echo "Stamping build: $GIT_COMMIT"

# Info.plist: substitute the variables Xcode used to expand
sed -e 's/\$(EXECUTABLE_NAME)/SpeakApp/g' \
    -e 's/\$(PRODUCT_NAME)/SpeakApp/g' \
    -e 's/\$(PRODUCT_BUNDLE_IDENTIFIER)/com.local.SpeakApp/g' \
    -e 's/\$(MACOSX_DEPLOYMENT_TARGET)/14.0/g' \
    -e "s/\$(SPEAK_GIT_COMMIT)/$GIT_COMMIT/g" \
    "$SRC_DIR/Info.plist" > "$APP/Contents/Info.plist"
plutil -lint -s "$APP/Contents/Info.plist"

printf 'APPL????' > "$APP/Contents/PkgInfo"

# Ad-hoc signature; locally-built means no quarantine, so Gatekeeper is happy
codesign --force --sign - \
    --entitlements "$SRC_DIR/SpeakApp.entitlements" \
    "$APP"

echo "Build complete: $APP"

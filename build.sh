#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR/SpeakApp"
BUILD_DIR="$SCRIPT_DIR/build"

if [ "$1" = "--clean" ]; then
    echo "Cleaning build directory..."
    rm -rf "$BUILD_DIR"
fi

echo "Building SpeakApp..."
xcodebuild -project "$PROJECT_DIR/SpeakApp.xcodeproj" \
    -scheme SpeakApp \
    -configuration Debug \
    -derivedDataPath "$BUILD_DIR" \
    -quiet \
    build

echo "Build complete: $BUILD_DIR/Build/Products/Debug/SpeakApp.app"

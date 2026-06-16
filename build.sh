#!/bin/bash
# Builds Shoum.app with swiftc directly — no Xcode required, only the
# Command Line Tools (swiftc, codesign, plutil).
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$SCRIPT_DIR/Shoum"
BUILD_DIR="$SCRIPT_DIR/build"
APP="$BUILD_DIR/Shoum.app"

# --static links the VAD against whisper.cpp's STATIC archives (build-install) so
# the app binary is self-contained — used by install.sh. Default (dev) links the
# clone's dylibs by rpath (fast iteration, but clone-tethered).
STATIC=false
for arg in "$@"; do
    case "$arg" in
        --clean)  echo "Cleaning build directory..."; rm -rf "$BUILD_DIR" ;;
        --static) STATIC=true ;;
    esac
done

mkdir -p "$APP/Contents/MacOS"

echo "Compiling Shoum$($STATIC && echo ' (static VAD)')..."
# Link whisper.cpp for the Silero VAD (whisper_vad_* via whisper-bridge.h).
WHISPER="$SCRIPT_DIR/whisper.cpp"
LINK=()
if $STATIC; then
    # Self-contained: link the static archives install.sh built (build-install).
    B="$WHISPER/build-install"
    [ -f "$B/src/libwhisper.a" ] || { echo "ERROR: $B/src/libwhisper.a missing — build whisper-server static first (install.sh does this)"; exit 1; }
    LINK=(
        "$B/src/libwhisper.a" "$B/src/libwhisper.coreml.a"
        "$B/ggml/src/libggml.a" "$B/ggml/src/libggml-cpu.a" "$B/ggml/src/libggml-base.a"
        "$B/ggml/src/ggml-blas/libggml-blas.a" "$B/ggml/src/ggml-metal/libggml-metal.a"
        -lc++ -framework Foundation -framework Accelerate -framework Metal
        -framework MetalKit -framework CoreML
    )
else
    # Dev: link the clone's dylibs by rpath (clone-tethered; not for install).
    LINK=(
        -L "$WHISPER/build/src" -L "$WHISPER/build/ggml/src" -lwhisper -lggml -lc++
        -Xlinker -rpath -Xlinker "$WHISPER/build/src"
        -Xlinker -rpath -Xlinker "$WHISPER/build/ggml/src"
        -Xlinker -rpath -Xlinker "$WHISPER/build/ggml/src/ggml-metal"
        -Xlinker -rpath -Xlinker "$WHISPER/build/ggml/src/ggml-blas"
    )
fi
swiftc \
    -O \
    -target arm64-apple-macos14.0 \
    -import-objc-header "$SRC_DIR/whisper-bridge.h" \
    -I "$WHISPER/include" -I "$WHISPER/ggml/include" \
    -o "$APP/Contents/MacOS/Shoum" \
    "$SRC_DIR"/*.swift \
    "${LINK[@]}"

# Stamp the build with its git commit (short hash, +"-dirty" if the working tree
# has uncommitted changes). The app reads this (Info.plist → ShoumGitCommit) for
# the About pane and the update check; "unknown"/"-dirty" marks a dev build that
# skips the update check.
GIT_COMMIT=$(git -C "$SCRIPT_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")
if [ "$GIT_COMMIT" != "unknown" ] && ! git -C "$SCRIPT_DIR" diff --quiet 2>/dev/null; then
    GIT_COMMIT="$GIT_COMMIT-dirty"
fi
echo "Stamping build: $GIT_COMMIT"

# Info.plist: substitute the variables Xcode used to expand
sed -e 's/\$(EXECUTABLE_NAME)/Shoum/g' \
    -e 's/\$(PRODUCT_NAME)/Shoum/g' \
    -e 's/\$(PRODUCT_BUNDLE_IDENTIFIER)/org.pipad.shoum/g' \
    -e 's/\$(MACOSX_DEPLOYMENT_TARGET)/14.0/g' \
    -e "s/\$(SHOUM_GIT_COMMIT)/$GIT_COMMIT/g" \
    "$SRC_DIR/Info.plist" > "$APP/Contents/Info.plist"
plutil -lint -s "$APP/Contents/Info.plist"

printf 'APPL????' > "$APP/Contents/PkgInfo"

# Ad-hoc signature; locally-built means no quarantine, so Gatekeeper is happy
codesign --force --sign - \
    --entitlements "$SRC_DIR/Shoum.entitlements" \
    "$APP"

echo "Build complete: $APP"

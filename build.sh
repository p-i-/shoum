#!/bin/bash
# Builds Shoum.app with swiftc directly — no Xcode required, only the
# Command Line Tools (swiftc, codesign, plutil).
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$SCRIPT_DIR/Shoum"
BUILD_DIR="$SCRIPT_DIR/build"
APP="$BUILD_DIR/Shoum.app"

usage() {
    cat <<EOF
Builds Shoum.app into ./build (swiftc + ad-hoc sign; Command Line Tools only).

Usage: ./build.sh <--dev | --static> [--clean]

Build mode (one required — bare invocation just prints this help):
  --dev              link the clone's whisper dylibs by rpath (fast iteration);
                     compiles -Onone -g -D DEBUG so assertions (softAssert) are
                     LIVE — a broken invariant stops a dev run at the breakage
  --static           link the static archives (self-contained; used by
                     install.sh); compiles -O with assertions stripped —
                     production logs-and-degrades instead of stopping

Options:
  --clean            wipe ./build before building
  -h, --help         show this help

The app icon + menu-bar glyph are the committed assets/AppIcon.icns +
assets/menubar-glyph.png (generated locally by tools/icon-prep — gitignored).

Examples:
  ./build.sh --dev
  ./build.sh --static --clean
EOF
}

# Bare invocation is self-documenting: print usage and quit (don't build).
[ $# -eq 0 ] && { usage; exit 0; }

# --dev / --static pick how the VAD links against whisper.cpp (dylibs vs static).
STATIC=false
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --dev)    STATIC=false ;;
        --clean)  echo "Cleaning build directory..."; rm -rf "$BUILD_DIR" ;;
        --static) STATIC=true ;;
        *) echo "build.sh: unknown option '$1'" >&2; usage; exit 1 ;;
    esac
    shift
done

mkdir -p "$APP/Contents/MacOS"

# Unit tests for the pure text engines (CommandProcessor + TextSplicer) — run in
# BOTH modes: cheap (~2s), and install.sh going --static shouldn't skip them.
echo "Running unit tests..."
swiftc -Onone -target arm64-apple-macos14.0 \
    -o "$BUILD_DIR/shoum-tests" \
    "$SCRIPT_DIR/tests/run-tests.swift" \
    "$SRC_DIR/CommandProcessor.swift" \
    "$SRC_DIR/TextSplicer.swift"
"$BUILD_DIR/shoum-tests"

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
# Dev builds keep assertions live (fail fast at the broken invariant); static
# builds strip them (production logs and degrades). See softAssert in Log.swift.
if $STATIC; then OPT=(-O); else OPT=(-Onone -g -D DEBUG); fi
swiftc \
    "${OPT[@]}" \
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
# status --porcelain (not diff --quiet) so STAGED and UNTRACKED changes also
# mark the build dirty — a staged-only tree is not the stamped commit.
if [ "$GIT_COMMIT" != "unknown" ] && [ -n "$(git -C "$SCRIPT_DIR" status --porcelain 2>/dev/null)" ]; then
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

# App icon + menu-bar glyph: copy the committed final assets into the bundle
# (CFBundleIconFile=AppIcon in Info.plist; the glyph is loaded by AppDelegate).
# Copied before signing so the bundle seal covers them; install.sh inherits both
# via its cp -R of the bundle. Regenerate via tools/icon-prep (gitignored).
mkdir -p "$APP/Contents/Resources"
for asset in AppIcon.icns menubar-glyph.png; do
    src="$SCRIPT_DIR/assets/$asset"
    [ -f "$src" ] || { echo "ERROR: missing $src (regenerate with tools/icon-prep/make_appicon.py)"; exit 1; }
    cp "$src" "$APP/Contents/Resources/$asset"
done

# Code signature. Prefer the STABLE self-signed identity from
# tools/make-signing-cert.sh — it keeps the app's designated requirement (and so
# the macOS Accessibility/TCC grant) constant across rebuilds (ARCHITECTURE.md
# invariant 11). Falls back to ad-hoc when that identity isn't installed.
# Locally-built means no quarantine, so Gatekeeper is happy either way.
# The dedicated signing keychain's password is deliberately not a secret: the
# identity is a LOCAL self-signed cert whose only job is a stable designated
# requirement (TCC grant persistence) — it grants no trust anywhere else.
SHOUM_KC="$HOME/Library/Keychains/shoum-signing.keychain-db"
if [ -f "$SHOUM_KC" ]; then security unlock-keychain -p shoum "$SHOUM_KC" 2>/dev/null || true; fi
SIGN_ID="-"
if security find-identity -p codesigning 2>/dev/null | grep -q "Shoum Local Signing"; then
    SIGN_ID="Shoum Local Signing"
fi
echo "Signing: $([ "$SIGN_ID" = "-" ] && echo 'ad-hoc (Accessibility re-grant needed each upgrade)' || echo "$SIGN_ID (stable — grant persists)")"
codesign --force --sign "$SIGN_ID" \
    --entitlements "$SRC_DIR/Shoum.entitlements" \
    "$APP"

echo "Build complete: $APP"

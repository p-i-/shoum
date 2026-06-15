#!/bin/bash
# Speak — one-shot installer. Builds everything from source in this (disposable)
# clone and installs a THIN SpeakApp.app into /Applications (~4 MB: the static
# whisper-server binary + a tiny sample + config seeds). The heavy ~2 GB model
# assets are MOVED to a shared store (~/Library/Application Support/Speak/models)
# that both the installed app and any dev build reuse — never duplicated. So you
# can delete this checkout afterward.
#
# Re-run with --dev (developer iteration) to replace an existing install AND
# reset its Accessibility grant + UserDefaults, so each test starts genuinely
# fresh (clean permission + preference state). The shared model store is reused,
# so a re-run is cheap (no re-download, no re-convert).
#
# Developers iterating on the app want build.sh + run.sh instead (fast, runs
# from the clone with foreground logs). This script is for getting a real
# installed app.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

MODEL="medium.en"
APP_NAME="SpeakApp"
BUNDLE_ID="com.local.SpeakApp"
DEST_APP="/Applications/$APP_NAME.app"
BUILD_APP="$SCRIPT_DIR/build/$APP_NAME.app"
WHISPER_DIR="$SCRIPT_DIR/whisper.cpp"
INSTALL_BUILD="build-install"   # static build dir, kept separate from dev's build-coreml
VENV="$SCRIPT_DIR/.venv-coreml"
STORE="$HOME/Library/Application Support/Speak/models"   # shared model store

DEV=false
for arg in "$@"; do [ "$arg" = "--dev" ] && DEV=true; done

say()  { printf '\n=== %s ===\n' "$*"; }
die()  { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
say "Preflight"
# ---------------------------------------------------------------------------
[ "$(uname -m)" = "arm64" ] || die "Speak requires Apple Silicon (arm64). This Mac reports '$(uname -m)'."

# A running instance (dev or installed) fights this build over the left-shift
# event tap and the whisper-server port, and can't be cleanly replaced while in
# use. Detect it FIRST — before any build work — and bail clearly.
if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
    printf '\n⚠️  %s is already running.\n' "$APP_NAME"
    printf '   Quit it first (menu-bar icon → Quit Speak, or  pkill -x %s), then re-run.\n\n' "$APP_NAME"
    exit 1
fi

# Toolchain gate. This is a build-FROM-SOURCE install (for developers /
# contributors / early adopters); end users will get a prebuilt signed app. So
# collect EVERY missing prerequisite up front, advise how to install each, and
# quit before any heavy work — rather than die on the first and make the user
# re-run repeatedly.
missing=()

# Apple developer toolchain — clang, swiftc, python3, git, otool. Either the
# Command Line Tools OR full Xcode satisfies it. Verify with `xcrun --find`, NOT
# `command -v`: the bare /usr/bin/swiftc shim exists even when no real toolchain
# is installed, so `command -v swiftc` would falsely pass on a clean Mac.
if ! xcode-select -p >/dev/null 2>&1 \
   || ! xcrun --find swiftc >/dev/null 2>&1 \
   || ! xcrun --find clang  >/dev/null 2>&1; then
    missing+=("Apple developer toolchain (clang, swiftc, python3, git).
       Install:  xcode-select --install
       Full Xcode also works — if it's installed but not selected, run:
       sudo xcode-select -s /Applications/Xcode.app")
fi

# cmake — NOT bundled with the toolchain or macOS; needs separate install.
if ! command -v cmake >/dev/null 2>&1; then
    if command -v brew >/dev/null 2>&1; then
        missing+=("cmake.  Install:  brew install cmake")
    else
        missing+=("cmake.  Install Homebrew (https://brew.sh) then 'brew install cmake',
       or download it from https://cmake.org/download/")
    fi
fi

# python3 — used once for the ANE encoder conversion (ships with the toolchain,
# but flag it explicitly since it's the step most likely to surprise).
command -v python3 >/dev/null 2>&1 \
    || missing+=("python3 (used once for the ANE encoder). Ships with: xcode-select --install")

if [ ${#missing[@]} -gt 0 ]; then
    printf '\nCannot build — missing prerequisites:\n\n'
    for m in "${missing[@]}"; do printf '  • %s\n\n' "$m"; done
    die "Install the above, then re-run ./install.sh"
fi
echo "Toolchain OK — $(xcode-select -p); cmake $(cmake --version | head -1 | awk '{print $3}'); $(python3 --version 2>&1)."

if $DEV; then
    # Make a --dev install genuinely fresh:
    #  • Ad-hoc re-signing changes the binary fingerprint each build, so the old
    #    TCC grant (still shown ticked in System Settings) no longer applies —
    #    reset it so the next launch grants cleanly for the current binary.
    #  • UserDefaults persist in ~/Library/Preferences keyed by bundle id,
    #    independent of the .app, so old prefs (e.g. autoCloseSplash) survive a
    #    reinstall — clear them too.
    echo "Dev mode: resetting Accessibility + Microphone grants + preferences for $BUNDLE_ID (clean test)…"
    tccutil reset Accessibility "$BUNDLE_ID" || true
    tccutil reset Microphone   "$BUNDLE_ID" || true
    defaults delete "$BUNDLE_ID" 2>/dev/null || true
fi

if [ -e "$DEST_APP" ]; then
    if $DEV; then
        echo "Replacing existing $DEST_APP (--dev)…"
        rm -rf "$DEST_APP"
    else
        die "$DEST_APP already exists.
       Re-run with --dev to replace it, or first: rm -rf \"$DEST_APP\""
    fi
fi

# ---------------------------------------------------------------------------
say "whisper.cpp source + model"
# ---------------------------------------------------------------------------
if [ -d "$WHISPER_DIR" ]; then
    echo "whisper.cpp present, skipping clone."
else
    git clone https://github.com/ggml-org/whisper.cpp.git "$WHISPER_DIR"
fi

cd "$WHISPER_DIR"
# Present in the clone OR already moved to the shared store (re-run) → skip.
if [ -f "models/ggml-$MODEL.bin" ] || [ -f "$STORE/ggml-$MODEL.bin" ]; then
    echo "Model present (clone or shared store), skipping download."
else
    sh ./models/download-ggml-model.sh "$MODEL"
fi

# ---------------------------------------------------------------------------
say "Build whisper-server (static, CoreML/ANE)"
# ---------------------------------------------------------------------------
# BUILD_SHARED_LIBS=OFF is the whole game: it links libwhisper + the ggml
# backends INTO whisper-server, producing one fat binary with no @rpath dylib
# dependencies (only system frameworks). That's what makes a copy-one-file,
# clone-independent bundle possible. A shared build bakes absolute clone paths
# into the binary's rpaths and breaks the moment this checkout is deleted.
cmake -B "$INSTALL_BUILD" -DWHISPER_COREML=1 -DBUILD_SHARED_LIBS=OFF -DCMAKE_BUILD_TYPE=Release
cmake --build "$INSTALL_BUILD" -j --target whisper-server
SERVER_BIN="$WHISPER_DIR/$INSTALL_BUILD/bin/whisper-server"
[ -x "$SERVER_BIN" ] || die "whisper-server did not build at $SERVER_BIN"

# Fail loudly if the binary is NOT self-contained (any @rpath or this-clone
# path means it would break once the clone is removed).
if otool -L "$SERVER_BIN" | tail -n +2 | grep -qE '@rpath|@loader_path|'"$SCRIPT_DIR"; then
    otool -L "$SERVER_BIN"
    die "whisper-server still has non-system dynamic deps — bundle would not be self-contained."
fi
echo "whisper-server is self-contained (system frameworks only)."

# ---------------------------------------------------------------------------
say "Generate the ANE encoder (one-time python conversion)"
# ---------------------------------------------------------------------------
ENCODER="$WHISPER_DIR/models/ggml-$MODEL-encoder.mlmodelc"
# Present in the clone OR already moved to the shared store (re-run) → skip the
# heavy python conversion.
if [ -d "$ENCODER" ] || [ -d "$STORE/ggml-$MODEL-encoder.mlmodelc" ]; then
    echo "Encoder present (clone or shared store), skipping conversion."
else
    if [ ! -d "$VENV" ]; then
        echo "Creating python venv for the conversion (downloads torch etc. — a few GB, one-time)..."
        python3 -m venv "$VENV"
        "$VENV/bin/pip" install --upgrade pip
        "$VENV/bin/pip" install torch==2.5.0 coremltools openai-whisper ane_transformers
    fi
    echo "Converting (downloads a separate ~1.4GB openai checkpoint, builds the mlmodelc)..."
    PATH="$VENV/bin:$PATH" ./models/generate-coreml-model.sh "$MODEL"
    [ -d "$ENCODER" ] || die "encoder conversion did not produce $ENCODER"
fi

# ---------------------------------------------------------------------------
say "Build SpeakApp"
# ---------------------------------------------------------------------------
cd "$SCRIPT_DIR"
./build.sh
[ -d "$BUILD_APP" ] || die "SpeakApp build did not produce $BUILD_APP"

# ---------------------------------------------------------------------------
say "Stage self-contained app into /Applications"
# ---------------------------------------------------------------------------
# THIN bundle: code + tiny sample + config seeds only (~4 MB). The heavy ~2 GB
# model assets do NOT go in the bundle — they move to a shared store below, so
# they're never duplicated between this clone and the app.
cp -R "$BUILD_APP" "$DEST_APP"
RES="$DEST_APP/Contents/Resources"
mkdir -p "$RES/samples"

cp "$SERVER_BIN"                                  "$RES/whisper-server"
cp "$WHISPER_DIR/samples/jfk.wav"                 "$RES/samples/"
# Seeds for the user-editable files (copied to ~/Library/Application Support/Speak
# on first run). Ship the current repo files as defaults.
cp "$SCRIPT_DIR/config.yaml"                      "$RES/config.default.yaml"
cp "$SCRIPT_DIR/prompt.txt"                       "$RES/prompt.default.txt"

# Shared model store (Application Support — NOT Caches, which get purged). MOVE
# the assets in so the clone's copy BECOMES the single canonical copy: exactly
# one ~2 GB copy that both dev and installed runs resolve (Config.modelsDir).
mkdir -p "$STORE"
if [ -f "$STORE/ggml-$MODEL.bin" ]; then
    echo "model already in shared store — leaving the clone copy for you to remove."
else
    mv "$WHISPER_DIR/models/ggml-$MODEL.bin" "$STORE/"
fi
if [ -d "$STORE/ggml-$MODEL-encoder.mlmodelc" ]; then
    echo "encoder already in shared store — leaving the clone copy for you to remove."
else
    mv "$ENCODER" "$STORE/"
fi
echo "Model assets in shared store: $STORE"

# Re-sign inside-out: the staged binary first (must be independently valid to
# run on Apple Silicon), then the whole bundle (staging invalidated build.sh's
# seal). Ad-hoc — locally built, no quarantine, Gatekeeper is satisfied.
codesign --force --sign - "$RES/whisper-server"
codesign --force --sign - --entitlements "$SCRIPT_DIR/SpeakApp/SpeakApp/SpeakApp.entitlements" "$DEST_APP"
codesign --verify --strict "$DEST_APP" || die "final signature failed to verify"

# Final guard: confirm the STAGED binary is still self-contained.
if otool -L "$RES/whisper-server" | tail -n +2 | grep -qE '@rpath|@loader_path'; then
    die "staged whisper-server has @rpath deps — install is broken."
fi

APP_SIZE=$(du -sh "$DEST_APP" | awk '{print $1}')
echo "Installed: $DEST_APP ($APP_SIZE)"

# ---------------------------------------------------------------------------
say "Launch"
# ---------------------------------------------------------------------------
# Nothing else is running (preflight bails otherwise), so just launch — this
# kicks off the first-run Microphone + Accessibility prompts and the checklist.
open "$DEST_APP"
echo "Launched. Grant Microphone + Accessibility when prompted; the startup window walks you through it."

# ---------------------------------------------------------------------------
say "Done"
# ---------------------------------------------------------------------------
cat <<EOF
SpeakApp is installed at $DEST_APP (thin app, ~$APP_SIZE).
The ~2 GB model assets live ONCE in the shared store and are reused by both the
installed app and any dev build — no duplication:
    $STORE

This clone is now just a build workspace — you can delete it:
    rm -rf "$SCRIPT_DIR"

Conversion scratch you can reclaim (~2.3 GB) whether or not you keep the clone:
    rm -rf "$VENV"                 # the python venv
    rm -rf ~/.cache/whisper        # the openai checkpoint the converter downloaded

Config + logs live (installed mode) under:
    ~/Library/Application Support/Speak/   (config.yaml, prompt.txt, server.log)
EOF

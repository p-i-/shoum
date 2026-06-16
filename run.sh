#!/bin/bash
# Dev runner. Foreground only: logs stream to the terminal AND to log.txt (the
# app owns that file directly — no tee). Ctrl+C to quit.
#
# Single-instance policy — only one Shoum alive at a time, or a second instance
# fights the first over the left-shift event tap and the whisper-server port:
#   dev already running  -> refuse (you quit it)
#   installed running    -> stop it now, relaunch when this session ends
#   nothing running      -> nothing special

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_PATH="$SCRIPT_DIR/build/Shoum.app"
BINARY="$APP_PATH/Contents/MacOS/Shoum"
INSTALLED_APP="/Applications/Shoum.app"
INSTALLED_BIN="$INSTALLED_APP/Contents/MacOS/Shoum"

if [ ! -d "$APP_PATH" ]; then
    echo "App not found. Running build.sh first..."
    "$SCRIPT_DIR/build.sh"
fi

if [ ! -x "$BINARY" ]; then
    echo "ERROR: Binary not found or not executable: $BINARY"
    exit 1
fi

# config.yaml is git-ignored (local to this machine). Create it once from the
# tracked template so a fresh clone's dev build has an editable config.
if [ ! -f "$SCRIPT_DIR/config.yaml" ]; then
    cp "$SCRIPT_DIR/config.yaml.template" "$SCRIPT_DIR/config.yaml"
    echo "Created config.yaml from config.yaml.template"
fi

SERVER_PORT=$(grep -E "^server_port:" "$SCRIPT_DIR/config.yaml" 2>/dev/null | sed 's/[^0-9]//g')
SERVER_PORT=${SERVER_PORT:-8178}

# Detection is by full binary path, so the dev build (build/…) and the installed
# build (/Applications/…) can never be confused for each other.
if pgrep -f "$BINARY" >/dev/null 2>&1; then
    echo "A dev instance is already running. Quit it first, then re-run."
    echo "  pkill -f '$BINARY'"
    exit 1
fi

RELAUNCH_INSTALLED=false
if pgrep -f "$INSTALLED_BIN" >/dev/null 2>&1; then
    echo "Stopping the installed app for this dev session (relaunches on exit)..."
    pkill -f "$INSTALLED_BIN"
    RELAUNCH_INSTALLED=true
fi

echo "Starting Shoum..."
echo "(Press Ctrl+C to quit)"
echo ""

# whisper-server shrugs off SIGINT and survives the app dying, so make sure it
# goes down with this session; relaunch the installed app if we displaced it.
cleanup() {
    pkill -f "whisper-server.*--port $SERVER_PORT" 2>/dev/null
    if $RELAUNCH_INSTALLED; then
        echo ""
        echo "Relaunching the installed app..."
        open -a "$INSTALLED_APP"
    fi
}
trap cleanup EXIT

# The app owns log.txt; its logger also mirrors to stderr, so the terminal shows
# everything live without a tee fighting the app for the file.
"$BINARY"
EXIT_CODE=$?

if [ $EXIT_CODE -ne 0 ]; then
    echo ""
    echo "ERROR: Shoum exited with code $EXIT_CODE"

    CRASH_LOG=$(ls -t ~/Library/Logs/DiagnosticReports/Shoum* 2>/dev/null | head -1)
    if [ -n "$CRASH_LOG" ]; then
        echo "Crash log found: $CRASH_LOG"
        echo ""
        echo "=== Crash Summary ==="
        head -50 "$CRASH_LOG"
    fi
fi

#!/bin/bash
# Dev runner. Foreground by default (logs stream to the terminal AND to
# log.txt, which the app now owns directly — no tee). Pass --detached to run it
# in the background; logs still land in log.txt because the app writes its own
# file (that's what makes detached viable).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_PATH="$SCRIPT_DIR/build/SpeakApp.app"
BINARY="$APP_PATH/Contents/MacOS/SpeakApp"

DETACHED=false
[ "$1" = "--detached" ] && DETACHED=true

if [ ! -d "$APP_PATH" ]; then
    echo "App not found. Running build.sh first..."
    "$SCRIPT_DIR/build.sh"
fi

if [ ! -x "$BINARY" ]; then
    echo "ERROR: Binary not found or not executable: $BINARY"
    exit 1
fi

SERVER_PORT=$(grep -E "^server_port:" "$SCRIPT_DIR/config.yaml" 2>/dev/null | sed 's/[^0-9]//g')
SERVER_PORT=${SERVER_PORT:-8178}

if $DETACHED; then
    # The app writes log.txt itself, so we can throw away the process's stdio.
    # Leave whisper-server running after this script returns (that's the point).
    nohup "$BINARY" >/dev/null 2>&1 &
    echo "SpeakApp detached (pid $!)."
    echo "  app log:    $SCRIPT_DIR/log.txt"
    echo "  server log: $SCRIPT_DIR/server.log"
    echo "Stop it with:"
    echo "  pkill -f 'SpeakApp/Contents/MacOS/SpeakApp'; pkill -f 'whisper-server.*--port $SERVER_PORT'"
    exit 0
fi

echo "Starting SpeakApp..."
echo "(Press Ctrl+C to quit)"
echo ""

# whisper-server shrugs off SIGINT and survives the app dying, so make sure it
# goes down with this foreground session no matter how we exit.
trap 'pkill -f "whisper-server.*--port $SERVER_PORT" 2>/dev/null' EXIT

# The app owns log.txt; its logger also mirrors to stderr, so the terminal still
# shows everything live without a tee fighting the app for the file.
"$BINARY"
EXIT_CODE=$?

if [ $EXIT_CODE -ne 0 ]; then
    echo ""
    echo "ERROR: SpeakApp exited with code $EXIT_CODE"

    CRASH_LOG=$(ls -t ~/Library/Logs/DiagnosticReports/SpeakApp* 2>/dev/null | head -1)
    if [ -n "$CRASH_LOG" ]; then
        echo "Crash log found: $CRASH_LOG"
        echo ""
        echo "=== Crash Summary ==="
        head -50 "$CRASH_LOG"
    fi
fi

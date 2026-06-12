#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_PATH="$SCRIPT_DIR/build/SpeakApp.app"
BINARY="$APP_PATH/Contents/MacOS/SpeakApp"

if [ ! -d "$APP_PATH" ]; then
    echo "App not found. Running build.sh first..."
    "$SCRIPT_DIR/build.sh"
fi

if [ ! -x "$BINARY" ]; then
    echo "ERROR: Binary not found or not executable: $BINARY"
    exit 1
fi

echo "Starting SpeakApp..."
echo "(Press Ctrl+C to quit)"
echo ""

# whisper-server survives the app dying (it shrugs off SIGINT), so make sure
# it goes down with this script no matter how we exit
SERVER_PORT=$(grep -E "^server_port:" "$SCRIPT_DIR/config.yaml" 2>/dev/null | sed 's/[^0-9]//g')
SERVER_PORT=${SERVER_PORT:-8178}
trap 'pkill -f "whisper-server.*--port $SERVER_PORT" 2>/dev/null' EXIT

# Run and capture exit code; tee everything to log.txt so the output
# survives the terminal session
"$BINARY" 2>&1 | tee "$SCRIPT_DIR/log.txt"
EXIT_CODE=${PIPESTATUS[0]}

if [ $EXIT_CODE -ne 0 ]; then
    echo ""
    echo "ERROR: SpeakApp exited with code $EXIT_CODE"

    # Check for recent crash logs
    CRASH_LOG=$(ls -t ~/Library/Logs/DiagnosticReports/SpeakApp* 2>/dev/null | head -1)
    if [ -n "$CRASH_LOG" ]; then
        echo "Crash log found: $CRASH_LOG"
        echo ""
        echo "=== Crash Summary ==="
        head -50 "$CRASH_LOG"
    fi
fi

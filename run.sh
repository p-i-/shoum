#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_PATH="$SCRIPT_DIR/build/Build/Products/Debug/SpeakApp.app"
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

# Run and capture exit code
"$BINARY" 2>&1
EXIT_CODE=$?

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

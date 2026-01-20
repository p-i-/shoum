#!/bin/bash
set -e
WAV_FILE="$1"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WHISPER_CLI="$SCRIPT_DIR/whisper.cpp/build/bin/whisper-cli"
MODEL="$SCRIPT_DIR/whisper.cpp/models/ggml-medium.en.bin"

"$WHISPER_CLI" -m "$MODEL" -f "$WAV_FILE" --no-timestamps 2>/dev/null \
  | sed 's/^[[:space:]]*//' \
  | grep -v '^$'

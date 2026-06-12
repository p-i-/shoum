#!/bin/bash
# Debug/CLI transcription path. The app itself talks to a resident
# whisper-server (see ServerManager.swift); this script spawns a one-off
# whisper-cli with the same model, prompt, and settings.
set -e
WAV_FILE="$1"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MODEL="$SCRIPT_DIR/whisper.cpp/models/ggml-medium.en.bin"

# Prefer the CoreML/ANE build when present
if [ -x "$SCRIPT_DIR/whisper.cpp/build-coreml/bin/whisper-cli" ]; then
    WHISPER_CLI="$SCRIPT_DIR/whisper.cpp/build-coreml/bin/whisper-cli"
else
    WHISPER_CLI="$SCRIPT_DIR/whisper.cpp/build/bin/whisper-cli"
fi

PROMPT=""
if [ -f "$SCRIPT_DIR/prompt.txt" ]; then
    PROMPT="$(cat "$SCRIPT_DIR/prompt.txt")"
fi

"$WHISPER_CLI" -m "$MODEL" -f "$WAV_FILE" --no-timestamps -sns --prompt "$PROMPT" 2>/dev/null \
  | sed 's/^[[:space:]]*//' \
  | grep -v '^$'

#!/bin/bash
# Smoke test for the mic recording pipeline (same code path as the app).
# PASS = tap callbacks fire, all buffers convert and write, audio has signal.
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
BIN="/tmp/speak-mic-test"
swiftc -O -o "$BIN" "$DIR/mic-test.swift"
exec "$BIN"

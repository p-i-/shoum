#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

echo "=== Installing whisper.cpp ==="

if [ -d "whisper.cpp" ]; then
    echo "whisper.cpp directory already exists, skipping clone"
else
    echo "Cloning whisper.cpp..."
    git clone https://github.com/ggml-org/whisper.cpp.git
fi

cd whisper.cpp

if [ -f "models/ggml-medium.en.bin" ]; then
    echo "Model already downloaded, skipping"
else
    echo "Downloading medium.en model..."
    sh ./models/download-ggml-model.sh medium.en
fi

if [ -f "build/bin/whisper-cli" ]; then
    echo "Already built, skipping"
else
    echo "Building whisper.cpp..."
    cmake -B build
    cmake --build build -j --config Release
fi

echo ""
echo "=== Testing with JFK sample ==="
./build/bin/whisper-cli -m models/ggml-medium.en.bin -f samples/jfk.wav --no-timestamps 2>/dev/null | sed 's/^[[:space:]]*//' | grep -v '^$'

echo ""
echo "=== Installation complete ==="
echo "Now run: ./build.sh && ./run.sh"

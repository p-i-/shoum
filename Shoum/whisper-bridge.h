// Bridging header: exposes whisper.cpp's C API to Swift (compiled with bare
// swiftc via -import-objc-header; include paths supplied in build.sh). We use
// only the VAD entry points (whisper_vad_*), but pulling the whole header is
// harmless and keeps us in lockstep with the linked libwhisper.
#include "whisper.h"

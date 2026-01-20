# Speak

A macOS menu bar utility for speech-to-text using whisper.cpp.

## Features

- **Hold-to-talk**: Hold left-shift (>300ms) to record, release to transcribe
- **Editable overlay**: Transcribed text appears in a floating editor
- **Multi-chunk dictation**: Keep recording additional chunks, edit between them
- **Quick paste**: Tap left-shift to copy all text and paste to previous app

## Requirements

- macOS 13.0+
- Xcode Command Line Tools
- Microphone access
- Accessibility permissions (for global hotkey)

## Installation

```bash
# Install whisper.cpp and download the model
./install.sh

# Build the app
./build.sh

# Run the app
./run.sh
```

## Usage

1. Run `./run.sh` - the app appears in your menu bar
2. Open any app where you want to paste text (e.g., a text editor, chat)
3. **Hold left-shift** for 300ms+ to start recording
4. Speak your text
5. **Release left-shift** to transcribe
6. Edit the text if needed (it's a full text editor)
7. **Tap left-shift** to paste to the previous app and dismiss
8. Or press **Escape** to cancel

### Multi-chunk recording

While in the editor, hold left-shift again to record another chunk. The new transcription inserts at the cursor position, so you can build up text from multiple dictation chunks.

## Permissions

On first run, you'll be prompted for:

1. **Microphone access** - for recording speech
2. **Accessibility** - for global hotkey monitoring and paste simulation

Grant these in System Settings → Privacy & Security.

## Files

```
speak/
├── install.sh          # Install whisper.cpp
├── build.sh            # Build the app (--clean for fresh build)
├── run.sh              # Run the app
├── process_wav.sh      # Whisper transcription script
├── whisper.cpp/        # Whisper.cpp installation
└── SpeakApp/           # Xcode project
```

## Troubleshooting

**No menu bar icon**: Check that the app built successfully with `./build.sh`

**Hotkey not working**: Grant Accessibility permissions in System Settings

**No transcription**: Check microphone permissions and that whisper.cpp installed correctly

**Black text in overlay**: This was a bug - if you see it, rebuild with `./build.sh --clean`

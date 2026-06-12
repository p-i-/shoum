# Speak

Local, private speech-to-text for macOS, living in your menu bar. Powered by
whisper.cpp (medium.en) with the encoder running on the Apple Neural Engine.
Everything — audio, transcription, vocabulary biasing — stays on your machine.

The entire interface is the **left shift key**:

| gesture | action |
|---|---|
| double-tap | start recording (🎙️ marks where text will land) |
| single tap (while recording) | stop & transcribe |
| double-tap **and hold** | push-to-talk: release stops |
| single tap (while editing) | paste result into the previous app |
| Escape | dismiss |

Yes, one modifier key carries the whole app. Normal shift use (capitals,
shift-click) never triggers anything: any intervening keystroke cancels the
gesture.

## Features

- **Resident whisper-server** — the model loads once at launch, not per
  utterance. Typical dictation round-trip: well under a second.
- **ANE-accelerated encoder** — Core ML runs the whisper encoder on the
  Neural Engine, ~1.65x faster than Metal, GPU left free.
- **Startup checklist splash** — every subsystem (permissions, mic, model
  files, server phases, a real test inference) gets a live ✅/❌ row.
  Dictation is gated until the system is actually ready.
- **Live spectrogram** — a scrolling viridis strip in the dictation box shows
  exactly what the mic hears; yellow flatline means the mic is off.
- **In-text state markers** — 🎙️ shows where the next utterance will land,
  🧠 means transcription in flight, then it becomes your text.
- **Smart splicing** — chunks are case/punctuation/spacing-adjusted to fit
  their insertion point (whisper emits standalone sentences; mid-sentence
  insertions get lowercased, doubled periods dropped, selections inherit
  capitalization).
- **Domain vocabulary** — `prompt.txt` biases transcription toward your
  jargon (default: AI/ML engineering terms).
- **Multi-chunk dictation** — keep double-tapping to add chunks at the
  cursor; edit freely in between.

## Requirements

- Apple Silicon Mac, macOS 13.0+
- Xcode (for building; Command Line Tools alone can't build the .app)
- cmake
- ~4GB disk (whisper.cpp + models), ~2GB RAM while running

## Install

```bash
git clone <this repo> && cd speak
./install.sh      # clones whisper.cpp, downloads ggml-medium.en, builds (Metal)
./build.sh        # builds SpeakApp
./run.sh          # runs it (terminal stays open; Ctrl+C quits everything)
```

On first run, grant **Microphone** and **Accessibility** permissions (System
Settings → Privacy & Security). The startup splash walks you through what's
missing.

### Optional: Neural Engine (ANE) acceleration

The default install runs whisper on Metal. For the ~1.65x faster ANE encoder:

```bash
cd whisper.cpp
cmake -B build-coreml -DWHISPER_COREML=1 -DCMAKE_BUILD_TYPE=Release
cmake --build build-coreml -j --target whisper-server whisper-cli

# Generate the CoreML encoder model (needs a python env with
# torch, coremltools, openai-whisper, ane_transformers — see
# models/requirements-coreml.txt):
python3 -m venv ../.venv-coreml
../.venv-coreml/bin/pip install torch==2.5.0 coremltools openai-whisper ane_transformers
PATH="../.venv-coreml/bin:$PATH" ./models/generate-coreml-model.sh medium.en
```

The app prefers `build-coreml` automatically (set `use_ane: false` in
config.yaml to force Metal). The first ANE load triggers a one-time ~35s
compile, cached by macOS afterwards — the splash shows it counting.

## Configuration

`config.yaml` at the repo root — flat `key: value` lines, `#` comments,
restart the app to apply, missing keys fall back to defaults:

| key | default | meaning |
|---|---|---|
| `model` | `medium.en` | which `whisper.cpp/models/ggml-<model>.bin` |
| `use_ane` | `true` | CoreML/ANE build vs plain Metal |
| `server_port` | `8178` | whisper-server port (localhost only) |
| `server_args` | _empty_ | extra whisper-server flags, space-separated |
| `double_tap_window_ms` | `350` | max gap between taps |
| `tap_max_ms` | `250` | longer presses aren't taps |
| `hold_release_ms` | `400` | double-tap-and-hold ≥ this: release stops |
| `hotkey_keycode` | `56` | 56 = left shift, 60 = right shift |
| `sounds` | `true` | Tink/Pop/Glass feedback |
| `paste_mode` | `paste` | `paste` = Cmd+V into previous app; `copy` = clipboard only |

Vocabulary biasing lives in `prompt.txt` (free prose; whisper takes ~220
tokens of it as the initial prompt; restart to apply).

## Debugging

The app is built to be diagnosable without a debugger:

- **`log.txt`** — everything the app prints (run.sh tees it). Gesture
  decisions with millisecond timings, recording start/stop, transcription
  results, server retries.
- **`server.log`** — whisper-server's own output (model load phases,
  per-request errors). Truncated each launch.
- **`tools/mic-test.sh`** — standalone 3s smoke test of the exact
  mic→16kHz→WAV pipeline the app uses; prints PASS/FAIL per stage.
- **The splash** (menu bar → Show Status…) doubles as the diagnostic panel;
  it reopens itself if a check fails.

## Architecture

```
SpeakApp (Swift, menu bar, LSUIElement)
├── KeyMonitor        CGEventTap on flagsChanged+keyDown; double-tap state
│                     machine driven by HARDWARE timestamps (see below)
├── AppStateCoordinator   idle → recording → processing → editing
├── AudioRecorder     one AVAudioEngine, prepared at launch; taps mic,
│                     converts to 16kHz mono WAV; feeds SpectrogramView
├── Transcriber       HTTP client → localhost whisper-server /inference
├── ServerManager     owns the resident whisper-server child process
├── ReadinessChecker  startup checklist; tails server.log markers,
│                     runs a real test inference
├── OverlayWindow     floating editor; 🎙️/🧠 marker; smartJoin splicing
├── SpectrogramView   vDSP FFT → scrolling viridis timeline
└── SplashWindow      live checklist UI
```

Hard-won lessons encoded in this design (do not regress these):

1. **Never measure key-press durations with processing-time clocks.** The
   event tap delivers on the main run loop; anything blocking main inflates
   apparent durations. `CGEvent.timestamp` (hardware time) is the only truth.
   Its units vary by system — KeyMonitor calibrates them against the system
   clock at runtime and logs the choice.
2. **AVAudioConverter with rate conversion returns `.inputRanDry` for the
   normal single-buffer case** — its output frames are still valid. Dropping
   them silently records empty files.
3. **whisper-server reports some failures as HTTP 200 with an error-JSON
   body**; Transcriber checks for that.
4. **The ANE compile cache is fragile** (entries evict each other; running
   whisper-cli benchmarks evicts the server's entry). Expect occasional ~35s
   recompiles; the splash makes them visible.
5. **Every failure path logs.** If something breaks silently, the bug is
   that it broke silently.

## Roadmap / TODO

- **LLM "jiggle"**: long-press shift (release between ~0.2–0.5s, only valid
  because intervening keystrokes already cancel — so holding shift to type a
  capital never fires it) sends the box text + cursor marker to a local LLM
  (llama-server, same resident pattern) for whole-text repair: spoken
  punctuation ("comma", "full stop"), capitalization, flubs. Same channel
  handles spoken commands ("command: reformat as a list"). Must be
  cancellable (ESC) and undoable. Config: `llm_url` (OpenAI-compatible) so
  local/cloud is one knob.
- **Proper .app distribution**: Release build, Developer ID signing +
  notarization, model download on first run (host the CoreML encoder as a
  release artifact — end users should never need the python conversion env),
  paths moved from repo-relative to ~/Library/Application Support, logs to
  ~/Library/Logs, "Start at login" via SMAppService. Then a Homebrew cask in
  a personal tap.
- **Gesture state machine extraction** — pure `(event, time) → action`
  function with replay tests from recorded traces (log.txt format already
  captures them).
- **`tools/doctor.sh`** — the full atomic diagnostic suite for bug reports
  (the splash covers the interactive case).
- **Spoken-punctuation mode** — a punctuation-free variant of prompt.txt
  biases whisper away from auto-punctuation, for those who dictate
  punctuation explicitly.
- Cancellable Transcriber (ESC during processing currently can't abort the
  in-flight request).

## License / credits

Built on [whisper.cpp](https://github.com/ggml-org/whisper.cpp) (MIT) and
OpenAI's Whisper models. Viridis colormap from matplotlib (CC0).

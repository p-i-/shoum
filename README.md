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

## Why not just use macOS dictation (or Claude Code's voice input)?

If you dictate to Claude Code on macOS, the two stock options both get in the
way of technical work.

**macOS built-in dictation** types straight into whatever control is focused,
and three problems compound:

- It mishears domain vocabulary — "Gaussian", "transformer", "tokenizer" come
  out wrong, so you spend half your time correcting it.
- It targets the OS's focused text field directly, but macOS has many kinds of
  text input; dictation works in some and silently not in others.
- The dictation daemon sporadically wedges, with no reliable way to reset it
  short of a reboot — painful when you have long-running work (a Dockerized VM,
  say) you don't want to kill.

**Claude Code's own voice input** is over-eager: it commits every short phrase
as you speak, so you ping-pong between watching the output and holding onto
your next thought — it interrupts the very train of thought you're trying to
get down.

**Speak fixes the shape of the interaction.** Everything you say lands first in
a private floating box that *you* own:

- You speak a whole thought (or several chunks), read it back, and edit it
  freely — nothing reaches Claude until you single-tap to paste. No premature
  insertion, no interruption of your flow.
- The result is pasted with ⌘V, so it works in every input surface, not "some
  but not others".
- `prompt.txt` biases whisper toward your jargon, so "Gaussian" and
  "transformer" come out right.
- The whisper server is a child process this app owns and restarts on crash —
  no opaque daemon you can't reset.

The whole interface is one key (left shift), and you decide when the text lands.

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
  cursor; edit freely in between, and ⌘Z undoes a dictated chunk.

## Requirements

- Apple Silicon Mac, macOS 13.0+
- Xcode Command Line Tools (`xcode-select --install`) — no Xcode needed;
  the app builds with plain `swiftc`
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

No Xcode project: `build.sh` compiles `SpeakApp/SpeakApp/*.swift` with
swiftc, assembles the bundle, and ad-hoc signs it. Adding a source file means
dropping it in that directory — nothing to register anywhere.

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

See [TODO.md](TODO.md) for the full forward path with rationale. In short:

- **Homebrew distribution** (active next project) — `brew install
  p-i-/tap/speak`, compile-from-source formula, Apple Silicon only, CoreML
  encoder hosted as a release artifact so users never run the python
  conversion. No Apple Developer account needed.
- **LLM "jiggle"** — long-press shift to send the whole box to a local LLM
  for repair (spoken punctuation, capitalization, flubs) and spoken commands.
- Smaller debts: cancellable Transcriber, gesture state-machine extraction +
  replay tests, `tools/doctor.sh`, spoken-punctuation mode.

## License / credits

Built on [whisper.cpp](https://github.com/ggml-org/whisper.cpp) (MIT) and
OpenAI's Whisper models. Viridis colormap from matplotlib (CC0).

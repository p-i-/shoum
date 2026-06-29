# Shoum

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
| Escape | cancel recording, then close the box |
| ⌘Z / ⌘⇧Z | undo / redo a dictated chunk |

Normal shift use (capitals, shift-click) never triggers anything: any
intervening keystroke cancels the gesture.

## Why not just use macOS dictation (or Claude Code's voice input)?

**macOS built-in dictation** types into whatever control is focused, and three
problems compound: it mishears domain vocabulary ("Gaussian", "transformer",
"tokenizer"); it works in some text fields and silently not others; and the
dictation daemon sporadically wedges with no reset short of a reboot.

**Claude Code's own voice input** commits every short phrase as you speak, so you
ping-pong between watching output and holding your next thought — it interrupts
the train of thought you're trying to get down.

**Shoum fixes the shape of the interaction.** Everything you say lands first in a
private floating box that *you* own: speak a whole thought (or several chunks),
read it back, edit freely — nothing reaches the target app until you single-tap
to paste. The result is pasted with ⌘V (works in most input surfaces, not "some
but not others"); `prompt.txt` biases whisper toward your jargon; and the whisper
server is a child process this app owns and restarts on crash — no opaque daemon.

## Requirements

- Apple Silicon Mac, macOS 14.0+
- Apple developer toolchain — **Xcode Command Line Tools** (`xcode-select --install`)
  or full Xcode; provides `clang`, `swiftc`, `python3`, `git`
- `cmake` (`brew install cmake`) — not bundled with the toolchain
- ~4 GB disk during install; ~2 GB resident model after

`install.sh` checks for all of these up front and tells you exactly what to install
if anything's missing. (This builds from source — it's the developer/contributor
path; a prebuilt signed app is the planned end-user distribution.)

## Install

```bash
git clone <this repo> && cd speak
./install.sh
```

`install.sh` builds everything from source and installs a self-contained app:

- builds a **static** `whisper-server`, downloads the model, generates the ANE
  encoder (one-time python conversion);
- builds `Shoum` and stages a **thin** `Shoum.app` into `/Applications`;
- **moves** the ~2 GB model assets into a shared store
  (`~/Library/Application Support/Shoum/models`) — one copy, reused by any future
  dev build, never duplicated;
- launches the app (triggers the first-run **Microphone** + **Accessibility**
  prompts; the Status window walks you through anything missing).

The clone is then just a build workspace you can `rm -rf`. **There is no in-place
upgrade in v1** — to reinstall, delete `/Applications/Shoum.app` first.

### Developing

Skip the installer and iterate from the clone:

```bash
./build.sh --dev   # compile Shoum.app into ./build (run with no args for help)
./run.sh     # foreground, logs stream to terminal + log.txt; Ctrl+C to quit
```

`run.sh` enforces one instance at a time: it refuses to start if a dev build is
already running, and temporarily stops the installed app (relaunching it when
you quit) so the two never fight over the hotkey and the whisper-server.

The first run from a fresh clone also needs whisper.cpp built + the model; the
easiest path is to run `install.sh` once (it leaves the shared model store in
place), after which dev builds resolve the model from there.

To push a **Swift-only change into the already-installed app** (without the full
delete-and-reinstall, which needlessly rebuilds whisper-server and the encoder):

```bash
./upgrade.sh   # static rebuild → swap binary into /Applications/Shoum.app → re-sign
```

It quits the running app, swaps in the new binary (keeping the bundle's
whisper-server), re-signs, and resets the Accessibility grant — which **must** be
re-granted after every upgrade because ad-hoc signing changes the code hash each
build (the script prints the steps; the app arms the hotkey live once you grant).
Use `upgrade.sh` only for app-code changes; an engine/model/server change still
needs a full reinstall.

## Configuration

Edit via the **Settings tab** (click the menu-bar icon → Settings…) or edit
`config.yaml` directly — both are equivalent; the Settings pane writes the same
file with a surgical per-line edit that preserves comments. **Restart to apply.**

`config.yaml` location: the clone root in dev; `~/Library/Application
Support/Shoum/config.yaml` when installed (seeded from a bundled default on first
run). Flat `key: value` lines, comments on their own lines, missing keys fall
back to defaults.

| key | default | meaning |
|---|---|---|
| `model` | `medium.en` | which `ggml-<model>.bin` to load |
| `model_dir` | _empty_ | model store path; empty = shared default |
| `use_ane` | `true` | CoreML/ANE build vs plain Metal |
| `server_port` | `8178` | whisper-server port (localhost only) |
| `server_args` | _empty_ | extra whisper-server flags, space-separated |
| `log_level` | `info` | `error` \| `info` \| `debug` |
| `double_tap_window_ms` | `350` | max gap between taps |
| `tap_max_ms` | `250` | longer presses aren't taps |
| `hold_release_ms` | `400` | double-tap-and-hold ≥ this: release stops |
| `hotkey_keycode` | `56` | 56 = left shift, 60 = right shift |
| `sounds` | `true` | Tink/Pop/Glass feedback |
| `paste_mode` | `paste` | `paste` = ⌘V into previous app; `copy` = clipboard only |
| `keep_recordings` | `true` | retain WAVs in `/tmp/shoum/wavs` for 24h (debugging) |
| `min_speech_dbfs` | `-60` | clips never louder than this are treated as no-speech (skip whisper) |
| `prune_dead_audio` | `true` | Silero VAD removes silence before transcribing (cleaner punctuation; more speech per 30s window). Falls back to sending raw audio if the VAD model is missing |
| `check_for_updates` | `true` | check GitHub on launch; notify in the menu if a newer build exists |

Vocabulary biasing lives in `prompt.txt` (free prose; whisper takes ~220 tokens
as its initial prompt). Edit it in the Settings tab or directly (same locations
as config.yaml). **Start at login** is a checkbox in Settings (installed app
only).

## Where things live

| | dev | installed |
|---|---|---|
| app | `./build/Shoum.app` | `/Applications/Shoum.app` |
| config / prompt | clone root | `~/Library/Application Support/Shoum/` |
| model + encoder | shared store (or clone `whisper.cpp/models`) | `~/Library/Application Support/Shoum/models/` |
| app log | clone `log.txt` | `~/Library/Logs/Shoum/shoum.log` |
| server log | clone `server.log` | `~/Library/Application Support/Shoum/server.log` |

## Debugging

- **App log** — every gesture decision (with ms timings at `log_level: debug`),
  recording start/stop, transcription results, server retries.
- **server.log** — whisper-server's own output (model load phases, per-request
  errors). Truncated each launch.
- **`tools/mic-test.sh`** — standalone smoke test of the mic→16kHz→WAV pipeline.
- **Status tab** (click the menu-bar icon → Status…) — live ✅/❌ per subsystem, the
  install paths, and **Open Settings…** deep-links for missing permissions.

## Known limitations

- **Paste coverage.** Output is delivered via a synthetic ⌘V, which works in
  almost every text surface but **not** secure-input fields (e.g. password
  fields) or apps that block synthetic key events. In those, switch
  `paste_mode: copy` and paste manually.
- **Idle footprint.** whisper-server is resident from launch (~2 GB RAM) so the
  first dictation is instant. As a login-item app that's held all day.

## Architecture

See [ARCHITECTURE.md](ARCHITECTURE.md) for the component map, run-mode/path
resolution, the install layout, and the hard-won invariants. Forward path in
[TODO.md](TODO.md).

## License / credits

Built on [whisper.cpp](https://github.com/ggml-org/whisper.cpp) (MIT) and
OpenAI's Whisper models. Viridis colormap from matplotlib (CC0).

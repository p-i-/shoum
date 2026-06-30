# Shoum — Architecture

Component map, runtime layout, and the hard-won invariants. For the user-facing
overview see [README.md](README.md); for the forward path see [TODO.md](TODO.md).

## Build

No Xcode project. `build.sh` compiles `Shoum/Shoum/*.swift` with `swiftc`,
assembles the `.app` bundle, writes Info.plist, and **ad-hoc signs** it
(`codesign --sign -`). A locally-built binary has no quarantine attribute, so
Gatekeeper is satisfied and ad-hoc signing is enough for TCC (mic/accessibility).
Adding a source file means dropping it in that directory — nothing to register.

- `build.sh` — compile the app (dev).
- `run.sh` — run from the clone, foreground logs; one instance at a time (stops/relaunches the installed app so they don't fight).
- `install.sh` — the user-facing installer (see "Install layout" below).
- `upgrade.sh` — **in-place upgrade of the installed app for Swift-only changes.**
  Rebuilds `--static`, swaps just the binary + Info.plist into
  `/Applications/Shoum.app` (keeping the bundle's `whisper-server` Resource —
  see invariant 11), re-signs, and resets the stale Accessibility grant. Use this
  to push app-code changes to a running installed app without the full
  delete-and-`install.sh` (which needlessly rebuilds whisper-server + the encoder).
  Only the Swift app changed → `upgrade.sh`; engine/model/server change → reinstall.

## Components

```
Shoum (Swift, menu bar, LSUIElement)
├── main.swift          NSApplication bootstrap
├── AppDelegate         status item (any click → menu: status line, Status/
│                       Settings/About, Update, Quit), tray icon state + colour,
│                       first-run permission onboarding (sequenced dialogs)
├── UpdateChecker       notify-only: GitHub latest-commit vs stamped ShoumGitCommit
├── Config              config.yaml loader + path resolution + surgical writer
├── Log                 leveled logger → app log file + stderr
├── KeyMonitor          CGEventTap on flagsChanged+keyDown; double-tap state
│                       machine driven by HARDWARE timestamps (see invariants)
├── AppStateCoordinator idle → recording → processing → editing
├── AudioRecorder       one AVAudioEngine, prepared at launch; taps mic,
│                       converts to 16kHz mono WAV; feeds SpectrogramView
├── Transcriber         HTTP client → localhost whisper-server /inference
├── ServerManager       owns the resident whisper-server child process
├── ReadinessChecker    startup checklist; tails server.log markers; real test inference
├── OverlayWindow       floating editor; 🎙️/🧠 marker; smartJoin splicing
├── SileroSpeechDetector  the speech/silence VAD (whisper.cpp whisper_vad_*, CPU,
│                       linked via whisper-bridge.h). classify→[Bool] for the
│                       spectrogram colours + gauge; speechSegments→ranges for the
│                       culler. No energy fallback: if the model can't load, the
│                       spectrogram greys out and culling is skipped (raw audio
│                       sent). build.sh (dev: clone dylibs) / --static (install).
├── SilenceCuller       on stop, re-VADs the recording and writes a silence-removed
│                       "kebab" WAV (prune_dead_audio) — only speech reaches whisper.
├── SpectrogramColumnSource  vDSP FFT → dBFS → viridis (speech) / grey (silence)
│                       columns + a green box around each speech run; accumulates
│                       the speech budget (producer)
├── ColumnRing          lock-protected ring of RGBA columns (producer↔consumer)
├── SpectrogramView     CADisplayLink consumer; sub-pixel scroll; emits speech-
│                       budget updates (seconds + active) to the fuel gauge
├── FuelGaugeView       speech-budget meter: fill toward the 30s whisper window
│                       (green active / white paused), a red bar per completed
│                       window, squash-to-fit on overflow
├── SplashWindow        tabbed Status/Settings window; settings apply instantly
│                       (no Save button — toggles on change, fields on commit)
└── ClipboardManager    remember/refocus frontmost app; deliver the result via
                        ⌘V — or, in terminals (type_into_terminals), by keystroke
                        injection (Shift+Return for newlines) so Claude Code
                        doesn't fold it into a "[Pasted N lines]" placeholder
```

## Run modes & on-disk layout

Mode is detected by the **install location itself** — no env var. A
`whisper-server` file inside the bundle's `Resources` means "installed";
otherwise the app walks up to find the clone ("dev"). `Config` resolves three
roots:

| | dev (run.sh) | installed (/Applications) |
|---|---|---|
| **resourceRoot** (binary, sample wav) | the clone | `…app/Contents/Resources` |
| **dataRoot** (config.yaml, prompt.txt, server.log) | the clone | `~/Library/Application Support/Shoum` |
| **model store** (`.bin` + `-encoder.mlmodelc`) | shared store, else clone `whisper.cpp/models` | shared store |
| **app log** | clone `log.txt` | `~/Library/Logs/Shoum/shoum.log` |

**Shared model store** = `~/Library/Application Support/Shoum/models` (overridable
via `model_dir`). The heavy ~2 GB assets live there **once** and are reused by
both dev and installed runs — no duplication. `install.sh` *moves* them out of
the clone into the store, so deleting the clone leaves exactly one copy. Chosen
over baking the model into the bundle (a "fat self-contained .app") precisely to
avoid that duplication; since distribution is compile-from-source, the bundle
never needed to carry the model.

Installed-mode user files are seeded once from bundled `config.default.yaml` /
`prompt.default.txt` on first run, so the data dir survives deletion.

## Install layout (install.sh)

1. Preflight (arm64, CLT, cmake, swiftc, python3); refuse if the app already
   exists (**no v1 upgrade path** — reinstall = delete then install).
2. Clone whisper.cpp, download the model.
3. Build `whisper-server` **static** (`-DBUILD_SHARED_LIBS=OFF`) → one fat
   binary with no `@rpath` dylib deps. Asserts self-containment via `otool -L`.
4. Generate the ANE encoder (one-time python conversion).
5. Build Shoum, stage a **thin** bundle (binary + sample + config seeds, ~4 MB).
6. `mv` the model assets into the shared store.
7. Re-sign inside-out (nested binary first, then the bundle), verify, launch.

## Hard-won invariants (DO NOT REGRESS)

1. **Never measure key-press durations with processing-time clocks.** The event
   tap delivers on the main run loop; main-thread work inflates apparent
   durations. `CGEvent.timestamp` (hardware time) is the only truth. Its units
   vary by system — `KeyMonitor` calibrates against the system clock at runtime.
2. **`AVAudioConverter` with rate conversion returns `.inputRanDry`** for the
   normal single-buffer case; its output frames are still valid. Dropping them
   records empty files.
3. **whisper-server reports some failures as HTTP 200 with an error-JSON body**;
   `Transcriber` checks for that.
4. **The ANE compile cache is fragile** (entries evict each other; running
   whisper-cli benchmarks evicts the server's entry). Expect occasional ~35 s
   recompiles. macOS caches the compiled blob but it's evictable and not
   ship-able — there is no supported way to pin or relocate it.
5. **The CoreML encoder is resolved relative to the `.bin`.** The `mlmodelc`
   MUST be a sibling of the model file in the same dir (true in both the clone's
   `whisper.cpp/models` and the shared store).
6. **whisper-server is dylib-linked in a shared build.** Its `@rpath` deps point
   at absolute clone paths, so the installed app uses a **static** build instead
   (see install.sh). Don't ship the shared binary.
7. **Never set `contentTintColor` on a template SF Symbol in an
   `NSStatusBarButton`** — it renders nothing (the menu-bar vibrancy compositor
   and the forced tint don't reconcile; the button reports fully healthy while
   drawing zero pixels). Colour a tray icon via
   `NSImage.SymbolConfiguration(hierarchicalColor:)` (a non-template coloured
   image); use a plain template image when uncoloured. (Cost us two
   misdiagnoses — see invariant 9.)
8. **Every failure path logs.** If something breaks silently, the bug is that it
   broke silently.
9. **Unobservable subsystem → instrument before theorising.** The tray bug was
   misdiagnosed twice from plausible mental models; it fell in one read once the
   button's actual state was dumped (a controlled `tint=nil` vs `tint=green`
   comparison). Compiling ≠ working. When something is hard to see, add the
   observation first; don't guess-and-rebuild.
10. **Sequence permission dialogs; never fire the Accessibility prompt at
    launch.** Auto-prompting it at startup (the pre-v1.0 bug) stacks it with the
    mic dialog as an unanchored popup before any window exists. Fire it only
    AFTER the mic dialog resolves and the window is foregrounded
    (`AppDelegate.autoPromptAccessibilityIfNeeded`). `AXIsProcessTrustedWithOptions`
    is one-shot — it registers the app and shows the dialog only until then — so
    the Status window's "Open Settings…" button must NAVIGATE to the pane (URL),
    not re-call the prompt. As an `LSUIElement` app we can't reliably hold
    activation through the System-Settings round-trip: `orderFrontRegardless`
    plus a one-shot post-onboarding re-foreground bring our window back (Stage
    Manager can still override — accept it; the green tray is the done-signal).
11. **Ad-hoc signing rebinds the Accessibility (TCC) grant on every build.**
    `codesign --sign -` mints a fresh code hash each compile, and macOS keys the
    Accessibility grant to that hash. So after any binary swap (`upgrade.sh`, or a
    manual `cp` into the installed bundle) the prior grant is STALE: the System
    Settings checkbox still shows "on" but `AXIsProcessTrusted()` returns false
    and toggling it does nothing (it re-applies the same stale binding). The fix
    is `tccutil reset Accessibility org.pipad.shoum` then relaunch so the app
    re-prompts clean — `upgrade.sh` does this automatically. Mic (a different TCC
    class) survives. Don't waste time re-toggling the checkbox — reset.
    **Permanent cure (implemented): `tools/make-signing-cert.sh`** installs a
    stable self-signed code-signing identity ("Shoum Local Signing", in a
    dedicated keychain) so the designated requirement is identity-based, not
    hash-based, and the grant then persists across rebuilds. `build.sh` signs with
    it when present (ad-hoc fallback otherwise) and `upgrade.sh` skips the reset.
    Only the one-time ad-hoc→cert transition still costs a single re-grant.
12. **Hot-swap upgrades must preserve `Contents/Resources/whisper-server`.** Its
    presence is the *only* signal for `Config.isInstalled`. Copying the whole dev
    `build/Shoum.app` over the installed one drops it and silently flips the app
    to dev path resolution. `upgrade.sh` copies only the binary + Info.plist for
    exactly this reason.
13. **A synthetic ⌘V is read by the target when IT processes the event**, which a
    busy terminal can defer well past when we post it. So restoring the clipboard
    too soon lets that deferred read grab the *restored* value instead of the
    payload (observed: pasted text replaced by stale clipboard content). Restore
    only after a generous delay (1 s) or not at all (`restore_clipboard`). And do
    NOT cycle the clipboard mid-paste to "chunk" a multi-line paste — it multiplies
    this race into reliable data loss (an abandoned approach; see git history). One
    clipboard set + one ⌘V is the only race-free clipboard paste.
14. **Claude Code's "[Pasted N lines]" collapse is avoided ONLY by raw typed
    keystrokes, never a bracketed paste.** It's a Claude-Code TUI feature keyed on
    bracketed-paste size, with no setting to disable it. Wrapping injected text in
    bracketed-paste markers (`ESC[200~…ESC[201~`) *recreates* the placeholder. So
    `ClipboardManager.typeToRememberedApp` must stay raw key events +
    `Shift+Return` newlines — don't "optimise" it into a clipboard ⌘V or a
    bracketed-paste block. (Terminals only — gated by `type_into_terminals` and a
    bundle-id allowlist; editors with embedded terminals can't be detected.)

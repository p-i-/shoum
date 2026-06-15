# Speak — Roadmap & Handoff

Forward path with the reasoning behind every decision, so a fresh session (or
contributor) can pick up without re-deriving it. Read this top-to-bottom before
starting.

The **active arc is v1.0** (§2): turn Speak from a repo-tethered dev tool into a
real, installable, professional macOS app that other people can use. Everything
below v1.0 is either already done (§1), deferred until justified (§4), a small
debt (§5), or a do-not-regress invariant (§6).

**Scope policy (decided this project):** this is meant to stay a *tight* project,
not a 6-month one. Defer features until an actual painpoint justifies them; bank
low-hanging fruit; fix problems as they arise. Whisper stays a pure transcriber —
the "smart" layer (welding / punctuation / commands / tidy) is a future LLM pass,
**not** whisper fine-tuning (ruled out: heavy, fragile, fights distribution).

---

## 1. Done (committed) — the usability cleanup sprint

Shipped and confirmed in daily use. Baseline the v1.0 work builds on:

- **Leading-dot strip** (`Transcriber.cleanTranscription`). Whisper emits a
  spurious leading `". "` when an utterance opens on a brief silence (~38% of
  chunks in a real session); stripped at source. Also kills the doubled `". ."`
  seams.
- **Undo** (`OverlayWindow.finish` + `AppState.setupEscapeKeyMonitor`). Dictated
  chunks register as a single undoable step (`shouldChangeText`/`didChangeText`).
  Root cause of "Cmd+Z did nothing": this is an `LSUIElement` app with **no Edit
  menu**, so the standard Cmd+Z key-equivalent is never dispatched — we route
  Cmd+Z / Cmd+Shift+Z through the existing local key monitor instead. A failed
  transcription now keeps the prior selection instead of deleting it.
- **Overlay polish.** Box enlarged to 750×300; frosted `.popover` backdrop with
  `visualEffectView.alphaValue = 0.8` (view-level, not window-level — window
  `alphaValue` flattens the vibrancy and kills the blur); persistent scrollbar
  on overflow; `scrollRangeToVisible` so long inserts follow the cursor.
- **ESC while recording** aborts the recording (discards audio); on an empty
  box it closes outright (the user reneged), otherwise it keeps the box text and
  a second ESC closes the box.
- **No-speech gate + start-cue mute** (the "Thank you." fix). Whisper
  hallucinates "Thank you"/"Thanks for watching" on near-silence. Two parts: the
  recording's first `0.1s + start-cue duration` is zeroed in the audio tap (the
  Tink bleeds into the mic — no echo cancellation — and seeded the
  hallucination), and a client-side RMS energy gate (`min_speech_dbfs`, -60)
  skips whisper entirely when a clip never rises above the speech floor.
  `no_speech_prob` was measured useless (real speech 0.93 == silence 0.93);
  energy separates by ~50 dB. Recordings now persist in `/tmp/speak/wavs` (24h,
  pruned at launch + each stop) with `tools/whisper_probe.py` to inspect
  whisper's verbose_json.
- **Trailing ellipsis strip.** Whisper's "..." on utterances it thinks trail off
  is removed (runs of 2+ dots; a real sentence-ending "." survives).

---

## 2. ACTIVE ARC — v1.0: a real, installable, professional app

**Goal:** `git clone` → run one script → a self-contained app in `/Applications`
that launches at login, with clean logs, in-app settings, and a README an AI
agent can act on. The clone becomes a disposable build workspace.

**Audience (drives the "is this bloat?" calls):** technical macOS users who
dictate to AI/Claude Code, fed up with the system dictation daemon, and *often
driving an AI agent to do the setup*. This is why config stays a file (§2.5) and
the README is written for an agent (§2.G).

### Decisions locked (do not relitigate)

> **REVISED 2026-06-14 (decision 1 below superseded — thin app + shared store).**
> The fat-`.app` plan duplicated the ~2 GB model whenever the clone stuck around,
> and since distribution is compile-from-source the bundle never needed to carry
> the model. New model: a **thin** `.app` (binary + sample + config seeds, ~4 MB)
> + a **single shared model store** at `~/Library/Application Support/Speak/models`
> (overridable via `model_dir`), reused by BOTH dev and installed runs. install.sh
> `mv`s the assets into the store (one copy; clone stays deletable). Resolution:
> `model_dir` → shared store → dev clone `whisper.cpp/models`. Everything else in
> decision 1 (mode-by-bundle-path, no env var) stands.

1. **Self-contained fat `.app` in `/Applications` (chosen distribution model).**
   Stage everything — `whisper-server` binary, ggml model, `mlmodelc` encoder —
   into `SpeakApp.app/Contents/Resources`. Most Mac-like ("it's just an app"),
   makes the app **clone-independent**, and makes `Config.speakRoot` *simpler*
   (resolve from `Bundle.main.resourceURL`, no walk-up). Honest cost: a ~2 GB
   `.app` (the model has to live somewhere). **This does NOT re-open the
   deferred Homebrew artifact-hosting problem**: building from source already
   means running the python ANE conversion *once, in the disposable clone, at
   install time* — that's what "compile from source" is. The every-user-runs-
   python-forever problem (which Homebrew artifact-hosting solved) doesn't exist
   here.

2. **Mode detection by bundle path — no env var.** Resources inside the bundle →
   "installed" mode; otherwise walk up to the clone → "dev" mode. The install
   location *is* the signal. (This SUPERSEDES the earlier `SPEAK_RUN_VIA` env-var
   leaning in §4 — that mechanism is no longer needed.)

3. **One user-facing script: `install.sh`.** `build.sh` (compile) and `run.sh`
   (fast dev iterate from the clone, foreground logs) stay for developers — but
   the *user* only ever runs `install.sh`. It: refuses if
   `/Applications/SpeakApp.app` already exists (**no upgrade path in v1** —
   reinstall = delete-then-install; document this); does deps → build
   whisper-server → ANE convert → build SpeakApp → stage self-contained into
   `/Applications` → `open` it (triggers first-run permission prompts) → print a
   **message** that the clone can now be `rm -rf`'d (never auto-delete — too
   dangerous for the user and devs).

4. **Logging.** A `Log.error/info/debug` shim + `log_level` config key (default
   `info`); gate the noisy sources (per-tap `KeyMonitor` timings, per-buffer
   `AudioRecorder` drops, the `Config` dump) to `debug`. The app **owns its log
   file**: installed → `~/Library/Logs/Speak/`; dev → repo `log.txt`. `server.log`
   relocates alongside. This is what makes detached/standalone running possible
   without losing logs (today logs depend on `run.sh`'s `tee`). Then add
   **`run.sh --detached`** (now viable; foreground stays the default).

5. **`config.yaml` = single source of truth, comments on their own lines.**
   Rewrite so value lines are pure `key: value` and `#` comments sit on separate
   lines. Keeps the file AI-agent-editable AND lets the settings pane (§2.4)
   rewrite a value with a surgical single-line replace that never clobbers a
   comment. Settings changes are **"restart to apply"** (matches the current
   model — `Config.shared` loads once at launch; live-reload is a later nicety).

6. **Status/Settings window** — left-click tray → window; right-click tray →
   small menu (stop using `statusItem.menu`; handle the button action + detect
   right-click). The window has tabs:
   - **Status tab** = the existing readiness checklist (`SplashWindow`) +
     a prominent **gesture cheat-sheet** (double-tap L-Shift = box+mic; tap =
     down a level / paste; ESC = down a level, cancelling) + the **install path**
     + **"Open Settings" deep-link buttons** on failed permission rows.
   - **Settings tab** = form controls mirroring `config.yaml` (write back via
     surgical line-edits), a **`prompt.txt` editor**, and the **"Start at login"**
     checkbox (per the §2.0 spike). The form is a *mirror* — the YAML stays
     authoritative, so an agent editing the file directly still works.
   - **No Logs tab** (bloat — the status window just names the log path).

7. **Tray icon states.** `statusItem.button?.contentTintColor`: pulse during
   startup, **green** when ready, **red** on failure. (The app already swaps SF
   Symbols by state in `AppDelegate.setStatusIcon` — this adds colour.) **No
   Reduce-Motion special-casing** — that setting is for vestibular/motion-
   sickness accessibility, not performance, and a minimal pulse doesn't trigger
   it. The calibrated progress-arc idea is parked (§4) as medium-code-low-value.

8. **Docs for GitHub.** README rewritten **for an AI agent** (operational and
   explicit: install path, config keys, how to edit config/prompt, the gestures)
   + keep the "Why not just use macOS dictation / Claude Code voice" positioning
   section + a GIF/screenshots. Split the deep component-map + invariants into
   **`ARCHITECTURE.md`**. Images in `assets/`.

### STATUS (2026-06-14): all of §2 below IMPLEMENTED in dev, pending the user's
### one dev-test pass (run.sh) then one install.sh pass. 2.0 ✅ verified.
### 2.1 (incl. model-store revision above), 2.2, 2.3, 2.4, 2.5, 2.6 ✅ written +
### compiling. Remaining gates: dev test, install test, idle RAM/CPU measurement.

### The work, in dependency order

> File pointers are approximate — verify against the tree, it shifts.

- **2.0 — SPIKE — ✅ RESOLVED (favorable).** `SMAppService.mainApp.register()`
  **works for an ad-hoc-signed app in `/Applications` with no Developer ID.**
  Probe (throwaway bundle, `Signature=adhoc`, `TeamIdentifier=not set`) went
  `notFound → enabled` on `register()`, stayed `enabled`, and `unregister()`
  cleanly returned to `notRegistered` — **not** `.requiresApproval`. So
  **"Start at login" is a real checkbox**, not a manual step. UX note for
  2.4/2.6: registering fires a system notification ("Login Item Added — will
  open automatically when you log in"), and that banner *persists even after
  unregister* (notifications don't retract). So the Settings toggle is not
  silent — don't also pop our own confirmation, and the deep-link target is
  **System Settings → General → Login Items**.

- **2.1 — Mode detection + install-location refactor + the new `install.sh`
  (structural core).** `Config.speakRoot` (`Config.swift:27`) gains a
  bundle-resource branch; everything routing through `Config.rootPath`
  (ServerManager, ReadinessChecker) follows for free. Write the self-contained
  installer. **Findings that shaped the implementation:**
  - **`whisper-server` is dylib-linked, NOT standalone.** The dev `build-coreml`
    binary loads 6 `@rpath` dylibs (libwhisper + 5 ggml/backend libs) and its
    baked rpaths are **absolute paths into the clone** — so copying just the
    binary into the bundle breaks the instant the clone is `rm -rf`'d. **Fix
    (chosen): install.sh builds whisper-server with `-DBUILD_SHARED_LIBS=OFF`**
    → one fat static binary, trivial to stage, verifiable with a single
    `otool -L` (must show only `/usr/lib` + `/System` frameworks). install.sh
    asserts this and FAILS LOUDLY otherwise. (Rejected the dylib-bundling +
    `install_name_tool` rpath-surgery alternative — more moving parts, per-file
    re-signing.)
  - **Two roots, not one.** The bundle's `Resources/` is read-only (and writing
    into it breaks the code signature), so `speakRoot` splits:
    **resourceRoot** (read-only assets: server binary, model `.bin`, encoder
    `mlmodelc`, `samples/jfk.wav`) → `Bundle.main.resourceURL` installed / clone
    dev; **dataRoot** (writable: `config.yaml`, `prompt.txt`, `server.log`) →
    `~/Library/Application Support/Speak/` installed / clone dev. In dev mode
    both collapse to the clone, preserving today's behavior exactly. The app
    seeds dataRoot from bundled defaults on first run (survives a deleted data
    dir). NOTE: the encoder-sibling-of-`.bin` invariant (#? / §4) is preserved —
    both live together under resourceRoot's `models/`.

- **2.2 — Logging foundation** (rides on mode detection). `Log` shim + levels +
  app-owned log file; migrate/gate the ~41 `NSLog` sites (most can stay `info`;
  the noisy ones → `debug`). Relocate `server.log` (`ServerManager.swift:69`).
  Add `run.sh --detached`.

- **2.3 — `config.yaml` rewrite** (own-line comments). Small; unblocks the
  settings writer. Parser (`Config.load`, `Config.swift:42`) already tolerates it.

- **2.4 — Status/Settings window.** Evolve `SplashWindow` into the tabbed window.
  Permission deep-links use the `x-apple.systempreferences:` URL scheme
  (`...Privacy_Accessibility` / `...Privacy_Microphone`) — the current code only
  *prompts* on first run (`AppDelegate.checkAccessibilityPermissions`,
  `ReadinessChecker.checkMic`) and shows passive failure text with no way back.

- **2.5 — Tray-icon states** (`AppDelegate.setStatusIcon` / `setupStatusItem`).

- **2.6 — Docs** (README-for-agent + `ARCHITECTURE.md` + `assets/`).

### MVP cut (if staying tight)

`2.0 → 2.1 → 2.2 → 2.6` gives an installable, self-contained, clean-logging app
with a good README — the genuine "valuable to others" core. Defer **2.4 (settings
window)** and **2.5 (tray polish)**: those are the heaviest-per-value and can land
in a follow-up. (The user has asked for the full set, but this is the fallback if
time is short.)

### Open unknowns to resolve

- ~~**SMAppService viability for an ad-hoc `/Applications` app** (the §2.0 spike).~~
  **RESOLVED ✅** — works, lands `.enabled`, login item is a checkbox (see §2.0).
- **Synthetic ⌘V paste coverage.** The README's core claim is "works in every
  input surface." Not verified against secure-input fields / apps that block
  synthetic events. Know where it breaks and document the caveat before
  publishing.
- **Always-on footprint / server lifecycle.** `whisper-server` is resident
  (~2 GB RAM) **from launch** for instant first dictation. As a login-item app
  that's 2 GB held all day. Decide **eager** (current, instant, heavy) vs **lazy**
  (start on first dictation, free when idle → first-use latency) — matters more
  on *other people's* machines. Measure idle RAM/CPU to decide on facts.
- **`contentTintColor`** on the status item across macOS versions / light-dark —
  minor, confirm before building 2.5.

---

## 2b. NEW DIRECTION (decided 2026-06-15) — signed distribution

**Decision:** pursue proper distribution — reactivate an Apple Developer account
($99/yr), sign with a Developer ID, notarize. Possibly a paid utility. This
*supersedes* the compile-from-source-as-distribution stance and reframes several
§2/§4 decisions.

**Why.** Building from source is a *developer* install: it needs Xcode/CLT +
cmake + python3 + ~4 GB of downloads + a multi-minute compile, and ad-hoc signing
**churns TCC grants on every (re)install** (new cdhash each build → Accessibility +
Mic re-prompt). No paying, non-technical user will do that. A Developer-ID-signed,
notarized `.app` removes ALL of it for end users (download → drag to /Applications
→ launch) **and** gives a stable signature so permissions persist across updates.

**Two-track model:**
- *Developer/contributor:* permanent clone → `install.sh` (build from source) →
  `build.sh`/`run.sh` → `install.sh`. Needs the toolchain. install.sh now
  preflight-checks all prereqs and advises (done 2026-06-15); README is honest
  ("CLT or Xcode"). The `curl|bash` bootstrap idea drops to a dev convenience, NOT
  the consumer path.
- *End user:* download a notarized `.dmg`, drag to /Applications. Zero toolchain.

**Updates: NOTIFY-ONLY** (no in-app rebuild/auto-update — decided). Implemented
2026-06-15: build.sh stamps the git commit into Info.plist (`SpeakGitCommit`);
`UpdateChecker` queries GitHub's latest `main` commit on launch (`check_for_updates`,
default on — the only network call); the menu shows "Update available → <sha>".
Dev builds (`-dirty`/`unknown`) skip the check. The item opens the repo for now;
once signed releases exist it can point at the `.dmg`. Sparkle (true auto-update of
a signed `.dmg`) is *possible* later but explicitly NOT wanted now.

**Open decisions for the signed arc:**
- **Notarization pipeline:** Developer ID Application cert, hardened runtime
  (`codesign --options runtime`), `xcrun notarytool submit`, `stapler staple`,
  package as `.dmg`. VERIFY entitlements for hardened-runtime + mic +
  the `CGEventTap` (Accessibility is a runtime TCC grant, likely fine; mic needs
  `NSMicrophoneUsageDescription`, present).
- **Model bundling:** fat signed `.app` (~2 GB download, dead simple) vs thin app
  that downloads the model on first run (smaller download, needs hosting + a signed
  fetch). The thin-app + shared-store design in §2 was a *consequence* of
  compile-from-source — reconsider it under prebuilt distribution.
- **Hosting:** GitHub Releases for the `.dmg`; the update check could then compare
  release tags instead of raw commit hashes.
- **Pricing/licensing** — out of scope here, but it's the reason low-friction
  install matters.

**Supersedes:** §4's "no developer account" rationale (we're getting one); the
"CLT-only / no Xcode" claim (now "CLT or Xcode", and moot for end users once
prebuilt). The §2 thin-app/shared-store model is up for reconsideration.

---

## 3. NEXT ARC — Eager background transcription (latency + >30s correctness)

**Big architectural change; hand to a FRESH agent after v1 (§2) is installed +
committed.** This is the planned post-v1 overhaul. Read this whole entry first.

### Why (evidence, measured 2026-06-14 from log.txt)
We currently record ONE continuous WAV (`AudioRecorder`, start→stop) and send it
as ONE `/inference` request (`Transcriber`) only after the user stops. whisper.cpp
+ ANE is very fast, so this is crisp for normal use — but two problems appear on
long dictation:

- **Latency grows past 30 s.** Decode ≈1 s for clips ≤~20 s (one 30-s ANE encoder
  window), then roughly linear as whisper processes successive 30-s windows:
  measured 26 s→1.9 s, 31 s→2.1 s, **48.7 s→4.6 s**. All paid as dead time after
  you stop talking.
- **>30 s boundary artifact.** When a sentence straddles whisper's internal 30-s
  window boundary mid-speech, whisper hallucinates a completion for the truncated
  segment AND re-transcribes the overlap → duplicated phrase + spurious break
  (e.g. "…doing the same.⏎⏎preventing them from doing that."). Clean when the
  boundary happens to fall in a silence gap.
- (Paragraph-splitting of one long utterance into many — ALREADY MITIGATED: §1
  now joins whisper segments with a space, not `\n`, in
  `Transcriber.cleanTranscription`.)

### Goal
Transcribe completed portions of an utterance IN THE BACKGROUND while the user
keeps talking, so on stop only the final segment needs decoding → low tail
latency. As a bonus this **also fixes the >30 s artifact** (we cut at silences
before whisper ever hits its own 30-s boundary) — one change, three wins
(latency, >30 s correctness, and it reinforces the paragraph fix).

### Design — the key simplification (avoids over-eager chunking)
The ONLY hard requirement is "never let whisper hit its own 30-s boundary
mid-speech." Everything else is preference. So:
- **Do not chunk at all until ~22 s since the last waypoint.** Below that, decode
  is ~1 s anyway — zero benefit, and short dictation stays on exactly today's code
  path. A long *mid-sentence thinking pause* in the first 22 s is preserved (the
  user explicitly wants to be able to pause to think).
- **After ~22 s, cut at the next silence gap:** dispatch [waypoint → gap] to
  whisper in the background; set a new waypoint at the gap.
- **Hard deadline ~28 s:** if speech is continuous with no gap, force a cut.
  Rare; still cleaner than whisper's internal 30-s split; `smartJoin` stitches.
(Start with 22 s / 28 s as tunables. This sidesteps the sliding-stringency curve
we first brainstormed.)

### Implementation pieces (the work, roughly)
1. **`AudioRecorder`**: slice the live buffer at a sample boundary and emit a
   sub-WAV of [waypoint…cut] while continuing to record into the next segment.
   Today it writes a single file at stop — this is the biggest change.
2. **VAD / silence detection**: an energy-gate over the captured samples. We
   already compute per-buffer energy/peak for the spectrogram — reuse it. Track
   "elapsed since waypoint" and the last silence position.
3. **Background dispatch + waypoint state** in `AppStateCoordinator.stop`/record
   path; `Transcriber` already does async requests and 60-s connect-retry.
4. **Progressive insertion into the box (fiddliest):** completed chunks return
   out of order-ish and must land BEFORE the live 🎙️ marker as they arrive
   (`OverlayWindow.finish` / `smartJoin` currently assume one result at the
   marker). Needs careful marker/cursor/undo-grouping management.

### Companion: show chunks in the spectrogram (now easy)
Post-rearchitecture we own the columns (`ColumnRing` / `SpectrogramColumnSource`
/ `SpectrogramView`). Draw a faint vertical line at each waypoint, dim columns
already transcribed, and highlight the chunk currently in flight — honest,
pretty feedback that pairs naturally with the pipeline.

### Cheaper alternative to try FIRST (cheap experiment, ~0 code)
Before the full rewrite, try whisper.cpp server flags that reduce the >30 s
repetition/hallucination. VERIFIED on this 1.8.3 build: `no_context` is already
hard-true server-side (each `/inference` clears prior context), but within a
single >30 s call the decoded text still rolls forward across the internal 30 s
windows, and there's no request flag to disable that. Entropy/temperature
fallback thresholds ARE request-settable. This won't help latency, but if it
kills the boundary artifact it lowers the rewrite to "latency only."

### Silero VAD + granular JSON (earmarked 2026-06-15)
The no-speech misfire is already handled by a client-side RMS gate (§1). When we
do this arc, consider getting more out of whisper:
- **Silero VAD** (`-vm <ggml>`, fetched by `whisper.cpp/models/download-vad-model.sh`;
  a SEPARATE ~1-2 MB neural net — NOT whisper — emitting per-frame speech probs,
  `whisper_vad_*` in `whisper.h`). Server-side pre-filter: non-speech windows
  yield empty output (~1-2 ms cost; small enough to bundle in the `.app`). This is
  the natural FIRST experiment for the >30 s artifact (whisper segments on speech,
  never cutting mid-word at 30 s) AND a noise-robust no-speech filter. Caveat: it
  runs at TRANSCRIPTION time, so it does NOT serve live cutting (that needs a
  CLIENT-side VAD) — and watch the 1.8.x quirk where no-voice returned the prior
  transcription (GH #3250), another reason to keep a client-side gate.
- **verbose_json signals** (measured — don't re-derive): `no_speech_prob` is
  UNRELIABLE (real speech 0.93 == silent hallucination 0.93). `avg_logprob` looks
  promising but our hallucinations sit at ~-0.5, so community -0.8/-1.0 thresholds
  don't transfer to medium.en+ANE. `compression_ratio` is commented out in this
  server build (would need a patch).
- **The silence/VAD result we'd want is NOT exposed over HTTP:** whisper.cpp
  computes per-frame VAD probs + speech-segment t0/t1 internally
  (`whisper_vad_probs`, `whisper_vad_segments_*`), but the server only returns
  transcription segments. Surfacing speech/silence boundaries would need a server
  patch or a client-side VAD. `tools/whisper_probe.py` dumps what verbose_json
  DOES expose today.

### Risks / open questions
- **Context loss:** decoding an early chunk without later context. Small for
  dictation if cuts land at real pauses (clauses/sentences are self-contained);
  the 22-s floor keeps most thinking-pauses intact. The box is editable anyway.
- Out-of-order chunk returns + undo grouping in the box.
- Where exactly to cut in sample space vs the WAV writer's framing.
- File pointers: `AudioRecorder.swift` (single-WAV recorder), `Transcriber.swift`
  (async request + cleanTranscription), `AppState.swift` (`stopRecordingAndTranscribe`),
  `OverlayWindow.swift` (`finish` + `smartJoin`, marker internals), spectrogram trio.

## 3b. (reserved)

---

## 4. Parked until justified (head-work preserved)

Do NOT re-pitch these unprompted; they were each considered and deliberately
deferred. Kept here so the reasoning isn't lost if one becomes justified.

### Distribution via Homebrew — SUPERSEDED for v1 by the §2 `/Applications` install

The self-contained-`.app`-in-`/Applications` install (§2) is the chosen v1
distribution path. The Homebrew route below is retained only if wide, one-command
distribution is ever revisited. **Note the supersessions:** the `SPEAK_RUN_VIA`
env-var mode detection is replaced by bundle-path detection (§2.2 decision); the
`var/`-model-storage + `fetch-model.sh` scheme is replaced by bundling resources
in the `.app`.

Retained brew head-work (still valid *if* revisited):
- **Formula, not cask.** Casks need an Apple Developer account ($99/yr) +
  notarization; a *formula* compiles from source, a locally-built binary has no
  quarantine attribute (Gatekeeper happy), ad-hoc signing suffices for TCC. No
  developer account, no notarization, no logins.
- **Tap = a GitHub repo `homebrew-tap`** with `Formula/speak.rb` →
  `brew install p-i-/tap/speak`. Apple Silicon only, macOS 13+
  (`depends_on arch: :arm64` / `macos: :ventura`).
- **Host the CoreML encoder (587 MB `mlmodelc.zip`) as a release artifact** so
  users never run the python conversion. The reason is **dependency rot** (the
  torch×coremltools×python matrix shifts ~quarterly), not the gigabytes.
- **`brew update` vs `brew upgrade` (verified, brew 5.1):** `update` git-pulls
  recipe metadata + brew itself, takes no formula arg; `brew upgrade speak` is the
  only event that re-runs the install block. A `resource` with unchanged sha256
  isn't re-downloaded but IS re-staged into the new keg → model-in-keg costs ~2–3×
  on disk transiently. (This is why brew would have fetched the model into `var/`
  rather than the keg.)

**Measured ANE-build cost (still relevant to §2 — the bundle is ~2 GB for this
reason, and the install-time python step is unavoidable for the ANE encoder):**
- (A) `ggml-medium.en.bin` = **1.4 GB** — the RUNTIME model (decoder + weights),
  never deletable.
- (B) the converter downloads a SEPARATE openai `medium.en.pt` = **1.4 GB** into
  `~/.cache/whisper`, builds an **880 MB** `.venv-coreml`, then
  `convert-whisper-to-coreml.py` → `.mlpackage` → `xcrun coremlc compile` →
  `ggml-medium.en-encoder.mlmodelc` = **587 MB** (the ANE ENCODER only).
- (C) at first server load macOS compiles B → ANE microcode (~35 s), cached in
  macOS's own evictable ANE cache (invariant #4; we cannot ship C).
- A and B are BOTH needed at runtime. The 1.4 GB `.pt` + 880 MB venv are
  conversion-only scratch (~2.3 GB) — `install.sh` should offer to clean them.
- HARD CONSTRAINT: whisper.cpp resolves the CoreML encoder path *relative to the
  `.bin`* (`ServerManager.swift:65`) — the `mlmodelc` MUST be a sibling of the
  `.bin` in the same dir.

### LLM "jiggle" (whole-box repair) — major feature, parked

Long-press of shift (release ~0.2–0.5 s) triggers an LLM pass over the whole box.
The window matters: a bare hold is already a no-op AND any intervening keystroke
marks the press `usedAsModifier` and cancels it, so holding shift to type a
capital can NEVER fire it. A `didDetectBareHold` event slots in cleanly, honored
only in editing state.

Sends box text + cursor position + an instruction system prompt + `prompt.txt` to
a local LLM, returns repaired text — absorbs everything `OverlayWindow.smartJoin`
can't (spoken punctuation, capitalization, flubs, rephrasing) plus spoken commands
("command: reformat as a list"), all from the system prompt. Opt-in (not
per-insertion: an LLM on every chunk taxes all dictation; the per-insertion
FROM/TO regex contract is fragile). `llama-server` is the same resident-server
pattern (`ServerManager` generalizes to N servers); a 4B-class instruct model,
~2–4 s, ~2.5 GB resident. One config key `llm_url` (OpenAI-compatible) covers
local + cloud. Gate behind `llm_enabled: false`. MUST be cancellable (ESC) and
undoable. **This is where "weld both sides of the cursor" and spoken-punctuation
actually live — whisper's decoder structurally cannot do them** (audio-conditioned,
causal/no-fill-in-middle, not instruction-tuned).

### Other explored-but-parked ideas

- **Phrase-boundary editing.** Whisper exposes boundaries (`verbose_json`
  segments; word-level via `max_len`/`split_on_word`; `--dtw`). Idea: colour
  boundaries, constrain cursor/selection to them, edit in audio-space (splice
  before+new+after, re-transcribe). Parked: hard-constraining conflicts with free
  text editing (the box's elegance), metadata goes stale on manual edits, and
  re-transcription can drift. Re-evaluate only with captured-audio data.
- **Audio / episode capture.** Persist each WAV (currently deleted at
  `AppState.swift` after transcribe) + the full action log + accepted text, for
  offline analysis (Python in `tools/`, never shipped). Gate behind a default-off
  flag. Implement only when we actually need data to resolve a question.
- **Per-request whisper context-prompt.** The server accepts a per-request
  `prompt` (`server.cpp:554`); feeding left-of-cursor context would bias
  continuation casing. Parked: conflicts with the 224-token vocab budget, and the
  deterministic fixes may make it unnecessary.
- **30 s window visualizer** (honest "filling rectangle"); **`use_ane:
  if_available`** third value (auto-detect ANE artifacts — would fix the
  fresh-clone Metal-only ❌, but tied to the deferred git-clone polish);
  **calibrated tray progress arc**; **Logs tab**; **popover coachmark onboarding**;
  **lazy server lifecycle** (see §2 unknown). All low-priority polish.

---

## 5. Smaller debts

- **Cancellable Transcriber.** ESC during "Processing…" can't abort the in-flight
  request (hand-rolled semaphore + `Thread.sleep` retries); should become a
  cancellable async task.
- **Gesture state-machine extraction.** Extract the decision logic as a pure
  `(event, timestamp) → action` function so it's unit-testable by replaying
  recorded `log.txt` traces (including the timestamp-lag regression). A middle
  tier synthesizes keypresses via `CGEvent.post`.
- **`tools/doctor.sh`.** Headless diagnostic suite for bug reports (the status
  window covers the interactive case): binaries+model present/sized, port
  free/stale, mic pipeline (`tools/mic-test.sh` exists), accessibility + event
  tap, server cold-start, inference round-trip + exact-text match. One PASS/FAIL
  line each, nonzero exit on failure. The artifact for "future AI agent debugs a
  user's install."
- **First-word clipping** — largely fixed by launch-time engine prewarm; residual
  lever is moving overlay-window creation off the gesture's synchronous path.

---

## 6. Hard-won invariants (DO NOT REGRESS — also in README/ARCHITECTURE)

1. Never measure key-press durations with processing-time clocks. The event tap
   delivers on the main run loop; main-thread work inflates apparent durations.
   `CGEvent.timestamp` (hardware time) is the only truth. Its units vary by
   system — `KeyMonitor` calibrates against the system clock at runtime.
2. `AVAudioConverter` with rate conversion returns `.inputRanDry` for the normal
   single-buffer case; its output frames are still valid. Dropping them records
   empty files.
3. whisper-server reports some failures as HTTP 200 with an error-JSON body;
   `Transcriber` must check for that.
4. The ANE compile cache is fragile (entries evict each other; running
   whisper-cli benchmarks evicts the server's entry). Expect occasional ~35 s
   recompiles. (macOS caches the compiled blob, but it's evictable and not
   ship-able — there is no supported way to pin or relocate it.)
5. Every failure path logs. If something breaks silently, the bug is that it
   broke silently.

---

## 7. Working-style notes for the next agent

- **Observe the output first.** Multiple past bugs hid behind unobservable
  subsystems; the leading-dot root cause was found by reading `log.txt`, not
  guessing. Make failures log; don't blind-guess.
- **Don't launch a test instance while the user's own `./run.sh` is running** —
  it hijacks the shared whisper-server on port 8178. Build-only is fine; ask the
  user to test, or confirm no `SpeakApp` is running first.
- **No Xcode, ever.** Plain `swiftc` via `build.sh`; adding a source file just
  means dropping it in `SpeakApp/SpeakApp/`. This is deliberate.
- **Commit discipline:** the user tests before committing. Don't commit until
  they've confirmed. Solo local repo, linear `main`, no remote — history rewrites
  (soft-reset/redo) are safe when needed.

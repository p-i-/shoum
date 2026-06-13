# Speak — Roadmap

Work not yet done, with the reasoning behind each decision so a future session
(or contributor) can pick up without re-deriving it. Ordered roughly by the
priority discussed: Homebrew distribution first, then the LLM "jiggle", then
smaller debts.

---

## 1. Homebrew distribution (the active next project)

**Goal:** a user runs one command and gets a working, fast, auto-starting app,
with near-zero chance of generating GitHub issues / support emails for us.

### Decisions already made (do not relitigate)

- **Formula, not cask.** Casks are prebuilt-binary only and would require an
  Apple Developer account ($99/yr) + notarization. A *formula* compiles from
  source on the user's machine: a locally-built binary carries no quarantine
  attribute, so Gatekeeper never blocks it, and ad-hoc signing (already done
  in `build.sh`) is enough for TCC permissions. **No Apple Developer account,
  no notarization, no API keys, no logins of any kind.**
- **The tap is just a GitHub repo named `homebrew-tap`.** Create
  `github.com/p-i-/homebrew-tap` with `Formula/speak.rb`. Then anyone runs:
  ```
  brew install p-i-/tap/speak
  ```
  Homebrew resolves `p-i-/tap` → that repo by naming convention. The "official
  homebrew" org is NOT involved. The only account in the picture is the
  GitHub one we already have.
- **Apple Silicon only, macOS 13+.** Declared in the formula
  (`depends_on arch: :arm64` / `macos: :ventura`) so Intel users get one clean
  sentence at install time, not a confusing failure later. Justification:
  pre-Metal Macs are pre-2012 and can't run macOS 13 anyway; Intel Macs would
  run medium.en painfully slowly (multi-second to minute transcriptions) — a
  bad product experience that itself generates issues. We are not bending over
  backwards for old hardware.
- **No ANE capability detection needed.** EVERY Apple Silicon chip (M1
  onward, including Airs) has a Neural Engine. ANE-vs-Metal is purely our
  software *build* choice, not a hardware split. If the formula installed, the
  machine has an ANE. The `use_ane: false` config key stays only as a
  debugging escape hatch.
- **One blessed model: medium.en.** Homebrew deprecated per-install options
  (`--with-small`) because they break caching and multiply the test matrix
  (= multiply fuss). Each model needs its OWN hosted ANE artifact, so
  supporting N models = N artifacts to maintain. Ship one tested config.
  Power users change `model:` in config.yaml and run a helper to fetch other
  ggml models (Metal-only unless they convert the encoder themselves).
- **Host the CoreML encoder as a release artifact.** This is the key call:
  the python/torch conversion (torch 2.5.0 + coremltools + openai-whisper +
  ane_transformers, ~2.5GB deps + 1.4GB checkpoint) must NEVER run on a user's
  machine or inside the formula. Reason isn't the gigabytes — it's
  **dependency rot**: the conversion sits on the torch×coremltools×python
  compatibility matrix which shifts ~quarterly (the conversion script already
  carries a `use_sdpa=False` workaround comment pinned to torch 2.5.0). If a
  user's fresh `pip install` resolves differently in 8 months, they get a
  coremltools stack trace and WE become their issue tracker. Instead: we run
  the conversion once per release, attach the 587MB `mlmodelc.zip` to a GitHub
  release (well under GitHub's 2GB/file limit), and the formula fetches it as
  a checksummed `resource`. Cost to us: re-upload one file when whisper.cpp or
  the model changes (rare). The self-build script stays in `tools/` as an
  escape hatch for the curious.

### Two distinct steps people confuse (keep them straight)

1. **Conversion** — whisper weights → `ggml-medium.en-encoder.mlmodelc` folder.
   Once per model, needs the python venv, output is portable across any Apple
   Silicon Mac. THIS is what we host so users never run it.
2. **ANE specialization** — macOS compiling that folder into Neural-Engine
   microcode at first load (the ~35s "Neural Engine compile" splash row). Every
   user's machine does this automatically, no dependencies. Already a visible
   checklist row. Not a problem.

### Remaining work items

**1a. Prefix-aware paths + system log location (the one real code task).**
`Config.speakRoot` currently walks up from the binary looking for
`whisper.cpp/` (dev-mode, repo-relative). Add a brew-mode branch: resources
live under the Homebrew prefix's `share/speak/`. Cleanest mechanism: the
formula bakes the path in at compile time (e.g. a `-DBREW_PREFIX=...`
equivalent, or a generated constant). In brew mode, logs go to
`~/Library/Logs/Speak/` instead of the repo's `log.txt`/`server.log`. Same
binary logic, two homes. **Both modes must keep working** — dev clone +
`./run.sh` (logs tee'd to repo) stays as-is for developers.

**1b. "Start at login" checkbox on the splash (~15 lines).** Brew formulas
cannot auto-launch a GUI app or register a login item (sandboxed install +
policy). So: the formula installs a one-line `speak` launcher into brew's
`bin/` (already on every brew user's PATH — this solves the "how do they find
it" problem without .rc/$PATH faffing). Caveats text says `run: speak`. On
first launch the splash offers a "Start at login" checkbox
(`SMAppService.mainApp.register()`), sitting next to the existing auto-close
checkbox. After ticking it, the app survives reboots and they never type
`speak` again. Division of labor: brew gets it onto disk + PATH; the app's own
onboarding (already built) handles GUI permissions + TCC prompts + login item.

**1c. Generate + upload release artifacts.** Per release: regenerate
`ggml-medium.en-encoder.mlmodelc.zip` (maintainer runs the conversion in
`.venv-coreml`), `gh release create` with it attached. The ggml model itself
comes straight from HuggingFace as a pinned checksummed resource — no need to
host that.

**1d. The `homebrew-tap` repo + `Formula/speak.rb` (~40 lines).** Resources:
app source (this repo, pinned tag), whisper.cpp (pinned commit), ggml-medium.en
(HuggingFace URL + sha256), CoreML encoder zip (our release artifact + sha256).
`depends_on "cmake" => :build`. Build steps: compile whisper.cpp with
`-DWHISPER_COREML=1 -DCMAKE_BUILD_TYPE=Release`, run our `build.sh` (swiftc —
this is why we killed the Xcode dependency; full Xcode is 12GB and `xcodebuild`
refuses to run with CLI tools alone), stage everything into `share/speak/`,
install `speak` launcher into `bin/`. Caveats explain `run: speak` + the
re-grant-permissions-on-upgrade quirk (see below).

**1e. README install section** gains the `brew install p-i-/tap/speak`
one-liner as the primary path; the current from-source instructions stay for
developers.

### Known quirks to document in formula caveats (not bugs)

- Every `brew upgrade` produces a new binary with a new code hash → macOS will
  likely re-prompt for Accessibility/Microphone permissions. (We watched this
  exact mechanism bite during development.) Document it; don't fight it.
- Formulas install into the brew prefix, not `/Applications` (that's cask
  territory, and casks can't compile). The `speak` launcher + login-item
  checkbox make this a non-issue for users.

### Session refinements (DECIDED 2026-06-13 — supersede the leanings above where they conflict)

Head-work captured so it isn't re-derived. Grounded against the real tree
(swiftc app, brew 5.1, measured artifact sizes).

- **Mode detection: a runtime `SPEAK_RUN_VIA` env var, NOT a compile-time bake
  (this reverses 1a's lean).** Values `homebrew` | `dev`; set by the launcher,
  read once by `Config` at startup and logged (observable). Absent → default
  `dev` (today's walk-up). Why: swiftc has no `-Dname=value` string injection
  (only valueless conditional-compilation flags), so baking would mean
  generating a `BuildConfig.swift` and editing `build.sh`. The env var keeps the
  binary byte-identical in both modes, touches nothing in `build.sh`, and
  reduces "which mode" to "did the launcher set the var." The launcher also
  passes the one thing it uniquely knows — the brew prefix / resource root — and
  the app derives config/log/model dirs from standard `~/Library` + `var/`.

- **`brew update` vs `brew upgrade` (verified against brew 5.1).** `brew update`
  git-pulls Homebrew + ALL recipe definitions (refreshes metadata, updates brew
  itself) and takes NO formula argument — `brew update speak` is rejected and
  rerouted to `upgrade`. `brew upgrade speak` is the ONLY event that re-runs the
  formula's install block and pours new bytes. So there is no cheap per-formula
  "update" hook; all model/version handling happens at `brew upgrade` (and first
  install) time. Caching: a `resource` with an unchanged sha256 is NOT
  re-downloaded (cache hit) but IS re-staged (copied) into the new versioned
  keg, and the old keg lingers until cleanup → a model-in-keg costs ~2–3× its
  size on disk transiently. That duplication is what we design against.

- **Model storage: app-fetched into `var/`, NOT a brew resource-in-keg.** On
  Apple Silicon `brew --prefix` is `/opt/homebrew`, which is USER-owned, so the
  app can write `/opt/homebrew/var/speak/models/` at runtime with no sudo, and
  it persists untouched across upgrades. The keg ships only code + the
  whisper.cpp binary (small → cheap upgrades). The app fetches the model on
  first launch, keyed by a baked model-id/sha, re-fetching only on mismatch
  ("need a new model? download it, else use what we've got"). Decouples the
  ~2GB model lifecycle from the tiny code lifecycle. Trade-off accepted: the
  model is invisible to `brew uninstall` (document a cleanup line in caveats).
  HARD CONSTRAINT: whisper.cpp resolves the CoreML encoder path *relative to the
  `.bin`* (ServerManager.swift:65), so the `mlmodelc` MUST install as a sibling
  of the `.bin` in the same dir; `-m` points there and the encoder auto-loads.

- **The fetch is a shell helper, not Swift.** `tools/fetch-model.sh`: curl the
  ggml `.bin` (HuggingFace, pinned) + our `.mlmodelc.zip` release artifact,
  `shasum -a 256 -c`, `ditto -xk` to unzip into the model dir. Trivial in shell,
  grim in Swift (no stdlib unzip; hand-rolled URLSession progress). The Swift
  GUI MUST stay a compiled bundle (menu-bar LSUIElement, event tap, overlays).
  Trigger already exists: the splash's "Binaries & model files" row
  (`ReadinessChecker.checkFiles`, ~line 116) goes ❌ when the model is missing —
  on ❌ in brew mode, run `fetch-model.sh` via `Process` and stream its progress
  into that row (honours the observe-the-output invariant).

- **Two run-paths, one binary.** Both are thin launchers over a shared core that
  (set `SPEAK_RUN_VIA`, ensure the model is present, then `exec` the SAME
  bundle):
  - *brew*: the formula installs a `speak` launcher into `bin/` (on PATH). Sets
    `=homebrew`, model in `var/`, logs to `~/Library/Logs/Speak`. The formula
    CANNOT auto-launch a GUI (no Aqua session at install, sandbox + policy), so
    install can't kick it off; caveats say `run: speak` once, then the splash's
    "Start at login" checkbox (SMAppService, item 1b) makes the app register
    itself as a login item.
  - *dev*: `run.sh` sets `=dev`, model stays in `whisper.cpp/models`, tees to
    `log.txt` (unchanged from today).

- **Config + logs in brew mode.** `config.yaml`/`prompt.txt` cannot live in the
  read-only keg (a `brew upgrade` would wipe the user's tuned gesture timings +
  curated vocabulary). Brew mode: seed defaults once into `var/speak/` and never
  clobber; the loader already tolerates missing keys. Logs: there is no `run.sh`
  tee in brew mode, so the app must `freopen` its own stderr →
  `~/Library/Logs/Speak/log.txt` EARLY in `main` — brew mode ONLY (doing it in
  dev would steal stderr from run.sh's pipe). `server.log` just repoints.

- **What a full ANE setup actually costs (measured — hardens the 1c rationale).**
  (A) download `ggml-medium.en.bin` = **1.4 GB** (HuggingFace) — the RUNTIME
  model whisper-server loads (decoder + weights). (B) the converter downloads a
  SEPARATE openai `medium.en.pt` = **1.4 GB** into `~/.cache/whisper`, builds an
  **880 MB** `.venv-coreml` (torch + coremltools + …), runs
  `convert-whisper-to-coreml.py` → `.mlpackage` → `xcrun coremlc compile` →
  `ggml-medium.en-encoder.mlmodelc` = **587 MB** (the ANE ENCODER only). (C) at
  first server load macOS compiles B → ANE microcode (~35s), cached in macOS's
  own ANE cache (evictable — invariant #4; we cannot ship C). A and B are BOTH
  needed at runtime and A is never deletable. The 1.4 GB `.pt` + 880 MB venv are
  CONVERSION-ONLY scratch (~2.3 GB) and are currently left behind. Hosting B
  (587 MB) as a release artifact means users fetch A + B and NEVER run
  python/torch/coremltools — killing both the 2.3 GB scratch and the
  dependency-rot risk. This is the hard justification for item 1c.

---

## 2. LLM "jiggle" (whole-box repair) — major feature, parked

A long-press of shift (release between ~0.2–0.5s) triggers an LLM pass over the
whole dictation box. The 0.2–0.5s release window matters: a bare hold is
already a no-op in the gesture state machine AND any intervening keystroke
marks the press `usedAsModifier` and cancels it — so holding shift to type a
capital letter can NEVER fire the jiggle. A `didDetectBareHold` event slots in
with no conflict; fire it at the threshold while still held (instant shimmer
feedback), honored only in editing state.

**What it does:** sends box text + cursor/marker position + an instruction
system prompt + `prompt.txt` (vocabulary) to a local LLM, which returns repaired
text. Absorbs every problem class at once that the deterministic join
heuristics (already shipped, see `OverlayWindow.smartJoin`) can't: spoken
punctuation ("comma", "full stop" → actual punctuation — the user LIKES
dictating punctuation explicitly, Apple-dictation style, and whisper's
auto-punctuation collides with it), capitalization, flubs, rephrasing. The same
channel handles spoken commands ("command: reformat as a list with emojis") —
falls out of the system prompt for free.

**Why opt-in (not per-insertion):** an LLM on every chunk taxes all dictation
with latency to fix problems that are 80% mechanical, and the per-insertion
FROM/TO regex-replace contract is fragile (FROM fails to match → worse bug than
a capital letter). The explicit gesture means the user decides when ~2–4s of
cleanup is worth it. The per-insertion LLM idea was explicitly considered and
rejected.

**Architecture fit:** llama.cpp is whisper.cpp's sibling; `llama-server` is the
same resident-server pattern we already run (`ServerManager` generalizes to N
servers). Gets a startup-checklist row ("LLM ready"), config keys, a log file.
The client is a small HTTP call against an OpenAI-compatible endpoint — so one
config key `llm_url` covers both local (default, privacy-preserving) and cloud
(point at a hosted API) with no other code. Local model: a 4B-class instruct
model (Qwen3-4B / Gemma-3-4B tier) handles this light instruction-following
task in ~2–4s on the M2, ~2.5GB resident quantized. Gate behind
`llm_enabled: false` by default (adds ~2.5–4GB RAM on top of whisper's ~2GB).

**Must-haves (lessons from this project's scars):** cancellable (ESC kills the
jiggle, box reverts — no repeat of the non-cancellable Transcriber mistake) and
undoable (keep pre-jiggle text for one-keystroke undo; LLMs will occasionally
"repair" something you wanted verbatim).

---

## 3. Smaller debts

- **Cancellable Transcriber.** ESC during "Processing…" currently can't abort
  the in-flight HTTP request; the app can sit in `.processing` up to the retry
  deadline. Hand-rolled sync-over-async (semaphore + `Thread.sleep` retries)
  should become a cancellable async task.
- **Gesture state-machine extraction.** The most bug-prone component (see the
  multi-hour debugging saga in git history) is untestable as written — timers,
  NSLogs, delegate side-effects woven through a class that only runs attached
  to a live event tap. Extract the decision logic as a pure
  `(event, timestamp) → action` function. Then unit tests are just replaying
  recorded traces (the `log.txt` format already captures real ones, including
  the timestamp-lag bug as a regression case). A middle tier — synthesizing
  real keypresses via `CGEvent.post` to exercise the actual tap — needs no
  human either. Human smoke-testing stays only for "does it feel right".
- **`tools/doctor.sh`.** Full atomic diagnostic suite for bug reports (the
  splash covers the interactive case; this is the headless/CI version). Checks:
  binaries+model present & sized, port free/stale-server, mic permission +
  pipeline (`tools/mic-test.sh` already exists), accessibility + event tap,
  server cold-start time-to-ready + dominant phase, inference round-trip
  latency + exact-text match, error-path handling, and (once #2 above lands)
  gesture trace replay. One PASS/FAIL line each, machine-parseable, nonzero
  exit on failure. This is the artifact for "future AI agent debugs a user's
  install".
- **Spoken-punctuation mode.** A punctuation-free variant of `prompt.txt`
  biases whisper away from auto-punctuation (initial prompt without punctuation
  → whisper emits less), for users who dictate punctuation explicitly. Cheap
  experiment; the jiggle (#2) covers the rest of that workflow.
- **First-word clipping** is largely fixed by the launch-time engine prewarm,
  but if any residual remains, the lever is moving the overlay-window creation
  fully off the gesture's synchronous path.

---

## Hard-won invariants (DO NOT REGRESS — also in README "Architecture")

1. Never measure key-press durations with processing-time clocks. The event tap
   delivers on the main run loop; main-thread work inflates apparent durations.
   `CGEvent.timestamp` (hardware time) is the only truth. Its units vary by
   system — KeyMonitor calibrates against the system clock at runtime.
2. `AVAudioConverter` with rate conversion returns `.inputRanDry` for the normal
   single-buffer case; its output frames are still valid. Dropping them records
   empty files.
3. whisper-server reports some failures as HTTP 200 with an error-JSON body;
   Transcriber must check for that.
4. The ANE compile cache is fragile (entries evict each other; running
   whisper-cli benchmarks evicts the server's entry). Expect occasional ~35s
   recompiles.
5. Every failure path logs. If something breaks silently, the bug is that it
   broke silently.

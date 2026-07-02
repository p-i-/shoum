import AppKit

enum ShoumState {
    case idle
    case recording
    case processing
    case editing
}

protocol AppStateDelegate: AnyObject {
    /// User gestured before the system is ready — surface the splash.
    func appStateNeedsAttention()
}

class AppStateCoordinator: KeyMonitorDelegate {
    weak var delegate: AppStateDelegate?

    private(set) var currentState: ShoumState = .idle {
        didSet {
            Log.info("[AppState] state \(oldValue) → \(currentState)")
            // Only in editing do tap (paste) and double-tap (new chunk) both
            // apply, so only there must single taps wait out the double-tap
            // window. Everywhere else taps fire instantly.
            keyMonitor.disambiguatesTaps = (currentState == .editing)
        }
    }

    private let audioRecorder = AudioRecorder()
    private let transcriber = Transcriber()
    private let silenceCuller = SilenceCuller()
    private let overlayWindow = OverlayWindow()
    private let clipboardManager = ClipboardManager()
    private let keyMonitor = KeyMonitor()
    private let serverManager = ServerManager()
    let readiness = ReadinessChecker()

    // Track if escape key monitor is active
    private var escapeMonitor: Any?

    private var recordingStartTime: TimeInterval?
    private var accessibilityPoll: Timer?
    private var axObserver: NSObjectProtocol?

    init() {
        keyMonitor.delegate = self
        audioRecorder.onSamples16k = { [weak self] samples in
            self?.overlayWindow.spectrogram.push16k(samples)
        }
    }

    func start() {
        // Post-startup engine events keep the Status row (and the tray, via the
        // readiness delegate chain) honest: a crash-relaunch re-verifies with a
        // round-trip; the give-up cap marks the engine dead (tray goes red).
        serverManager.onCrashRestart = { [weak self] in
            self?.readiness.recheckServer(label: "engine restarting after crash…")
        }
        serverManager.onGaveUp = { [weak self] detail in
            self?.readiness.engineDied(detail)
        }
        serverManager.start()
        // Only create the event tap when actually authorized. Creating it while
        // unauthorized yields a DEAD tap that churns (system disables → our
        // handler re-enables) and spawns repeated Accessibility popups. When
        // untrusted we create nothing and wait for the grant, then arm.
        let trusted = AXIsProcessTrusted()
        let hotkeyOK = trusted && keyMonitor.start()
        setupEscapeKeyMonitor()
        audioRecorder.prepare()
        readiness.run(recorder: audioRecorder, hotkeyOK: hotkeyOK, vad: vadState())
        if !trusted { pollForAccessibilityGrant() }
    }

    /// The VAD (silence-culling) health for the startup checklist: a missing
    /// Silero model is degraded-but-usable (⚠️, raw audio sent), not a failure.
    private func vadState() -> CheckState {
        guard Config.shared.pruneDeadAudio else { return .ok("off (prune_dead_audio: false)") }
        return silenceCuller.available
            ? .ok("Silero loaded")
            : .warning("VAD model missing — raw audio sent (no silence culling)")
    }

    func stop() {
        stopAccessibilityWatch()
        keyMonitor.stop()
        removeEscapeKeyMonitor()
        serverManager.stop()
    }

    /// Watch for the user granting Accessibility and re-arm the tap LIVE.
    /// Two triggers (a 1.5 s poll and the system's accessibility-changed
    /// distributed notification) both call `attemptHotkeyRearm`, which logs
    /// every signal so the next test run resolves what's still uncertain:
    ///  - does `AXIsProcessTrusted()` update live or cache per-process?
    ///  - does `tapIsEnabled` distinguish a live tap from the dead launch one?
    ///  - does the `com.apple.accessibility.api` notification actually fire?
    /// If the logs show `AXIsProcessTrusted` never flips, we'll switch to an
    /// auto-relaunch on the notification.
    private func pollForAccessibilityGrant() {
        accessibilityPoll?.invalidate()
        accessibilityPoll = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.attemptHotkeyRearm(trigger: "poll")
        }
        axObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.accessibility.api"), object: nil, queue: .main
        ) { [weak self] _ in
            self?.attemptHotkeyRearm(trigger: "notification")
        }
    }

    private func attemptHotkeyRearm(trigger: String) {
        let trusted = AXIsProcessTrusted()
        Log.info("[Accessibility] \(trigger): AXIsProcessTrusted=\(trusted) currentTapEnabled=\(keyMonitor.isTapEnabled)")
        guard trusted else { return }
        // Trusted now — replace the (possibly dead) launch tap with a fresh one.
        keyMonitor.stop()
        let created = keyMonitor.start(quiet: true)
        Log.info("[Accessibility] re-arm after trust: created=\(created) enabled=\(keyMonitor.isTapEnabled)")
        if created {
            stopAccessibilityWatch()
            readiness.markHotkeyArmed()
            Log.info("[Accessibility] hotkey armed LIVE — no relaunch")
        }
    }

    private func stopAccessibilityWatch() {
        accessibilityPoll?.invalidate()
        accessibilityPoll = nil
        if let o = axObserver {
            DistributedNotificationCenter.default().removeObserver(o)
            axObserver = nil
        }
    }

    /// Apply a Settings-pane change live. Reloading Config.shared makes every
    /// in-process consumer (KeyMonitor, AppState, Transcriber) pick up the new
    /// values immediately; only an engine-affecting change needs the
    /// whisper-server relaunched — with the reload made VISIBLE: the Status row
    /// shows "engine restarting…", readiness gates dictation until a fresh
    /// round-trip verifies the new engine, and a failed reload goes red.
    func applySettings(engineChanged: Bool) {
        Config.reload()
        if engineChanged {
            serverManager.restart()
            readiness.recheckServer(label: "engine restarting…")
        }
    }

    /// Let the Settings window come in front of the floating box while it's
    /// frontmost; restore floating otherwise.
    func setOverlayFloating(_ floating: Bool) {
        overlayWindow.setFloating(floating)
    }

    /// Menu-driven engine restart (Docker-style): relaunch whisper-server and
    /// re-verify with a fresh round-trip. Also the recovery path after a
    /// crash-loop give-up — restart() resets the give-up counter.
    func restartEngine() {
        Log.info("[AppState] engine restart requested (menu)")
        serverManager.restart()
        readiness.recheckServer(label: "engine restarting…")
    }

    // MARK: - KeyMonitorDelegate

    func keyMonitorDidDetectDoubleTap() {
        Log.info("[AppState] gesture: DOUBLE-TAP (state=\(currentState))")
        switch currentState {
        case .idle:
            guard readiness.isReady else {
                Log.info("[AppState] double-tap before ready - showing status")
                delegate?.appStateNeedsAttention()
                return
            }
            startRecording(isFirstChunk: true)
        case .editing:
            startRecording(isFirstChunk: false)
        case .recording, .processing:
            Log.info("[AppState] double-tap IGNORED (state=\(currentState))")
        }
    }

    func keyMonitorDidDetectTap() -> Bool {
        Log.info("[AppState] gesture: TAP (state=\(currentState))")
        switch currentState {
        case .recording:
            stopRecordingAndTranscribe()
            return true
        case .editing:
            confirmAndPaste()
            return true
        case .idle, .processing:
            Log.info("[AppState] tap IGNORED (state=\(currentState))")
            return false
        }
    }

    func keyMonitorDidDetectHoldRelease() {
        Log.info("[AppState] gesture: HOLD-RELEASE (state=\(currentState))")
        guard currentState == .recording else {
            Log.info("[AppState] hold-release IGNORED (state=\(currentState))")
            return
        }
        stopRecordingAndTranscribe()
    }

    // MARK: - Private Methods

    /// Seconds to zero at the head of each recording so the start cue —
    /// still ringing through the speakers when the mic arms, with no echo
    /// cancellation on the raw input — never reaches the file or the
    /// spectrogram. 100ms "clear the air" always, plus the cue's own length
    /// when sounds are enabled.
    private func startCueMuteSeconds() -> TimeInterval {
        let cue = Config.shared.sounds ? (NSSound(named: Self.startCueSound)?.duration ?? 0.3) : 0
        return 0.1 + cue
    }

    private func startRecording(isFirstChunk: Bool) {
        if isFirstChunk {
            clipboardManager.rememberFrontmostApp()
        }

        playSound(.start)
        overlayWindow.showRecording()

        do {
            try audioRecorder.startRecording(muteSeconds: startCueMuteSeconds())
            recordingStartTime = ProcessInfo.processInfo.systemUptime
            Log.info("[AppState] ▶ RECORDING STARTED (\(isFirstChunk ? "first chunk" : "additional chunk"))")
            currentState = .recording
        } catch {
            Log.error("[AppState] recording FAILED to start: \(error.localizedDescription)")
            overlayWindow.finish(with: nil)
            showError("Failed to start recording: \(error.localizedDescription)")
            if isFirstChunk {
                overlayWindow.hide()
            }
            currentState = isFirstChunk ? .idle : .editing
        }
    }

    private func stopRecordingAndTranscribe() {
        let duration = recordingStartTime.map { ProcessInfo.processInfo.systemUptime - $0 } ?? 0
        recordingStartTime = nil
        let artifacts = RecordingArtifacts(raw: audioRecorder.stopRecording())
        Log.info("[AppState] ■ RECORDING STOPPED after \(String(format: "%.2f", duration))s (RMS \(String(format: "%.1f", audioRecorder.lastRMSdBFS)) dBFS) -> \(artifacts.raw.lastPathComponent)")

        // Whisper hallucinates "Thank you" / "Thanks for watching" on
        // near-silence (no_speech_prob is unreliable — see tools/whisper_probe.py).
        // If the clip never rose above the speech floor, skip the round-trip and
        // treat it as empty (also saves the dead time).
        guard audioRecorder.lastRMSdBFS >= Config.shared.minSpeechDBFS else {
            finishAsNoSpeech(artifacts, reason: "no speech (RMS \(String(format: "%.1f", audioRecorder.lastRMSdBFS)) < \(Config.shared.minSpeechDBFS) dBFS)")
            return
        }

        playSound(.stop)
        overlayWindow.markProcessing()
        currentState = .processing

        // The (CPU-bound) cull runs off-main; the transcribe call is
        // non-blocking so it's issued from main — which also re-checks that ESC
        // hasn't cancelled the conversion during the cull. Every completion
        // guards on still being in .processing: after a cancel, results are
        // dropped and the files disposed. Config is read HERE (main) so the
        // background block never races a Settings-pane Config.reload().
        let pruneDeadAudio = Config.shared.pruneDeadAudio
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            var artifacts = artifacts
            if pruneDeadAudio {
                switch self.silenceCuller.cull(artifacts.raw) {
                case .culled(let url): artifacts.culled(to: url)
                case .noSpeech:
                    DispatchQueue.main.async {
                        guard self.currentState == .processing else { artifacts.discardAll(); return }
                        self.finishAsNoSpeech(artifacts, reason: "VAD found no speech")
                    }
                    return
                case .unavailable:
                    Log.info("[AppState] cull unavailable — sending raw audio")
                }
            }

            DispatchQueue.main.async {
                guard self.currentState == .processing else {
                    Log.info("[AppState] cancelled during cull — dropping recording")
                    artifacts.discardAll()
                    return
                }
                self.transcriber.transcribe(wavFile: artifacts.sent) { result in
                    guard self.currentState == .processing else {
                        Log.info("[AppState] transcription result arrived after cancel — dropped")
                        artifacts.discardAll()
                        return
                    }
                    switch result {
                    case .success(let text):
                        artifacts.discardAllButSent() // sent is retained for flagging
                        self.handleTranscriptionSuccess(
                            text, sentAudio: artifacts.sent, pruned: artifacts.kebab != nil, duration: duration)
                    case .failure(let error):
                        artifacts.discardAll()
                        self.handleTranscriptionError(error)
                    }
                }
            }
        }
    }

    /// Common tail for "this recording turned out to be silence" (RMS gate or
    /// VAD): discard the audio, drop the marker, land in editing. Main thread.
    private func finishAsNoSpeech(_ artifacts: RecordingArtifacts, reason: String) {
        Log.info("[AppState] \(reason) — skipping whisper")
        artifacts.discardAll()
        playSound(.subtle)
        overlayWindow.finish(with: nil)
        overlayWindow.show()
        currentState = .editing
    }

    private func handleTranscriptionSuccess(
        _ text: String, sentAudio: URL, pruned: Bool, duration: TimeInterval) {
        Log.info("[AppState] transcription OK: \(text.count) chars: \"\(String(text.prefix(80)))\"")
        playSound(.success)

        // Run spoken symbol/markdown commands ("ascii slash" → /) before the
        // chunk lands; see CommandProcessor / lexicon.md. Off → raw text.
        let chunk = Config.shared.voiceCommands ? CommandProcessor.process(text) : text

        // The 🧠 marker becomes the transcribed text. The clipboard is left
        // untouched until the user confirms (single-tap) so dictating never
        // clobbers what they had copied; confirmAndPaste borrows it then restores.
        // `finish` returns the smartJoin I/O it performed — captured for the flag
        // feature. Held until the next conversion supersedes it, so it's
        // flaggable even after paste.
        let splice = overlayWindow.finish(with: chunk)
        overlayWindow.showWhisperResponse(Config.shared.showWhisperResponse ? text : nil)
        setLastInteraction(LastInteraction(
            kebabURL: sentAudio,
            pruned: pruned,
            durationSec: duration,
            rmsDBFS: audioRecorder.lastRMSdBFS,
            model: Config.shared.model,
            prompt: FlagStore.currentPrompt(),
            timestamp: Date(),
            chunk: splice?.chunk ?? chunk,
            boxBefore: splice?.boxBefore ?? "",
            boxAfter: splice?.boxAfter ?? overlayWindow.getText(),
            replaced: splice?.replaced ?? ""))

        currentState = .editing
    }

    // MARK: - Flagging

    private var lastInteraction: LastInteraction?

    /// Whether there's a conversion available to flag (drives the menu item).
    var hasFlaggableInteraction: Bool { lastInteraction != nil }

    private func setLastInteraction(_ interaction: LastInteraction) {
        if let prev = lastInteraction { releaseRetainedAudio(prev) }
        lastInteraction = interaction
    }

    /// The superseded interaction's sent audio was retained only for flagging;
    /// once it's replaced, dispose it (RecordingArtifacts.dispose applies the
    /// keep_recordings rule).
    private func releaseRetainedAudio(_ interaction: LastInteraction) {
        RecordingArtifacts.dispose(interaction.kebabURL)
    }

    /// Persist the last conversion as a flagged incident (menu action). Returns
    /// false if there's nothing to flag or the record couldn't be written.
    @discardableResult
    func flagLastInteraction(note: String) -> Bool {
        guard let interaction = lastInteraction else { return false }
        let ok = FlagStore.write(interaction, note: note)
        Log.info("[AppState] flag last interaction (note: \(note.isEmpty ? "—" : "\"\(note)\"")) -> \(ok ? "saved" : "FAILED")")
        return ok
    }

    private func handleTranscriptionError(_ error: Error) {
        if case Transcriber.TranscriberError.cancelled = error {
            // ESC already unwound the state synchronously (cancelProcessing);
            // normally the stale-result guard filters this — kept for safety.
            Log.info("[AppState] transcription cancelled")
            return
        }
        Log.error("[AppState] transcription FAILED: \(error.localizedDescription)")
        overlayWindow.finish(with: nil)
        if case Transcriber.TranscriberError.emptyTranscription = error {
            // Empty transcription - the marker just disappears
            playSound(.subtle)
            overlayWindow.show()
        } else {
            playSound(.error)
            showError(error.localizedDescription)
        }
        currentState = .editing
    }

    private func confirmAndPaste() {
        let text = overlayWindow.getText()
        Log.info("[AppState] confirmAndPaste: \(text.count) chars in box")
        guard !text.isEmpty else {
            Log.info("[AppState] confirmAndPaste: empty box → hiding")
            overlayWindow.hide()
            clipboardManager.refocusRememberedApp()
            currentState = .idle
            return
        }

        if Config.shared.pasteMode == "copy" {
            Log.info("[AppState] copying \(text.count) chars to clipboard (paste_mode: copy)")
            clipboardManager.copyToClipboard(text)
            overlayWindow.hide()
            clipboardManager.refocusRememberedApp()
            currentState = .idle
            return
        }

        // Terminal target + the toggle on → deliver via keystroke injection (no
        // clipboard, no "[Pasted N lines]" collapse). Hide first so the overlay
        // can't grab focus mid-type; typing runs in the background.
        if Config.shared.typeIntoTerminals, clipboardManager.rememberedAppIsTerminal {
            Log.info("[AppState] typing \(text.count) chars into terminal (keystroke injection)")
            overlayWindow.hide()
            clipboardManager.typeToRememberedApp(text)
            currentState = .idle
            return
        }

        Log.info("[AppState] pasting \(text.count) chars to previous app")
        clipboardManager.pasteToRememberedApp(
            text, restoreClipboardAfter: Config.shared.restoreClipboard)

        // Hide overlay after a brief delay to ensure paste completes
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.overlayWindow.hide()
            self?.currentState = .idle
        }
    }

    private func dismiss() {
        Log.info("[AppState] dismissed (escape)")
        overlayWindow.hide()
        clipboardManager.refocusRememberedApp()
        currentState = .idle
    }

    /// ESC while recording: stop the mic, discard the audio (no transcription),
    /// drop the recording marker but keep any text already in the box, and land
    /// in editing — so a second ESC then closes the box.
    private func cancelRecording() {
        recordingStartTime = nil
        RecordingArtifacts.dispose(audioRecorder.stopRecording())
        Log.info("[AppState] recording cancelled (escape)")
        playSound(.subtle)
        overlayWindow.finish(with: nil) // removes the marker, restores any selection
        currentState = .editing
    }

    /// ESC while recording into an EMPTY box: the user reneged on invoking the
    /// tool — stop the mic, discard the audio, and close the box outright
    /// (straight to idle) instead of landing in an empty editor.
    private func cancelRecordingAndClose() {
        recordingStartTime = nil
        RecordingArtifacts.dispose(audioRecorder.stopRecording())
        Log.info("[AppState] recording cancelled + box closed (escape on empty box)")
        playSound(.subtle)
        overlayWindow.hide()
        clipboardManager.refocusRememberedApp()
        currentState = .idle
    }

    /// ESC while transcribing (🧠): abandon the in-flight conversion. Same
    /// semantics as ESC-while-recording — the 🧠 marker vanishes, text already
    /// in the box is kept (editing), and an empty box closes outright. The
    /// pipeline's stale-result guards dispose the audio files.
    private func cancelProcessing() {
        Log.info("[AppState] transcription cancelled (escape)")
        transcriber.cancel()
        playSound(.subtle)
        overlayWindow.finish(with: nil) // removes the 🧠 marker, restores any selection
        if overlayWindow.getText().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            overlayWindow.hide()
            clipboardManager.refocusRememberedApp()
            currentState = .idle
        } else {
            currentState = .editing
        }
    }

    private func setupEscapeKeyMonitor() {
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }

            if event.keyCode == 53 { // 53 = Escape
                if self.currentState == .recording {
                    // Empty box → the user reneged: stop the mic and close the
                    // box outright. With text already present, keep it and just
                    // abort this chunk (land in editing).
                    if self.overlayWindow.getText().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        self.cancelRecordingAndClose()
                    } else {
                        self.cancelRecording() // first ESC: abort this chunk, keep text
                    }
                    return nil
                }
                if self.currentState == .processing {
                    self.cancelProcessing() // abandon the in-flight transcription
                    return nil
                }
                if self.currentState == .editing {
                    self.dismiss() // ESC with no active recording: close the box
                    return nil
                }
            }

            // ⌘Z/⌘C/etc. dispatch via the Edit menu (AppDelegate.setupMainMenu).
            return event
        }
    }

    private func removeEscapeKeyMonitor() {
        if let monitor = escapeMonitor {
            NSEvent.removeMonitor(monitor)
            escapeMonitor = nil
        }
    }

    // MARK: - Audio Feedback

    private enum SoundType {
        case start
        case stop
        case success
        case subtle
        case error
    }

    /// The start cue — also measured by startCueMuteSeconds to size the head
    /// mute, so the two must stay the same sound.
    private static let startCueSound = NSSound.Name("Tink")

    private func playSound(_ type: SoundType) {
        guard Config.shared.sounds else { return }
        let soundName: NSSound.Name
        switch type {
        case .start:
            soundName = Self.startCueSound
        case .stop:
            soundName = NSSound.Name("Pop")
        case .success:
            soundName = NSSound.Name("Glass")
        case .subtle:
            soundName = NSSound.Name("Morse")
        case .error:
            soundName = NSSound.Name("Basso")
        }

        NSSound(named: soundName)?.play()
    }

    // MARK: - Error Handling

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Transcription Error"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

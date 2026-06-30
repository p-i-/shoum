import AppKit

enum ShoumState {
    case idle
    case recording
    case processing
    case editing
}

protocol AppStateDelegate: AnyObject {
    func appStateDidChange(to state: ShoumState)
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
            delegate?.appStateDidChange(to: currentState)
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
        serverManager.start()
        // Only create the event tap when actually authorized. Creating it while
        // unauthorized yields a DEAD tap that churns (system disables → our
        // handler re-enables) and spawns repeated Accessibility popups. When
        // untrusted we create nothing and wait for the grant, then arm.
        let trusted = AXIsProcessTrusted()
        let hotkeyOK = trusted && keyMonitor.start()
        setupEscapeKeyMonitor()
        audioRecorder.prepare()
        readiness.run(recorder: audioRecorder, hotkeyOK: hotkeyOK)
        if !trusted { pollForAccessibilityGrant() }
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
    /// whisper-server relaunched.
    func applySettings(engineChanged: Bool) {
        Config.reload()
        if engineChanged { serverManager.restart() }
    }

    /// Let the Settings window come in front of the floating box while it's
    /// frontmost; restore floating otherwise.
    func setOverlayFloating(_ floating: Bool) {
        overlayWindow.setFloating(floating)
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

    func keyMonitorDidDetectTap() {
        Log.info("[AppState] gesture: TAP (state=\(currentState))")
        switch currentState {
        case .recording:
            stopRecordingAndTranscribe()
        case .editing:
            confirmAndPaste()
        case .idle, .processing:
            Log.info("[AppState] tap IGNORED (state=\(currentState))")
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

    /// Seconds to zero at the head of each recording so the start cue (Tink) —
    /// still ringing through the speakers when the mic arms, with no echo
    /// cancellation on the raw input — never reaches the file or the
    /// spectrogram. 100ms "clear the air" always, plus the cue's own length
    /// when sounds are enabled.
    private func startCueMuteSeconds() -> TimeInterval {
        let cue = Config.shared.sounds ? (NSSound(named: "Tink")?.duration ?? 0.3) : 0
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
        let wavURL = audioRecorder.stopRecording()
        Log.info("[AppState] ■ RECORDING STOPPED after \(String(format: "%.2f", duration))s (RMS \(String(format: "%.1f", audioRecorder.lastRMSdBFS)) dBFS) -> \(wavURL.lastPathComponent)")

        // Whisper hallucinates "Thank you" / "Thanks for watching" on
        // near-silence (no_speech_prob is unreliable — see tools/whisper_probe.py).
        // If the clip never rose above the speech floor, skip the round-trip and
        // treat it as empty (also saves the dead time).
        guard audioRecorder.lastRMSdBFS >= Config.shared.minSpeechDBFS else {
            Log.info("[AppState] no speech (RMS \(String(format: "%.1f", audioRecorder.lastRMSdBFS)) < \(Config.shared.minSpeechDBFS) dBFS) — skipping whisper")
            cleanupRecording(wavURL)
            playSound(.subtle)
            overlayWindow.finish(with: nil)
            overlayWindow.show()
            currentState = .editing
            return
        }

        playSound(.stop)
        overlayWindow.markProcessing()
        currentState = .processing

        // Off the main thread: optionally VAD-cull silence (prune_dead_audio) into
        // a kebab, then transcribe. Culling can also reveal there's no speech at
        // all → skip whisper. Both cull + transcribe run in the background; the
        // transcriber completes back on main.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            var sendURL = wavURL
            var culledURL: URL?
            if Config.shared.pruneDeadAudio {
                switch self.silenceCuller.cull(wavURL) {
                case .culled(let url): sendURL = url; culledURL = url
                case .noSpeech:
                    DispatchQueue.main.async {
                        Log.info("[AppState] VAD found no speech — skipping whisper")
                        self.cleanupRecording(wavURL)
                        self.playSound(.subtle)
                        self.overlayWindow.finish(with: nil)
                        self.overlayWindow.show()
                        self.currentState = .editing
                    }
                    return
                case .unavailable:
                    Log.info("[AppState] cull unavailable — sending raw audio")
                }
            }

            self.transcriber.transcribe(wavFile: sendURL) { result in
                switch result {
                case .success(let text):
                    // Retain the audio actually sent (sendURL) for possible
                    // flagging — released when the next conversion supersedes it
                    // (or kept 24h when keep_recordings is on). Drop the raw now,
                    // but only when it's a distinct file from the one sent.
                    if wavURL != sendURL { self.cleanupRecording(wavURL) }
                    self.handleTranscriptionSuccess(
                        text, sentAudio: sendURL, pruned: culledURL != nil, duration: duration)
                case .failure(let error):
                    self.cleanupRecording(wavURL)
                    if let culledURL = culledURL { self.cleanupRecording(culledURL) }
                    self.handleTranscriptionError(error)
                }
            }
        }
    }

    private func handleTranscriptionSuccess(
        _ text: String, sentAudio: URL, pruned: Bool, duration: TimeInterval) {
        Log.info("[AppState] transcription OK: \(text.count) chars: \"\(String(text.prefix(80)))\"")
        playSound(.success)

        // The 🧠 marker becomes the transcribed text. The clipboard is left
        // untouched until the user confirms (single-tap) so dictating never
        // clobbers what they had copied; confirmAndPaste borrows it then restores.
        overlayWindow.finish(with: text)

        // Capture this conversion for the flag feature: the exact audio sent to
        // the engine plus the smartJoin I/O `finish` just produced. Held until
        // the next conversion supersedes it, so it's flaggable even after paste.
        let splice = overlayWindow.lastSplice
        setLastInteraction(LastInteraction(
            kebabURL: sentAudio,
            pruned: pruned,
            durationSec: duration,
            rmsDBFS: audioRecorder.lastRMSdBFS,
            model: Config.shared.model,
            prompt: FlagStore.currentPrompt(),
            timestamp: Date(),
            chunk: splice?.chunk ?? text,
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
    /// once it's replaced, let keep_recordings decide its fate — the retained dir
    /// prunes at 24h, so we only need to act when keep_recordings is off.
    private func releaseRetainedAudio(_ interaction: LastInteraction) {
        guard !Config.shared.keepRecordings else { return }
        try? FileManager.default.removeItem(at: interaction.kebabURL)
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

        Log.info("[AppState] pasting \(text.count) chars to previous app")
        clipboardManager.pasteToRememberedApp(text, restoreClipboardAfter: true)

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
        let wavURL = audioRecorder.stopRecording()
        cleanupRecording(wavURL)
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
        let wavURL = audioRecorder.stopRecording()
        cleanupRecording(wavURL)
        Log.info("[AppState] recording cancelled + box closed (escape on empty box)")
        playSound(.subtle)
        overlayWindow.hide()
        clipboardManager.refocusRememberedApp()
        currentState = .idle
    }

    /// Recordings are retained (for post-hoc debugging of misfires) unless
    /// keep_recordings is off; AudioRecorder prunes the 24h-old ones at launch.
    private func cleanupRecording(_ url: URL) {
        guard !Config.shared.keepRecordings else { return }
        try? FileManager.default.removeItem(at: url)
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
                if self.currentState == .editing {
                    self.dismiss() // ESC with no active recording: close the box
                    return nil
                }
            }

            // Undo/redo (⌘Z / ⌘⇧Z) and Cut/Copy/Paste/Select All/Emoji are now
            // handled natively by the app's Edit menu (AppDelegate.setupMainMenu),
            // which routes the standard key equivalents to the text view through
            // the responder chain — no manual interception needed here.
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

    private func playSound(_ type: SoundType) {
        guard Config.shared.sounds else { return }
        let soundName: NSSound.Name
        switch type {
        case .start:
            soundName = NSSound.Name("Tink")
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

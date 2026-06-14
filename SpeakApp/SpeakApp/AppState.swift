import AppKit

enum SpeakState {
    case idle
    case recording
    case processing
    case editing
}

protocol AppStateDelegate: AnyObject {
    func appStateDidChange(to state: SpeakState)
    /// User gestured before the system is ready — surface the splash.
    func appStateNeedsAttention()
}

class AppStateCoordinator: KeyMonitorDelegate {
    weak var delegate: AppStateDelegate?

    private(set) var currentState: SpeakState = .idle {
        didSet {
            // Only in editing do tap (paste) and double-tap (new chunk) both
            // apply, so only there must single taps wait out the double-tap
            // window. Everywhere else taps fire instantly.
            keyMonitor.disambiguatesTaps = (currentState == .editing)
            delegate?.appStateDidChange(to: currentState)
        }
    }

    private let audioRecorder = AudioRecorder()
    private let transcriber = Transcriber()
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
        audioRecorder.onBuffer = { [weak self] samples, sampleRate in
            self?.overlayWindow.spectrogram.push(samples, sampleRate: sampleRate)
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
            // Ignore
            break
        }
    }

    func keyMonitorDidDetectTap() {
        switch currentState {
        case .recording:
            stopRecordingAndTranscribe()
        case .editing:
            confirmAndPaste()
        case .idle, .processing:
            break
        }
    }

    func keyMonitorDidDetectHoldRelease() {
        guard currentState == .recording else { return }
        stopRecordingAndTranscribe()
    }

    // MARK: - Private Methods

    private func startRecording(isFirstChunk: Bool) {
        if isFirstChunk {
            clipboardManager.rememberFrontmostApp()
        }

        playSound(.start)
        overlayWindow.showRecording()

        do {
            try audioRecorder.startRecording()
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
        Log.info("[AppState] ■ RECORDING STOPPED after \(String(format: "%.2f", duration))s -> transcribing")
        let wavURL = audioRecorder.stopRecording()
        playSound(.stop)
        overlayWindow.markProcessing()
        currentState = .processing

        transcriber.transcribe(wavFile: wavURL) { [weak self] result in
            guard let self = self else { return }

            // Clean up temp file
            try? FileManager.default.removeItem(at: wavURL)

            switch result {
            case .success(let text):
                self.handleTranscriptionSuccess(text)
            case .failure(let error):
                self.handleTranscriptionError(error)
            }
        }
    }

    private func handleTranscriptionSuccess(_ text: String) {
        Log.info("[AppState] transcription OK: \(text.count) chars: \"\(String(text.prefix(80)))\"")
        playSound(.success)

        // Copy to clipboard; the 🧠 marker becomes the transcribed text
        clipboardManager.copyToClipboard(text)
        overlayWindow.finish(with: text)

        currentState = .editing
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
        guard !text.isEmpty else {
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
        clipboardManager.pasteToRememberedApp(text)

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
        try? FileManager.default.removeItem(at: wavURL)
        Log.info("[AppState] recording cancelled (escape)")
        playSound(.subtle)
        overlayWindow.finish(with: nil) // removes the marker, restores any selection
        currentState = .editing
    }

    private func setupEscapeKeyMonitor() {
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }

            if event.keyCode == 53 { // 53 = Escape
                if self.currentState == .recording {
                    self.cancelRecording() // first ESC: abort the in-progress recording
                    return nil
                }
                if self.currentState == .editing {
                    self.dismiss() // ESC with no active recording: close the box
                    return nil
                }
            }

            // Cmd+Z / Cmd+Shift+Z → undo/redo in the dictation box. This is an
            // accessory app with no Edit menu, so the standard Cmd+Z key
            // equivalent is never dispatched to undo: — route it to the box's
            // own undo manager here, the same way Escape is handled.
            if self.currentState == .editing,
               event.modifierFlags.contains(.command),
               event.charactersIgnoringModifiers?.lowercased() == "z" {
                let undoManager = self.overlayWindow.textView.undoManager
                if event.modifierFlags.contains(.shift) {
                    undoManager?.redo()
                } else {
                    undoManager?.undo()
                }
                return nil // Consume the event
            }
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

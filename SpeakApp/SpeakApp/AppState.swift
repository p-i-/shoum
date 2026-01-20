import AppKit

enum SpeakState {
    case idle
    case recording
    case processing
    case editing
}

protocol AppStateDelegate: AnyObject {
    func appStateDidChange(to state: SpeakState)
}

class AppStateCoordinator: KeyMonitorDelegate {
    weak var delegate: AppStateDelegate?

    private(set) var currentState: SpeakState = .idle {
        didSet {
            delegate?.appStateDidChange(to: currentState)
        }
    }

    private let audioRecorder = AudioRecorder()
    private let transcriber = Transcriber()
    private let overlayWindow = OverlayWindow()
    private let clipboardManager = ClipboardManager()
    private let keyMonitor = KeyMonitor()

    // Track if escape key monitor is active
    private var escapeMonitor: Any?

    init() {
        keyMonitor.delegate = self
    }

    func start() {
        keyMonitor.start()
        setupEscapeKeyMonitor()
    }

    func stop() {
        keyMonitor.stop()
        removeEscapeKeyMonitor()
    }

    // MARK: - KeyMonitorDelegate

    func keyMonitorDidDetectHoldStart() {
        switch currentState {
        case .idle:
            startRecording(isFirstChunk: true)
        case .editing:
            startRecording(isFirstChunk: false)
        case .recording, .processing:
            // Ignore
            break
        }
    }

    func keyMonitorDidDetectHoldEnd() {
        guard currentState == .recording else { return }
        stopRecordingAndTranscribe()
    }

    func keyMonitorDidDetectTap() {
        guard currentState == .editing else { return }
        confirmAndPaste()
    }

    // MARK: - Private Methods

    private func startRecording(isFirstChunk: Bool) {
        if isFirstChunk {
            clipboardManager.rememberFrontmostApp()
        }

        playSound(.start)
        overlayWindow.showWithStatus("Recording...")

        do {
            try audioRecorder.startRecording()
            currentState = .recording
        } catch {
            showError("Failed to start recording: \(error.localizedDescription)")
            if isFirstChunk {
                overlayWindow.hide()
            }
            currentState = isFirstChunk ? .idle : .editing
        }
    }

    private func stopRecordingAndTranscribe() {
        let wavURL = audioRecorder.stopRecording()
        playSound(.stop)
        overlayWindow.showWithStatus("Processing...")
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
        playSound(.success)

        // Copy to clipboard and paste into overlay at cursor position
        clipboardManager.copyToClipboard(text)
        overlayWindow.insertTextAtCursor(text)

        currentState = .editing
    }

    private func handleTranscriptionError(_ error: Error) {
        if case Transcriber.TranscriberError.emptyTranscription = error {
            // Empty transcription - just go to editing state without changing text
            playSound(.subtle)
            overlayWindow.showWithStatus("")
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
            currentState = .idle
            return
        }

        clipboardManager.pasteToRememberedApp(text)

        // Hide overlay after a brief delay to ensure paste completes
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.overlayWindow.hide()
            self?.currentState = .idle
        }
    }

    private func dismiss() {
        overlayWindow.hide()
        currentState = .idle
    }

    private func setupEscapeKeyMonitor() {
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }

            if event.keyCode == 53 && self.currentState == .editing { // 53 = Escape
                self.dismiss()
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

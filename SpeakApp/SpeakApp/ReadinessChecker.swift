import AppKit
import AVFoundation

enum CheckItem: Int, CaseIterable {
    case accessibility
    case hotkey
    case micPermission
    case micLive
    case files
    case serverModel
    case serverANE
    case serverReady

    var title: String {
        switch self {
        case .accessibility: return "Accessibility permission"
        case .hotkey:        return "Hotkey armed"
        case .micPermission: return "Microphone permission"
        case .micLive:       return "Microphone live"
        case .files:         return "Binaries & model files"
        case .serverModel:   return "Whisper model load"
        case .serverANE:     return "Neural Engine compile"
        case .serverReady:   return "Server inference"
        }
    }
}

enum CheckState {
    case pending
    case running(String)
    case ok(String)
    case failed(String)

    var emoji: String {
        switch self {
        case .pending: return "⚪️"
        case .running: return "🔄"
        case .ok:      return "✅"
        case .failed:  return "❌"
        }
    }

    var detail: String {
        switch self {
        case .pending: return ""
        case .running(let s), .ok(let s), .failed(let s): return s
        }
    }

    var isOK: Bool { if case .ok = self { return true }; return false }
    var isFailed: Bool { if case .failed = self { return true }; return false }
}

protocol ReadinessDelegate: AnyObject {
    func readinessDidUpdate(_ item: CheckItem, state: CheckState)
    func readinessDidBecomeReady()
}

/// Runs the startup checklist: instant permission/file checks, a live mic
/// probe, and a watch over whisper-server's startup phases (via server.log
/// markers) capped by a real inference round-trip.
class ReadinessChecker {
    weak var delegate: ReadinessDelegate?

    private(set) var states: [CheckItem: CheckState] = Dictionary(
        uniqueKeysWithValues: CheckItem.allCases.map { ($0, .pending) })
    private(set) var isReady = false

    private var logTimer: Timer?
    private var aneCompileStart: TimeInterval?
    private var roundtripStarted = false
    private let watchStart = ProcessInfo.processInfo.systemUptime
    /// Generous: covers a cold 1.4GB model read plus a ~36s ANE compile, both
    /// of which are visible as their own splash rows while they run.
    private let markerTimeout: TimeInterval = 90
    /// Once the model is loaded, the test inference itself must be quick.
    private let inferenceTimeout: TimeInterval = 15
    // Held strongly: Transcriber's completion is lost if the instance deallocates.
    private let transcriber = Transcriber()

    var anyFailed: Bool { states.values.contains { $0.isFailed } }

    /// True once every check has reached ✅ or ❌ — gates the splash controls.
    var allResolved: Bool {
        states.values.allSatisfy { $0.isOK || $0.isFailed }
    }

    func run(recorder: AudioRecorder, hotkeyOK: Bool) {
        set(.accessibility, AXIsProcessTrusted()
            ? .ok("granted")
            : .failed("grant in System Settings → Privacy → Accessibility, then relaunch"))
        set(.hotkey, hotkeyOK
            ? .ok("double-tap key \(Config.shared.hotkeyKeycode)")
            : .failed("event tap refused — needs Accessibility permission"))
        checkFiles()
        checkMic(recorder)
        startServerWatch()
    }

    private func set(_ item: CheckItem, _ state: CheckState) {
        states[item] = state
        delegate?.readinessDidUpdate(item, state: state)

        let wasReady = isReady
        isReady = (states[.micLive]?.isOK ?? false)
            && (states[.serverReady]?.isOK ?? false)
            && (states[.hotkey]?.isOK ?? false)
        if isReady && !wasReady {
            NSLog("[Readiness] READY")
            delegate?.readinessDidBecomeReady()
        }
    }

    // MARK: - Files

    private func checkFiles() {
        let cfg = Config.shared
        let build = cfg.useANE ? "build-coreml" : "build"
        var missing: [String] = []

        if !FileManager.default.isExecutableFile(atPath: Config.rootPath("whisper.cpp/\(build)/bin/whisper-server")) {
            missing.append("\(build)/bin/whisper-server")
        }
        if !FileManager.default.fileExists(atPath: Config.rootPath("whisper.cpp/models/ggml-\(cfg.model).bin")) {
            missing.append("models/ggml-\(cfg.model).bin")
        }
        if cfg.useANE && !FileManager.default.fileExists(atPath: Config.rootPath("whisper.cpp/models/ggml-\(cfg.model)-encoder.mlmodelc")) {
            missing.append("models/ggml-\(cfg.model)-encoder.mlmodelc")
        }

        set(.files, missing.isEmpty
            ? .ok("\(cfg.model)\(cfg.useANE ? " + ANE" : " (Metal)")")
            : .failed("missing: \(missing.joined(separator: ", "))"))
    }

    // MARK: - Microphone

    private func checkMic(_ recorder: AudioRecorder) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            set(.micPermission, .ok("granted"))
            probeMic(recorder)
        case .notDetermined:
            set(.micPermission, .running("requesting…"))
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    if granted {
                        self.set(.micPermission, .ok("granted"))
                        self.probeMic(recorder)
                    } else {
                        self.set(.micPermission, .failed("denied — System Settings → Privacy → Microphone"))
                        self.set(.micLive, .failed("blocked by permission"))
                    }
                }
            }
        default:
            set(.micPermission, .failed("denied — System Settings → Privacy → Microphone"))
            set(.micLive, .failed("blocked by permission"))
        }
    }

    private func probeMic(_ recorder: AudioRecorder) {
        set(.micLive, .running("listening for 1s…"))
        recorder.micProbe { buffers, peak in
            DispatchQueue.main.async {
                if buffers > 5 {
                    self.set(.micLive, .ok(String(format: "%d buffers, peak %.3f", buffers, peak)))
                } else {
                    self.set(.micLive, .failed("no audio from input device (\(buffers) buffers)"))
                }
            }
        }
    }

    // MARK: - Server (server.log markers + inference round-trip)

    private func startServerWatch() {
        set(.serverModel, .running("loading…"))
        if !Config.shared.useANE {
            set(.serverANE, .ok("skipped (Metal build)"))
        }

        logTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.pollServerLog()
        }
    }

    private func pollServerLog() {
        let elapsed = ProcessInfo.processInfo.systemUptime - watchStart
        if elapsed > markerTimeout {
            logTimer?.invalidate()
            if !(states[.serverModel]?.isOK ?? false) {
                set(.serverModel, .failed("no model after \(Int(markerTimeout))s — see server.log"))
            }
            if Config.shared.useANE, !(states[.serverANE]?.isOK ?? false) {
                set(.serverANE, .failed("no compile after \(Int(markerTimeout))s — see server.log"))
            }
            if !roundtripStarted {
                set(.serverReady, .failed("server never came up — see server.log"))
            }
            return
        }

        guard let log = try? String(contentsOfFile: Config.rootPath("server.log"), encoding: .utf8) else { return }

        if !(states[.serverModel]?.isOK ?? false), log.contains("model size    =") {
            set(.serverModel, .ok(String(format: "1.5 GB in %.1fs", elapsed)))
        }

        if Config.shared.useANE, !(states[.serverANE]?.isOK ?? false) {
            if log.contains("Core ML model loaded") {
                let took = aneCompileStart.map { ProcessInfo.processInfo.systemUptime - $0 } ?? 0
                set(.serverANE, .ok(took < 5 ? "cached" : String(format: "compiled in %.0fs", took)))
            } else if log.contains("loading Core ML model") {
                if aneCompileStart == nil { aneCompileStart = ProcessInfo.processInfo.systemUptime }
                let secs = Int(ProcessInfo.processInfo.systemUptime - aneCompileStart!)
                set(.serverANE, .running("compiling… \(secs)s (first time ~35s)"))
            }
        }

        let aneDone = !Config.shared.useANE || (states[.serverANE]?.isOK ?? false)
        if aneDone, !roundtripStarted {
            roundtripStarted = true
            runInferenceRoundtrip()
        }
    }

    private func runInferenceRoundtrip() {
        set(.serverReady, .running("test inference…"))
        let testWav = Config.rootPath("whisper.cpp/samples/jfk.wav")
        guard FileManager.default.fileExists(atPath: testWav) else {
            // Degraded check: no sample audio available, settle for the port.
            pollPortUntilUp()
            return
        }

        let t0 = ProcessInfo.processInfo.systemUptime

        // Separate deadline for the inference itself; a late success still
        // overwrites the failure (set() recomputes readiness either way).
        DispatchQueue.main.asyncAfter(deadline: .now() + inferenceTimeout) { [weak self] in
            guard let self = self, !(self.states[.serverReady]?.isOK ?? false),
                  !(self.states[.serverReady]?.isFailed ?? false) else { return }
            self.set(.serverReady, .failed("no response after \(Int(self.inferenceTimeout))s"))
        }

        // Transcriber retries while the port comes up, so this also covers
        // the gap between "model loaded" and "listening".
        transcriber.transcribe(wavFile: URL(fileURLWithPath: testWav)) { [weak self] result in
            guard let self = self else { return }
            self.logTimer?.invalidate()
            let took = ProcessInfo.processInfo.systemUptime - t0
            switch result {
            case .success(let text):
                let looksRight = text.lowercased().contains("country")
                self.set(.serverReady, looksRight
                    ? .ok(String(format: "round-trip %.1fs", took))
                    : .failed("unexpected transcription: \(text.prefix(60))"))
            case .failure(let error):
                self.set(.serverReady, .failed(error.localizedDescription))
            }
        }
    }

    private func pollPortUntilUp() {
        let url = URL(string: "http://127.0.0.1:\(Config.shared.serverPort)/")!
        URLSession.shared.dataTask(with: url) { [weak self] _, response, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if (response as? HTTPURLResponse) != nil {
                    self.logTimer?.invalidate()
                    self.set(.serverReady, .ok("responding (no test wav found)"))
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.pollPortUntilUp() }
                }
            }
        }.resume()
    }
}

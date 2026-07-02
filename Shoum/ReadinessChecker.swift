import AppKit
import AVFoundation

enum CheckItem: Int, CaseIterable {
    case accessibility
    case hotkey
    case micPermission
    case micLive
    case files
    case vad
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
        case .vad:           return "Silence culling (VAD)"
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
    /// Not satisfied yet but not a failure — waiting on the user (e.g. a
    /// permission grant). Renders yellow ⚠️, not red ❌; doesn't make the tray
    /// red. Resolves to .ok once the user acts.
    case warning(String)
    case failed(String)

    var emoji: String {
        switch self {
        case .pending: return "⚪️"
        case .running: return "🔄"
        case .ok:      return "✅"
        case .warning: return "⚠️"
        case .failed:  return "❌"
        }
    }

    var detail: String {
        switch self {
        case .pending: return ""
        case .running(let s), .ok(let s), .warning(let s), .failed(let s): return s
        }
    }

    var isOK: Bool { if case .ok = self { return true }; return false }
    var isWarning: Bool { if case .warning = self { return true }; return false }
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
    private let watchStart = ProcessInfo.processInfo.systemUptime
    /// Patience for the AUTHORITATIVE startup round-trip: a cold model read
    /// plus a first-time ~36s ANE compile, with margin (the phases are visible
    /// as their own splash rows while they run).
    private let startupDeadline: TimeInterval = 120
    // Held strongly: Transcriber's completion is lost if the instance deallocates.
    private let transcriber = Transcriber()

    var anyFailed: Bool { states.values.contains { $0.isFailed } }
    /// A check is waiting on the user (e.g. Accessibility not yet granted) — a
    /// ⚠️, not a failure. Drives the splash header + tray without going red.
    var anyWarning: Bool { states.values.contains { $0.isWarning } }

    /// True once every check has settled into a terminal display state
    /// (✅ / ⚠️ / ❌) — gates the splash controls.
    var allResolved: Bool {
        states.values.allSatisfy { $0.isOK || $0.isFailed || $0.isWarning }
    }

    /// Accessibility was granted after launch and the event tap re-armed live;
    /// flip both rows to ✅ (recomputes readiness → may become ready).
    func markHotkeyArmed() {
        set(.accessibility, .ok("granted"))
        set(.hotkey, .ok("double-tap key \(Config.shared.hotkeyKeycode)"))
    }

    func run(recorder: AudioRecorder, hotkeyOK: Bool, vad: CheckState) {
        // NOTE: CGEvent.tapCreate succeeds even WITHOUT Accessibility (the tap
        // is created but dead), so tap-creation success is NOT a valid signal.
        // Gate "hotkey armed" on actual Accessibility trust so a missing grant
        // can't masquerade as ready (which painted the tray falsely green).
        let accessible = AXIsProcessTrusted()
        // Not-yet-granted is a ⚠️ (waiting on the user), not a ❌ failure — the
        // app polls and arms live once granted.
        set(.accessibility, accessible
            ? .ok("granted")
            : .warning("grant in System Settings → Privacy → Accessibility"))
        set(.hotkey, (accessible && hotkeyOK)
            ? .ok("double-tap key \(Config.shared.hotkeyKeycode)")
            : .warning("needs Accessibility permission"))
        set(.vad, vad)
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
            Log.info("[Readiness] READY")
            delegate?.readinessDidBecomeReady()
        }
    }

    // MARK: - Files

    private func checkFiles() {
        let cfg = Config.shared
        var missing: [String] = []

        if !FileManager.default.isExecutableFile(atPath: Config.serverBinaryPath) {
            missing.append((Config.serverBinaryPath as NSString).lastPathComponent)
        }
        if !FileManager.default.fileExists(atPath: Config.modelPath) {
            missing.append((Config.modelPath as NSString).lastPathComponent)
        }
        if cfg.useANE && !FileManager.default.fileExists(atPath: Config.encoderPath) {
            missing.append((Config.encoderPath as NSString).lastPathComponent)
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

    // MARK: - Server (authoritative inference round-trip + cosmetic log markers)

    /// Readiness is decided by ONE thing: a real inference round-trip, started
    /// immediately (the Transcriber retries while the server comes up). The
    /// server.log markers only enrich the display with phase detail ("model
    /// loading", "ANE compiling… Ns") — a whisper.cpp log-format change can
    /// degrade the display but can never fail a working startup.
    private func startServerWatch() {
        set(.serverModel, .running("loading…"))
        if !Config.shared.useANE {
            set(.serverANE, .ok("skipped (Metal build)"))
        }

        logTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.pollServerLog()
        }
        runInferenceRoundtrip(connectDeadline: startupDeadline)
    }

    /// Cosmetic phase display only — never fails anything (see startServerWatch).
    private func pollServerLog() {
        guard let log = try? String(contentsOfFile: Config.serverLogPath, encoding: .utf8) else { return }
        let elapsed = ProcessInfo.processInfo.systemUptime - watchStart

        if !(states[.serverModel]?.isOK ?? false), log.contains("model size    =") {
            let bytes = (try? FileManager.default.attributesOfItem(atPath: Config.modelPath))?[.size] as? Int ?? 0
            let size = bytes > 0 ? String(format: "%.1f GB", Double(bytes) / 1_073_741_824) : "model"
            set(.serverModel, .ok(String(format: "%@ in %.1fs", size, elapsed)))
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

        // Both phases displayed — nothing left to watch for.
        if (states[.serverModel]?.isOK ?? false), (states[.serverANE]?.isOK ?? false) {
            logTimer?.invalidate()
            logTimer = nil
        }
    }

    /// Post-startup engine events (AppState wires these to ServerManager):

    /// The engine is reloading (settings change or crash-relaunch): gate
    /// readiness on a fresh round-trip against the new process.
    func recheckServer(label: String) {
        transcriber.cancel() // supersede any round-trip already in flight
        runInferenceRoundtrip(label: label)
    }

    /// The server crash-looped and ServerManager gave up — dictation is dead;
    /// the failed row turns the tray red through the normal delegate chain.
    func engineDied(_ detail: String) {
        transcriber.cancel()
        set(.serverReady, .failed(detail))
    }

    /// Drives the menu status line while a settings/crash reload is in flight.
    var engineRestarting: Bool {
        if case .running(let d)? = states[.serverReady], d.hasPrefix("engine restarting") { return true }
        return false
    }

    private func runInferenceRoundtrip(connectDeadline: TimeInterval = 60,
                                       label: String = "test inference…") {
        set(.serverReady, .running(label))
        let testWav = Config.samplePath
        guard FileManager.default.fileExists(atPath: testWav) else {
            // Degraded check: no sample audio available, settle for the port.
            pollPortUntilUp()
            return
        }

        let t0 = ProcessInfo.processInfo.systemUptime

        // The Transcriber retries while the port comes up and fails on its own
        // deadline — no separate timeout needed here.
        transcriber.transcribe(wavFile: URL(fileURLWithPath: testWav),
                               connectDeadline: connectDeadline) { [weak self] result in
            guard let self = self else { return }
            if case .failure(let error) = result,
               case Transcriber.TranscriberError.cancelled = error {
                return // superseded by a newer recheck
            }
            self.logTimer?.invalidate()
            self.logTimer = nil
            let took = ProcessInfo.processInfo.systemUptime - t0
            switch result {
            case .success(let text):
                // Round-trip proof beats missing markers: resolve any phase row
                // the log never confirmed (e.g. upstream changed its wording).
                if !(self.states[.serverModel]?.isOK ?? false) {
                    self.set(.serverModel, .ok("loaded (log marker not seen)"))
                }
                if Config.shared.useANE, !(self.states[.serverANE]?.isOK ?? false) {
                    self.set(.serverANE, .ok("loaded (log marker not seen)"))
                }
                let looksRight = text.lowercased().contains("country")
                self.set(.serverReady, looksRight
                    ? .ok(String(format: "round-trip %.1fs", took))
                    : .failed("unexpected transcription: \(text.prefix(60))"))
            case .failure(let error):
                if !(self.states[.serverModel]?.isOK ?? false) {
                    self.set(.serverModel, .failed("not confirmed — see server.log"))
                }
                if Config.shared.useANE, !(self.states[.serverANE]?.isOK ?? false) {
                    self.set(.serverANE, .failed("not confirmed — see server.log"))
                }
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

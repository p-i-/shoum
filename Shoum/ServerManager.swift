import Foundation

/// Owns a resident whisper-server process so the model is loaded once at app
/// launch instead of on every utterance.
class ServerManager {
    private var process: Process?
    private var isStopping = false

    /// server.log is truncated once per app run (the first launch); crash
    /// relaunches APPEND with a banner instead, so a crash loop can't destroy
    /// the evidence of what killed the previous instance (invariant 8).
    private var truncatedLogThisRun = false

    /// Crash-restart guard: an exit within `rapidExitWindow` of its launch counts
    /// toward a consecutive-failure streak; after `maxRapidExits` we stop
    /// relaunching (a broken model/binary would otherwise loop every 2s forever).
    private var lastLaunchUptime: TimeInterval = 0
    private var rapidExitCount = 0
    private let rapidExitWindow: TimeInterval = 30
    private let maxRapidExits = 5

    /// Fired on main when a crashed server is about to be relaunched — the UI
    /// re-verifies the engine (Status row "engine restarting…").
    var onCrashRestart: (() -> Void)?
    /// Fired on main when the rapid-exit cap trips: dictation is dead until the
    /// user acts (the readiness row goes ❌ → tray red).
    var onGaveUp: ((String) -> Void)?

    private var serverBinary: String? {
        let path = Config.serverBinaryPath
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    private var prompt: String {
        var base = "A technical discussion about AI and software engineering."
        if let text = try? String(contentsOfFile: Config.promptFilePath, encoding: .utf8) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { base = trimmed }
        }
        // Append the command primer LAST: whisper truncates the initial prompt to
        // its tail, so the control vocabulary stays in the most-recent context.
        guard Config.shared.voiceCommands else { return base }
        return base + " " + CommandProcessor.primer
    }

    func start() {
        killStaleServers()
        launch()
    }

    func stop() {
        isStopping = true
        process?.terminate()
        process = nil
    }

    /// Relaunch to pick up changed engine settings (model, model_dir, use_ane,
    /// port, args, prompt). In-process consumers already read the reloaded
    /// Config; only this external process must be replaced. We clear the old
    /// termination handler so killing it doesn't trigger the crash-restart path.
    func restart() {
        if let p = process {
            p.terminationHandler = nil
            p.terminate()
        }
        process = nil
        isStopping = false
        rapidExitCount = 0 // user-initiated restart starts a fresh streak
        killStaleServers()
        launch()
    }

    private func launch() {
        guard let binary = serverBinary else {
            Log.error("[ServerManager] No whisper-server binary at \(Config.serverBinaryPath)")
            return
        }

        let model = Config.modelPath
        guard FileManager.default.fileExists(atPath: model) else {
            Log.error("[ServerManager] Model not found: \(model)")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        var args = [
            "-m", model,
            "--host", "127.0.0.1",
            "--port", String(Config.shared.serverPort),
            "-sns",
            "--prompt", prompt,
        ]
        let extra = Config.shared.serverArgs.split(separator: " ").map(String.init)
        args.append(contentsOf: extra)
        process.arguments = args
        // The CoreML encoder path is resolved relative to the model file, so
        // models/ggml-<model>-encoder.mlmodelc is picked up automatically.

        // Server output goes to server.log: truncated on the run's FIRST launch
        // (the one ReadinessChecker watches), appended with a banner on any
        // relaunch — so a crash's final output survives the restart.
        let serverLogPath = Config.serverLogPath
        let fresh = !truncatedLogThisRun
        if fresh || !FileManager.default.fileExists(atPath: serverLogPath) {
            FileManager.default.createFile(atPath: serverLogPath, contents: nil)
            truncatedLogThisRun = true
        }
        if let logHandle = FileHandle(forWritingAtPath: serverLogPath) {
            if !fresh {
                logHandle.seekToEndOfFile()
                logHandle.write(Data("\n===== whisper-server relaunch =====\n".utf8))
            }
            process.standardOutput = logHandle
            process.standardError = logHandle
        } else {
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
        }

        process.terminationHandler = { [weak self] proc in
            guard let self = self, !self.isStopping else { return }
            DispatchQueue.main.async {
                guard !self.isStopping else { return }
                let ranFor = ProcessInfo.processInfo.systemUptime - self.lastLaunchUptime
                self.rapidExitCount = ranFor < self.rapidExitWindow ? self.rapidExitCount + 1 : 1
                guard self.rapidExitCount < self.maxRapidExits else {
                    Log.error("[ServerManager] whisper-server exited (status \(proc.terminationStatus)) — \(self.rapidExitCount) rapid exits in a row, GIVING UP (see server.log). Fix the cause, then restart via Settings or relaunch the app.")
                    self.onGaveUp?("engine keeps crashing (\(self.rapidExitCount)×) — see server.log")
                    return
                }
                Log.error("[ServerManager] whisper-server exited (status \(proc.terminationStatus)) after \(String(format: "%.0f", ranFor))s - restarting in 2s (\(self.rapidExitCount)/\(self.maxRapidExits))")
                self.onCrashRestart?()
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    guard !self.isStopping else { return }
                    self.launch()
                }
            }
        }

        do {
            try process.run()
            self.process = process
            lastLaunchUptime = ProcessInfo.processInfo.systemUptime
            Log.info("[ServerManager] whisper-server started (pid \(process.processIdentifier), \(binary)), output -> server.log")
        } catch {
            Log.error("[ServerManager] Failed to start whisper-server: \(error)")
        }
    }

    /// Kill any server left over from a previous run (e.g. after a crash),
    /// otherwise our port is taken.
    private func killStaleServers() {
        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkill.arguments = ["-f", "whisper-server.*--port \(Config.shared.serverPort)"]
        try? pkill.run()
        pkill.waitUntilExit()
    }
}

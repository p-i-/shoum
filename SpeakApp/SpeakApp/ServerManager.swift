import Foundation

/// Owns a resident whisper-server process so the model is loaded once at app
/// launch instead of on every utterance.
class ServerManager {
    private var process: Process?
    private var isStopping = false

    private var serverBinary: String? {
        let path = Config.serverBinaryPath
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    private var prompt: String {
        let promptPath = Config.promptFilePath
        if let text = try? String(contentsOfFile: promptPath, encoding: .utf8) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return "A technical discussion about AI and software engineering."
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

        // Server output goes to server.log, truncated each launch
        let serverLogPath = Config.serverLogPath
        FileManager.default.createFile(atPath: serverLogPath, contents: nil)
        if let logHandle = FileHandle(forWritingAtPath: serverLogPath) {
            process.standardOutput = logHandle
            process.standardError = logHandle
        } else {
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
        }

        process.terminationHandler = { [weak self] proc in
            guard let self = self, !self.isStopping else { return }
            Log.error("[ServerManager] whisper-server exited (status \(proc.terminationStatus)) - restarting in 2s")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                guard !self.isStopping else { return }
                self.launch()
            }
        }

        do {
            try process.run()
            self.process = process
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

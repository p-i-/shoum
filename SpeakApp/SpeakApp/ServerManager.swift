import Foundation

/// Owns a resident whisper-server process so the model is loaded once at app
/// launch instead of on every utterance.
class ServerManager {
    private var process: Process?
    private var isStopping = false

    private var serverBinary: String? {
        // Honor use_ane; fall back to whichever build exists.
        let builds = Config.shared.useANE ? ["build-coreml", "build"] : ["build", "build-coreml"]
        for build in builds {
            let path = Config.rootPath("whisper.cpp/\(build)/bin/whisper-server")
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    private var prompt: String {
        let promptPath = Config.rootPath("prompt.txt")
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

    private func launch() {
        guard let binary = serverBinary else {
            NSLog("[ServerManager] No whisper-server binary found under \(Config.speakRoot)/whisper.cpp")
            return
        }

        let model = Config.rootPath("whisper.cpp/models/ggml-\(Config.shared.model).bin")
        guard FileManager.default.fileExists(atPath: model) else {
            NSLog("[ServerManager] Model not found: \(model)")
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
        let serverLogPath = Config.rootPath("server.log")
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
            NSLog("[ServerManager] whisper-server exited (status \(proc.terminationStatus)) - restarting in 2s")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                guard !self.isStopping else { return }
                self.launch()
            }
        }

        do {
            try process.run()
            self.process = process
            NSLog("[ServerManager] whisper-server started (pid \(process.processIdentifier), \(binary)), output -> server.log")
        } catch {
            NSLog("[ServerManager] Failed to start whisper-server: \(error)")
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

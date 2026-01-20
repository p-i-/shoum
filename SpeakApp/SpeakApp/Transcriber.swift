import Foundation

class Transcriber {
    private let scriptPath: String

    init() {
        // Find the process_wav.sh script relative to the app bundle or in development location
        if let bundlePath = Bundle.main.path(forResource: "process_wav", ofType: "sh") {
            scriptPath = bundlePath
        } else {
            // Development fallback: look for it relative to the app's location
            let appPath = Bundle.main.bundlePath
            let speakDir = (appPath as NSString).deletingLastPathComponent
            let devPath = (speakDir as NSString).appendingPathComponent("process_wav.sh")

            if FileManager.default.fileExists(atPath: devPath) {
                scriptPath = devPath
            } else {
                // Try the parent speak directory
                let parentPath = ((speakDir as NSString).deletingLastPathComponent as NSString).appendingPathComponent("process_wav.sh")
                if FileManager.default.fileExists(atPath: parentPath) {
                    scriptPath = parentPath
                } else {
                    // Hardcoded fallback for development
                    scriptPath = NSString(string: "~/code/speak/process_wav.sh").expandingTildeInPath
                }
            }
        }
    }

    func transcribe(wavFile: URL, completion: @escaping (Result<String, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [self.scriptPath, wavFile.path]

            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            do {
                try process.run()
                process.waitUntilExit()

                let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

                if process.terminationStatus == 0 {
                    let output = String(data: outputData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                    DispatchQueue.main.async {
                        if output.isEmpty {
                            completion(.failure(TranscriberError.emptyTranscription))
                        } else {
                            completion(.success(output))
                        }
                    }
                } else {
                    let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
                    DispatchQueue.main.async {
                        completion(.failure(TranscriberError.scriptFailed(errorMessage)))
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }

    enum TranscriberError: LocalizedError {
        case emptyTranscription
        case scriptFailed(String)

        var errorDescription: String? {
            switch self {
            case .emptyTranscription:
                return "No speech detected in recording"
            case .scriptFailed(let message):
                return "Transcription failed: \(message)"
            }
        }
    }
}

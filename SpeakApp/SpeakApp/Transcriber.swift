import Foundation

/// Sends recorded WAV files to the resident whisper-server over localhost.
class Transcriber {
    private let inferenceURL = URL(string: "http://127.0.0.1:\(Config.shared.serverPort)/inference")!

    /// How long to keep retrying while the server is still starting up.
    /// Cold CoreML model load under system load has been observed at ~26s.
    private let connectDeadline: TimeInterval = 60
    private let retryInterval: TimeInterval = 0.4

    func transcribe(wavFile: URL, completion: @escaping (Result<String, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            let result = self.transcribeWithRetry(wavFile: wavFile)
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }

    private func transcribeWithRetry(wavFile: URL) -> Result<String, Error> {
        let deadline = Date().addingTimeInterval(connectDeadline)
        var attempt = 0

        while true {
            attempt += 1
            let result = performRequest(wavFile: wavFile)

            // Retry only connection failures (server still loading the model);
            // anything else is a real error.
            if case .failure(let error) = result,
               let urlError = error as? URLError,
               urlError.code == .cannotConnectToHost || urlError.code == .networkConnectionLost,
               Date() < deadline {
                if attempt == 1 || attempt % 5 == 0 {
                    NSLog("[Transcriber] server not reachable (attempt \(attempt)), retrying for up to %.0fs more", deadline.timeIntervalSinceNow)
                }
                Thread.sleep(forTimeInterval: retryInterval)
                continue
            }

            if attempt > 1 {
                NSLog("[Transcriber] server reachable after \(attempt) attempts")
            }
            return result
        }
    }

    private func performRequest(wavFile: URL) -> Result<String, Error> {
        guard let wavData = try? Data(contentsOf: wavFile) else {
            return .failure(TranscriberError.serverError("Could not read recording: \(wavFile.path)"))
        }

        let boundary = "speak-\(UUID().uuidString)"
        var request = URLRequest(url: inferenceURL)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60

        var body = Data()
        func appendField(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(wavData)
        body.append("\r\n".data(using: .utf8)!)
        appendField("response_format", "text")
        appendField("temperature", "0.0")
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<String, Error> = .failure(TranscriberError.serverError("No response"))

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }

            if let error = error {
                result = .failure(error)
                return
            }

            guard let http = response as? HTTPURLResponse, let data = data else {
                result = .failure(TranscriberError.serverError("Invalid response from whisper-server"))
                return
            }

            let text = String(data: data, encoding: .utf8) ?? ""

            guard http.statusCode == 200 else {
                result = .failure(TranscriberError.serverError("Server returned \(http.statusCode): \(text)"))
                return
            }

            // whisper-server reports some failures as HTTP 200 with an error
            // JSON body — don't let those through as transcribed text.
            if text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{\"error\"") {
                result = .failure(TranscriberError.serverError(text))
                return
            }

            let cleaned = Self.cleanTranscription(text)
            result = cleaned.isEmpty
                ? .failure(TranscriberError.emptyTranscription)
                : .success(cleaned)
        }
        task.resume()
        semaphore.wait()

        return result
    }

    /// Trim whitespace and drop non-speech annotations like [BLANK_AUDIO] or
    /// (coughs) that survive even with --suppress-nst.
    private static func cleanTranscription(_ raw: String) -> String {
        let lines = raw
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in
                guard !line.isEmpty else { return false }
                let isAnnotation = (line.hasPrefix("[") && line.hasSuffix("]"))
                    || (line.hasPrefix("(") && line.hasSuffix(")"))
                return !isAnnotation
            }
        let joined = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        // Whisper sometimes emits a spurious leading "." (or "...") when an
        // utterance opens with a brief silence — strip leading dots/whitespace so
        // chunks don't start with a stray full stop (see log.txt: ". I think…").
        return String(joined.drop(while: { $0 == "." || $0 == "…" || $0.isWhitespace }))
    }

    enum TranscriberError: LocalizedError {
        case emptyTranscription
        case serverError(String)

        var errorDescription: String? {
            switch self {
            case .emptyTranscription:
                return "No speech detected in recording"
            case .serverError(let message):
                return "Transcription failed: \(message)"
            }
        }
    }
}

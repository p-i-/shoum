import Foundation

/// Sends recorded WAV files to the resident whisper-server over localhost.
class Transcriber {
    // Derived from Config.shared so a live port change applies without recreating.
    private var inferenceURL: URL { URL(string: "http://127.0.0.1:\(Config.shared.serverPort)/inference")! }

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
                    Log.info("[Transcriber] server not reachable (attempt \(attempt)), retrying for up to \(String(format: "%.0f", deadline.timeIntervalSinceNow))s more")
                }
                Thread.sleep(forTimeInterval: retryInterval)
                continue
            }

            if attempt > 1 {
                Log.info("[Transcriber] server reachable after \(attempt) attempts")
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
        // Disable token-level timestamps. The server defaults them ON, which
        // subdivides segments to attach per-token times — and those cuts land
        // mid-word ("open p"|"aren") / before punctuation ("generate"|"."). The
        // server joins segments with "\n" and cleanTranscription re-joins with a
        // space, so each split became a spurious space. We don't use token times,
        // and turning them off yields clean word-boundary segments (and is faster).
        appendField("token_timestamps", "false")
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
        // Join whisper's segments with a SPACE, not a newline: for continuous
        // dictation its segment breaks (at pauses / the 30s window boundary) are
        // artifacts, not intended paragraphs. Real breaks = separate chunks.
        var joined = lines.joined(separator: " ")
        // Whisper marks utterances it thinks trail off with an ellipsis ("...");
        // the user rarely does so deliberately. Strip runs of 2+ dots anywhere
        // (a real sentence-ending single "." survives), then collapse the double
        // space an interior strip can leave behind.
        joined = joined.replacingOccurrences(of: "\\.{2,}", with: "", options: .regularExpression)
        joined = joined.replacingOccurrences(of: " {2,}", with: " ", options: .regularExpression)
        joined = joined.trimmingCharacters(in: .whitespacesAndNewlines)
        // A spurious LEADING single "." (or whitespace) still slips through when
        // an utterance opens on a brief silence (see log.txt: ". I think...") —
        // the 2+-dot rule won't catch a lone dot, so strip leading dots here.
        return String(joined.drop(while: { $0 == "." || $0.isWhitespace }))
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

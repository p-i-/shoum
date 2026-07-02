import Foundation

/// Sends recorded WAV files to the resident whisper-server over localhost.
/// Each transcription runs as a cancellable `Task`: `cancel()` aborts the retry
/// loop and any in-flight request immediately (ESC during 🧠). The completion
/// still fires — promptly, with `.cancelled` — so callers keep one unwinding
/// path.
class Transcriber {
    // Derived from Config.shared so a live port change applies without recreating.
    private var inferenceURL: URL { URL(string: "http://127.0.0.1:\(Config.shared.serverPort)/inference")! }

    /// Default patience while the server comes up (a settings-change model
    /// reload is ~15–30 s under load). Callers can extend it — startup passes a
    /// longer deadline to cover a cold load plus a first-time ANE compile.
    private let defaultConnectDeadline: TimeInterval = 60
    private let retryInterval: TimeInterval = 0.4

    private var currentTask: Task<Void, Never>?

    func transcribe(wavFile: URL, connectDeadline: TimeInterval? = nil,
                    completion: @escaping (Result<String, Error>) -> Void) {
        let deadline = connectDeadline ?? defaultConnectDeadline
        currentTask = Task {
            let result = await self.transcribeWithRetry(wavFile: wavFile, connectDeadline: deadline)
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Abort the in-flight transcription (both the retry loop and a live
    /// request — URLSession responds to task cancellation immediately).
    func cancel() {
        currentTask?.cancel()
    }

    private func transcribeWithRetry(wavFile: URL, connectDeadline: TimeInterval) async -> Result<String, Error> {
        let deadline = Date().addingTimeInterval(connectDeadline)
        var attempt = 0

        while true {
            if Task.isCancelled { return .failure(TranscriberError.cancelled) }
            attempt += 1
            let result = await performRequest(wavFile: wavFile)

            if case .failure(let error) = result {
                if error is CancellationError || (error as? URLError)?.code == .cancelled {
                    return .failure(TranscriberError.cancelled)
                }
                // Retry only connection failures (server still loading the
                // model); anything else is a real error.
                if let urlError = error as? URLError,
                   urlError.code == .cannotConnectToHost || urlError.code == .networkConnectionLost,
                   Date() < deadline {
                    if attempt == 1 || attempt % 5 == 0 {
                        Log.info("[Transcriber] server not reachable (attempt \(attempt)), retrying for up to \(String(format: "%.0f", deadline.timeIntervalSinceNow))s more")
                    }
                    do { try await Task.sleep(nanoseconds: UInt64(retryInterval * 1_000_000_000)) }
                    catch { return .failure(TranscriberError.cancelled) }
                    continue
                }
            }

            if attempt > 1 {
                Log.info("[Transcriber] server reachable after \(attempt) attempts")
            }
            return result
        }
    }

    private func performRequest(wavFile: URL) async -> Result<String, Error> {
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

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let http = response as? HTTPURLResponse else {
                return .failure(TranscriberError.serverError("Invalid response from whisper-server"))
            }

            let text = String(data: data, encoding: .utf8) ?? ""

            guard http.statusCode == 200 else {
                return .failure(TranscriberError.serverError("Server returned \(http.statusCode): \(text)"))
            }

            // whisper-server reports some failures as HTTP 200 with an error
            // JSON body — don't let those through as transcribed text.
            if text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{\"error\"") {
                return .failure(TranscriberError.serverError(text))
            }

            let cleaned = Self.cleanTranscription(text)
            return cleaned.isEmpty
                ? .failure(TranscriberError.emptyTranscription)
                : .success(cleaned)
        } catch {
            return .failure(error)
        }
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
        case cancelled

        var errorDescription: String? {
            switch self {
            case .emptyTranscription:
                return "No speech detected in recording"
            case .serverError(let message):
                return "Transcription failed: \(message)"
            case .cancelled:
                return "Transcription cancelled"
            }
        }
    }
}

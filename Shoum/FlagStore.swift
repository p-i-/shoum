import Foundation

/// One flagged dictation incident, captured the moment an audio chunk is
/// converted and spliced into the box. Held in memory by the coordinator until
/// the next successful conversion supersedes it, so it can be flagged even after
/// the result has been pasted and the box is gone.
///
/// Two stages can go wrong and both are reproducible from this record:
///   • engine (audio → text): re-POST `kebabURL` (exactly what whisper saw) to
///     replay the transcription;
///   • post-processing (text → box): `boxBefore` / `replaced` / `chunk` /
///     `boxAfter` fully reproduce `OverlayWindow.smartJoin`.
struct LastInteraction {
    /// The audio actually sent to the engine — the silence-culled "kebab" when
    /// `prune_dead_audio` ran, else the raw recording. This is the file copied
    /// into a flag (so the same bytes can be re-thrown at the engine).
    let kebabURL: URL
    let pruned: Bool          // was VAD culling applied to produce kebabURL
    let durationSec: TimeInterval
    let rmsDBFS: Double
    let model: String
    let prompt: String        // prompt.txt in force at conversion time
    let timestamp: Date

    // Post-processing context (the smartJoin I/O).
    let chunk: String         // transcription handed to the box for this chunk
    let boxBefore: String     // box text just before the splice, marker included
    let boxAfter: String      // box text immediately after the splice
    let replaced: String      // selection the marker replaced (drives casing)
}

/// Persists flagged incidents to ~/Library/Application Support/Shoum/flags/
/// (dataRoot/flags) — durable across the 24h /tmp prune and reboots, so they can
/// be reviewed later. Each flag is a copy of the sent audio plus one JSON line.
enum FlagStore {
    static var flagsDir: String {
        let dir = (Config.dataRoot as NSString).appendingPathComponent("flags")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The prompt.txt contents in force right now (recorded with each flag, since
    /// the initial prompt biases the engine's output).
    static func currentPrompt() -> String {
        (try? String(contentsOfFile: Config.promptFilePath, encoding: .utf8)) ?? ""
    }

    private static func appVersion() -> String {
        let info = Bundle.main.infoDictionary
        let commit = info?["ShoumGitCommit"] as? String ?? "?"
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        return "\(short) (\(commit))"
    }

    /// Copy the sent audio into flags/ and append a JSON-lines record. Returns
    /// false only if the record line couldn't be written; a missing/uncopyable
    /// audio file still records the text context (with audio: null) rather than
    /// losing the whole incident.
    @discardableResult
    static func write(_ interaction: LastInteraction, note: String) -> Bool {
        let fm = FileManager.default
        let dir = flagsDir
        let base = "flag_\(Int(interaction.timestamp.timeIntervalSince1970))"

        // Copy the exact audio that hit the engine, if it's still on disk.
        var savedAudio: String? = nil
        let wavName = base + ".wav"
        let wavDest = URL(fileURLWithPath: (dir as NSString).appendingPathComponent(wavName))
        do {
            if fm.fileExists(atPath: wavDest.path) { try fm.removeItem(at: wavDest) }
            try fm.copyItem(at: interaction.kebabURL, to: wavDest)
            savedAudio = wavName
        } catch {
            Log.error("[FlagStore] could not copy audio \(interaction.kebabURL.lastPathComponent): \(error)")
        }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let record: [String: Any] = [
            "timestamp": iso.string(from: interaction.timestamp),
            "note": note,
            "transcription": interaction.chunk,
            "box_before": interaction.boxBefore,
            "box_after": interaction.boxAfter,
            "replaced": interaction.replaced,
            "audio": savedAudio as Any,        // null if the copy failed
            "pruned": interaction.pruned,
            "duration_s": (interaction.durationSec * 100).rounded() / 100,
            "rms_dbfs": (interaction.rmsDBFS * 10).rounded() / 10,
            "model": interaction.model,
            "prompt": interaction.prompt,
            "app_version": appVersion(),
        ]

        guard var data = try? JSONSerialization.data(
            withJSONObject: record, options: [.sortedKeys]) else {
            Log.error("[FlagStore] failed to serialize flag record")
            return false
        }
        data.append(0x0A) // newline → one record per line

        let jsonlPath = (dir as NSString).appendingPathComponent("flags.jsonl")
        if let fh = FileHandle(forWritingAtPath: jsonlPath) {
            defer { try? fh.close() }
            do {
                try fh.seekToEnd()
                fh.write(data)
            } catch {
                Log.error("[FlagStore] append failed: \(error)")
                return false
            }
        } else if !fm.createFile(atPath: jsonlPath, contents: data) {
            Log.error("[FlagStore] could not create flags.jsonl")
            return false
        }

        Log.info("[FlagStore] flagged → \(wavName) (audio: \(savedAudio != nil ? "saved" : "MISSING"))")
        return true
    }
}

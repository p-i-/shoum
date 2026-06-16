import Foundation

/// Builds a silence-removed ("kebab") copy of a recording using Silero VAD, so
/// only speech reaches whisper. Measured wins: cleaner punctuation (clean pauses
/// between segments) and far more speech fits in whisper's 30 s window. Off-path
/// from the live spectrogram: it re-VADs the finished WAV once at stop (warm from
/// the true start), then concatenates the speech segments with a short gap.
///
/// Owns one Silero instance, reused across stops (only ever called on the
/// transcribe path, serialized). Returns nil when culling can't/shouldn't happen
/// (no model, unreadable file, or no speech found) — the caller then either sends
/// the raw WAV or treats it as no-speech.
final class SilenceCuller {
    private let vad: SileroSpeechDetector?
    private let gapMs: Int

    /// `gapMs`: silence inserted between kept segments. ~100 ms keeps whisper's
    /// segmentation clean without wasting window budget (matches whisper's own VAD).
    init(gapMs: Int = 100) {
        vad = SileroSpeechDetector(modelPath: Config.vadModelPath)
        self.gapMs = gapMs
    }

    /// Whether culling is possible at all (Silero loaded).
    var available: Bool { vad != nil }

    /// Result of a cull attempt.
    enum Result {
        case culled(URL)   // a kebab WAV to send instead of the raw recording
        case noSpeech      // VAD found nothing — caller skips whisper
        case unavailable   // no model / unreadable — caller sends the raw WAV
    }

    func cull(_ wavURL: URL) -> Result {
        guard let vad = vad else { return .unavailable }
        guard let pcm = Self.readPCM16(wavURL) else {
            Log.error("[Culler] could not read \(wavURL.lastPathComponent)")
            return .unavailable
        }

        let floats = pcm.map { Float($0) / 32768.0 }
        let segs = vad.speechSegments(floats)
        guard !segs.isEmpty else { return .noSpeech }

        // Concatenate speech, padding each gap with a little silence.
        let gap = [Int16](repeating: 0, count: gapMs * 16000 / 1000)
        var out = [Int16]()
        out.reserveCapacity(segs.reduce(0) { $0 + max(0, $1.end - $1.start) } + gap.count * segs.count)
        for (i, s) in segs.enumerated() {
            let a = max(0, s.start), b = min(pcm.count, s.end)
            if b > a { out.append(contentsOf: pcm[a..<b]) }
            if i < segs.count - 1 { out.append(contentsOf: gap) }
        }
        guard !out.isEmpty else { return .noSpeech }

        let outURL = wavURL.deletingPathExtension().appendingPathExtension("kebab.wav")
        guard Self.writePCM16(out, to: outURL) else { return .unavailable }
        let kept = Double(out.count) / 16000.0, orig = Double(pcm.count) / 16000.0
        Log.info("[Culler] \(segs.count) speech segs: \(String(format: "%.1f", orig))s -> \(String(format: "%.1f", kept))s")
        return .culled(outURL)
    }

    // MARK: - Minimal 16 kHz mono 16-bit WAV IO

    private static func readPCM16(_ url: URL) -> [Int16]? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        let b = [UInt8](d)
        // Find the "data" subchunk (AVAudioFile may emit extra chunks before it).
        var i = 12, off = -1, len = 0
        while i + 8 <= b.count {
            let id = String(bytes: b[i..<i+4], encoding: .ascii) ?? ""
            let sz = Int(b[i+4]) | Int(b[i+5]) << 8 | Int(b[i+6]) << 16 | Int(b[i+7]) << 24
            if id == "data" { off = i + 8; len = sz; break }
            i += 8 + sz + (sz & 1)
        }
        guard off >= 0 else { return nil }
        let end = min(off + len, b.count)
        var out = [Int16](); out.reserveCapacity((end - off) / 2)
        var j = off
        while j + 1 < end {
            out.append(Int16(bitPattern: UInt16(b[j]) | UInt16(b[j+1]) << 8))
            j += 2
        }
        return out
    }

    private static func writePCM16(_ samples: [Int16], to url: URL) -> Bool {
        let dataBytes = samples.count * 2
        let sr: UInt32 = 16000, byteRate = sr * 2
        var h = [UInt8]()
        func u32(_ v: UInt32) { h.append(UInt8(v & 0xFF)); h.append(UInt8((v >> 8) & 0xFF)); h.append(UInt8((v >> 16) & 0xFF)); h.append(UInt8((v >> 24) & 0xFF)) }
        func u16(_ v: UInt16) { h.append(UInt8(v & 0xFF)); h.append(UInt8((v >> 8) & 0xFF)) }
        h.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + dataBytes))
        h.append(contentsOf: Array("WAVE".utf8))
        h.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1) // PCM, mono
        u32(sr); u32(byteRate); u16(2); u16(16)                          // align, 16-bit
        h.append(contentsOf: Array("data".utf8)); u32(UInt32(dataBytes))
        var data = Data(h)
        samples.withUnsafeBufferPointer { data.append(Data(buffer: $0)) }
        do { try data.write(to: url); return true }
        catch { Log.error("[Culler] write failed: \(error)"); return false }
    }
}

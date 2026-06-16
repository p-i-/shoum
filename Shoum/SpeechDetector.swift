import Foundation

/// Silero VAD (whisper.cpp's `whisper_vad_*`), run on CPU. The single speech
/// detector: a trained net that recognizes speech structure, so it catches quiet
/// voiced speech a crude energy gate would miss. Used two ways:
///   • the spectrogram calls `classify` for per-frame viridis/grey + the gauge;
///   • the silence culler calls `speechSegments` to build the kebab sent to whisper.
///
/// There is deliberately NO energy fallback: if Silero can't load we'd rather not
/// cull at all (send raw audio — safe) than prune with a blunt detector that drops
/// quiet speech. Callers treat a nil detector as "VAD unavailable".
///
/// Each instance owns a whisper_vad_context (its LSTM resets on every detect
/// call) and is single-threaded — give each user (spectrogram, culler) its own.
final class SileroSpeechDetector {
    let frameSize = 512 // Silero v5/v6 window @ 16 kHz
    private let ctx: OpaquePointer
    private let threshold: Float

    /// Fails (nil) if the model can't be loaded — caller degrades (no cull / grey).
    init?(modelPath: String, threshold: Float = 0.5) {
        guard FileManager.default.fileExists(atPath: modelPath) else {
            Log.error("[Silero] model not found at \(modelPath) — VAD unavailable (no cull, grey spectrogram)")
            return nil
        }
        var cp = whisper_vad_default_context_params()
        cp.n_threads = 4
        cp.use_gpu = false
        guard let c = whisper_vad_init_from_file_with_params(modelPath, cp) else {
            Log.error("[Silero] failed to init VAD context from \(modelPath)")
            return nil
        }
        ctx = c
        self.threshold = threshold
        Log.info("[Silero] VAD loaded from \(modelPath)")
    }

    deinit { whisper_vad_free(ctx) }

    /// Per-frame speech verdict (one bool per `frameSize` samples). For the
    /// spectrogram colouring. Empty if the buffer is too short.
    func classify(_ buffer: [Float]) -> [Bool] {
        guard detect(buffer) else { return [] }
        let n = Int(whisper_vad_n_probs(ctx))
        guard n > 0, let p = whisper_vad_probs(ctx) else { return [] }
        var out = [Bool](repeating: false, count: n)
        for i in 0..<n { out[i] = p[i] >= threshold }
        return out
    }

    /// Speech segments as 16 kHz sample ranges, with Silero's own min-duration +
    /// padding post-processing — for building the culled kebab. Empty if no speech.
    func speechSegments(_ buffer: [Float]) -> [(start: Int, end: Int)] {
        guard detect(buffer) else { return [] }
        var p = whisper_vad_default_params()
        p.threshold = threshold
        // min_speech_duration_ms / min_silence_duration_ms / speech_pad_ms keep
        // their sane defaults (250 / 100 / 30) so segments don't clip word edges.
        guard let segs = whisper_vad_segments_from_probs(ctx, p) else { return [] }
        defer { whisper_vad_free_segments(segs) }
        let n = Int(whisper_vad_segments_n_segments(segs))
        var out = [(start: Int, end: Int)]()
        out.reserveCapacity(n)
        for i in 0..<n {
            let t0 = whisper_vad_segments_get_segment_t0(segs, Int32(i)) // centiseconds
            let t1 = whisper_vad_segments_get_segment_t1(segs, Int32(i))
            out.append((Int(Double(t0) / 100.0 * 16000), Int(Double(t1) / 100.0 * 16000)))
        }
        return out
    }

    private func detect(_ buffer: [Float]) -> Bool {
        guard buffer.count >= frameSize else { return false }
        return buffer.withUnsafeBufferPointer {
            whisper_vad_detect_speech(ctx, $0.baseAddress, Int32($0.count))
        }
    }
}

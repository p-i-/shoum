import Foundation

/// Classifies 16 kHz mono audio as speech ("pertinent") or not. The spectrogram
/// paints pertinent frames viridis (silence grey) and the fuel gauge counts
/// pertinent time toward the 30 s whisper-window budget.
///
/// Batch interface: hand it a contiguous buffer, get one bool per `frameSize`
/// samples. Stateful detectors (Silero, whose LSTM resets each call) should be
/// fed the buffer with lead-in context — the caller re-runs over a rolling
/// `[emitted-warmup … now]` window each tick, so the verdicts it actually uses
/// are always warm.
///
/// Called only on the spectrogram's serial DSP queue → no internal locking.
protocol SpeechDetector: AnyObject {
    /// Samples per verdict (at 16 kHz).
    var frameSize: Int { get }
    /// One bool per `frameSize` samples of `buffer` (floor(count/frameSize)).
    func classify(_ buffer: [Float]) -> [Bool]
    func reset()
}

/// Broadband RMS-energy gate. Cheap, instant, and good enough on a clean signal,
/// but misses quiet voiced speech (low broadband RMS even when harmonics are
/// strong) — which is why Silero is preferred. Kept as the always-available
/// fallback when the Silero model can't be loaded.
final class EnergySpeechDetector: SpeechDetector {
    let frameSize = 512 // 32 ms @ 16 kHz, matching Silero's frame so verdicts align
    private let thresholdDBFS: Float
    init(thresholdDBFS: Float = -50) { self.thresholdDBFS = thresholdDBFS }

    func classify(_ buffer: [Float]) -> [Bool] {
        let n = buffer.count / frameSize
        guard n > 0 else { return [] }
        var out = [Bool](repeating: false, count: n)
        buffer.withUnsafeBufferPointer { b in
            for i in 0..<n {
                var sum: Float = 0
                let base = i * frameSize
                for j in 0..<frameSize { let v = b[base + j]; sum += v * v }
                let rms = (sum / Float(frameSize)).squareRoot()
                let db: Float = rms > 0 ? 20 * log10(rms) : -120
                out[i] = db >= thresholdDBFS
            }
        }
        return out
    }

    func reset() {}
}

/// Silero VAD (whisper.cpp's `whisper_vad_*`), run on CPU. A trained net that
/// recognizes speech structure, so it catches the quiet voiced speech the energy
/// gate misses. Per-frame probabilities thresholded into bools.
final class SileroSpeechDetector: SpeechDetector {
    let frameSize = 512 // Silero v5/v6 window @ 16 kHz
    private let ctx: OpaquePointer
    private let threshold: Float

    /// Fails (returns nil) if the model can't be loaded — caller falls back to
    /// the energy gate, so a missing model degrades rather than breaks.
    init?(modelPath: String, threshold: Float = 0.5) {
        guard FileManager.default.fileExists(atPath: modelPath) else {
            Log.info("[Silero] model not found at \(modelPath) — falling back to energy gate")
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

    func classify(_ buffer: [Float]) -> [Bool] {
        guard buffer.count >= frameSize else { return [] }
        let ok = buffer.withUnsafeBufferPointer {
            whisper_vad_detect_speech(ctx, $0.baseAddress, Int32($0.count))
        }
        guard ok else { return [] }
        let n = Int(whisper_vad_n_probs(ctx))
        guard n > 0, let p = whisper_vad_probs(ctx) else { return [] }
        var out = [Bool](repeating: false, count: n)
        for i in 0..<n { out[i] = p[i] >= threshold }
        return out
    }

    func reset() {} // the LSTM resets inside each detect call anyway

    deinit { whisper_vad_free(ctx) }
}

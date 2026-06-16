import Foundation

/// Classifies audio frames as speech-bearing ("pertinent") or silence/noise.
/// The spectrogram paints pertinent frames with viridis and the rest grey, and
/// the fuel gauge counts pertinent time toward the 30 s whisper-window budget.
///
/// This is the seam where the real VAD goes: energy thresholding today, Silero
/// (whisper.cpp's `whisper_vad_detect_speech`) planned as a drop-in replacement
/// behind this same interface. Silero will buffer internally and may lag the
/// live verdict by a frame or two — acceptable; the leading edge just re-settles.
///
/// Called only on the spectrogram's serial DSP queue, so implementations need no
/// internal locking.
protocol SpeechDetector: AnyObject {
    /// Verdict for one spectrogram frame (one emitted column).
    func classify(_ frame: [Float], sampleRate: Double) -> Bool
    /// Forget any running state at the start of a new recording.
    func reset()
}

/// Broadband RMS-energy gate with a short release hold so brief intra-word dips
/// don't flicker a speech run back to silence (mirrors VAD's speech padding).
/// Good enough to drive the visuals and an indicative budget; Silero will be
/// more accurate on soft speech and noise rejection.
final class EnergySpeechDetector: SpeechDetector {
    private let thresholdDBFS: Float
    private let releaseFrames: Int

    private var inSpeech = false
    private var silenceRun = 0

    /// `thresholdDBFS`: per-frame RMS level above which a frame counts as speech.
    /// Measured silence sits ~-80 dBFS and speech ~-25..-45, so -50 separates with
    /// margin. `releaseFrames`: keep calling it speech for this many quiet frames
    /// after the last loud one (~21 ms each at 48 kHz/1024), bridging short gaps.
    init(thresholdDBFS: Float = -50, releaseFrames: Int = 5) {
        self.thresholdDBFS = thresholdDBFS
        self.releaseFrames = releaseFrames
    }

    func classify(_ frame: [Float], sampleRate: Double) -> Bool {
        var sum: Float = 0
        for s in frame { sum += s * s }
        let rms = (sum / Float(max(frame.count, 1))).squareRoot()
        let dbfs: Float = rms > 0 ? 20 * log10(rms) : -120

        if dbfs >= thresholdDBFS {
            inSpeech = true
            silenceRun = 0
            return true
        }
        silenceRun += 1
        if inSpeech && silenceRun <= releaseFrames { return true } // hold through brief dips
        inSpeech = false
        return false
    }

    func reset() {
        inSpeech = false
        silenceRun = 0
    }
}

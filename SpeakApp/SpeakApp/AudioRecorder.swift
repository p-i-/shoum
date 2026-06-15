import AVFoundation
import Foundation

class AudioRecorder {
    // One engine for the app's lifetime, created and prepared up front so the
    // record path doesn't pay allocation cost. Stopped between recordings so
    // the system's mic-in-use indicator doesn't stay lit.
    private let audioEngine = AVAudioEngine()
    private var audioFile: AVAudioFile?
    private var recordingURL: URL?
    // All file writes go through this queue so stopRecording can drain
    // in-flight writes before the file is closed.
    private let writeQueue = DispatchQueue(label: "speak.audio.write")

    private(set) var isRecording = false

    /// Recordings are written here and kept for 24h (pruned at launch + on each
    /// stop) so a misfire — e.g. a silent clip whisper hallucinated into "Thank
    /// you" — can be inspected after the fact.
    static let recordingsDir = "/tmp/speak/wavs"
    private let retention: TimeInterval = 24 * 3600

    /// Leading frames to zero out so the start cue bleeding into the mic (no
    /// echo cancellation on the raw input) never reaches the file or the
    /// spectrogram. Set per recording from the cue's measured duration.
    private var framesToMute = 0
    private var framesMuted = 0

    /// RMS energy of the non-muted audio, exposed after stopRecording so the
    /// caller can skip whisper on near-silence (it hallucinates "Thank you").
    private var sumSquares: Double = 0
    private var rmsSampleCount: Int = 0
    private(set) var lastRMSdBFS: Double = -120

    /// Raw native-format samples from the recording tap, for visualization.
    /// Called on the audio thread — receivers must hop queues themselves.
    var onBuffer: ((_ samples: [Float], _ sampleRate: Double) -> Void)?

    /// Touch the input node and preallocate engine resources. Call once at
    /// launch (before any recording) — makes startRecording fast.
    func prepare() {
        pruneOldRecordings()
        _ = audioEngine.inputNode
        audioEngine.prepare()
    }

    /// Delete recordings older than the retention window. Cheap; runs at launch.
    func pruneOldRecordings() {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: Self.recordingsDir, withIntermediateDirectories: true)
        guard let names = try? fm.contentsOfDirectory(atPath: Self.recordingsDir) else { return }
        let cutoff = Date().addingTimeInterval(-retention)
        for name in names {
            let p = (Self.recordingsDir as NSString).appendingPathComponent(name)
            if let m = (try? fm.attributesOfItem(atPath: p))?[.modificationDate] as? Date, m < cutoff {
                try? fm.removeItem(atPath: p)
            }
        }
    }

    /// Records briefly without writing a file, reporting how many buffers the
    /// mic delivered and the peak level. Drives the splash "microphone live"
    /// check and doubles as the engine warm-up.
    func micProbe(duration: TimeInterval = 1.0,
                  completion: @escaping (_ buffers: Int, _ peak: Float) -> Void) {
        guard !isRecording else {
            completion(0, 0)
            return
        }

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        var buffers = 0
        var peak: Float = 0

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            buffers += 1
            if let ch = buffer.floatChannelData?[0] {
                for i in 0..<Int(buffer.frameLength) { peak = max(peak, abs(ch[i])) }
            }
        }

        do {
            try audioEngine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            Log.error("[AudioRecorder] mic probe: engine start failed: \(error)")
            completion(0, 0)
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self = self else { return }
            inputNode.removeTap(onBus: 0)
            if !self.isRecording {
                self.audioEngine.stop()
                self.audioEngine.prepare()
            }
            Log.info("[AudioRecorder] mic probe: \(buffers) buffers, peak \(peak)")
            completion(buffers, peak)
        }
    }

    func startRecording(muteSeconds: TimeInterval = 0) throws {
        let inputNode = audioEngine.inputNode

        // Persist into the retained recordings dir (pruned at 24h) so misfires
        // can be inspected later.
        let timestamp = Date().timeIntervalSince1970
        try? FileManager.default.createDirectory(atPath: Self.recordingsDir, withIntermediateDirectories: true)
        let fileURL = URL(fileURLWithPath: Self.recordingsDir)
            .appendingPathComponent("recording_\(Int(timestamp)).wav")
        recordingURL = fileURL

        // Get the native format and create our target format (16kHz, mono, 16-bit PCM)
        let nativeFormat = inputNode.outputFormat(forBus: 0)
        framesToMute = Int(muteSeconds * nativeFormat.sampleRate)
        framesMuted = 0
        sumSquares = 0
        rmsSampleCount = 0
        lastRMSdBFS = -120

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16000,
            channels: 1,
            interleaved: true
        ) else {
            throw RecorderError.formatCreationFailed
        }

        // Create the audio file
        audioFile = try AVAudioFile(
            forWriting: fileURL,
            settings: targetFormat.settings,
            commonFormat: .pcmFormatInt16,
            interleaved: true
        )

        // Create converter from native format to target format
        guard let converter = AVAudioConverter(from: nativeFormat, to: targetFormat) else {
            throw RecorderError.converterCreationFailed
        }

        // Small buffer (≈21ms @ 48kHz): tighter head-mute granularity, less
        // trailing audio captured at stop, finer energy resolution for the
        // spectrogram.
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: nativeFormat) { [weak self] buffer, _ in
            guard let self = self, let audioFile = self.audioFile else { return }

            // Zero the leading samples overlapping the start-cue window before
            // either consumer sees them, so the cue never lands in the file or
            // the spectrogram. The same treated buffer feeds both, so the strip
            // still scrolls crisply (it shows live silence, not the cue).
            if self.framesMuted < self.framesToMute {
                if let chans = buffer.floatChannelData {
                    let n = min(Int(buffer.frameLength), self.framesToMute - self.framesMuted)
                    for c in 0..<Int(buffer.format.channelCount) {
                        let ch = chans[c]
                        for i in 0..<n { ch[i] = 0 }
                    }
                }
                self.framesMuted += Int(buffer.frameLength)
            }

            // Accumulate energy over the non-muted audio (the boundary buffer's
            // zeroed head adds only zeros — negligible) for the no-speech gate.
            if self.framesMuted >= self.framesToMute, let ch = buffer.floatChannelData?[0] {
                let count = Int(buffer.frameLength)
                var ss = 0.0
                for i in 0..<count { let v = Double(ch[i]); ss += v * v }
                self.sumSquares += ss
                self.rmsSampleCount += count
            }

            if let onBuffer = self.onBuffer, let ch = buffer.floatChannelData?[0] {
                onBuffer(Array(UnsafeBufferPointer(start: ch, count: Int(buffer.frameLength))),
                         nativeFormat.sampleRate)
            }

            // Calculate output frame capacity
            let ratio = targetFormat.sampleRate / nativeFormat.sampleRate
            let outputFrameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio)

            guard let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: outputFrameCapacity
            ) else { return }

            // Hand the buffer to the converter exactly once per callback —
            // re-supplying it would duplicate audio. With rate conversion the
            // converter answers .inputRanDry once it's consumed; the frames it
            // produced are still valid.
            var consumed = false
            var error: NSError?
            let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
                if consumed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                consumed = true
                outStatus.pointee = .haveData
                return buffer
            }

            if (status == .haveData || status == .inputRanDry || status == .endOfStream),
               outputBuffer.frameLength > 0 {
                self.writeQueue.async {
                    do {
                        try audioFile.write(from: outputBuffer)
                    } catch {
                        Log.error("[AudioRecorder] write error: \(error)")
                    }
                }
            } else {
                Log.debug("[AudioRecorder] dropped buffer (status \(status.rawValue), err \(error?.localizedDescription ?? "none"))")
            }
        }

        do {
            try audioEngine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            audioFile = nil
            throw error
        }

        isRecording = true
    }

    func stopRecording() -> URL {
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        audioEngine.prepare() // ready for the next recording
        // Drain pending writes, then release the file so it closes flushed.
        writeQueue.sync {}
        audioFile = nil
        isRecording = false

        let rms = rmsSampleCount > 0 ? (sumSquares / Double(rmsSampleCount)).squareRoot() : 0
        lastRMSdBFS = rms > 0 ? 20 * log10(rms) : -120

        if let url = recordingURL,
           let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int {
            Log.info("[AudioRecorder] Recorded \(size) bytes (RMS \(String(format: "%.1f", lastRMSdBFS)) dBFS) to \(url.lastPathComponent)")
        }

        pruneOldRecordings()
        return recordingURL ?? URL(fileURLWithPath: "/tmp/error.wav")
    }

    enum RecorderError: Error {
        case formatCreationFailed
        case converterCreationFailed
    }
}

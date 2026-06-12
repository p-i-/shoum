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

    /// Raw native-format samples from the recording tap, for visualization.
    /// Called on the audio thread — receivers must hop queues themselves.
    var onBuffer: ((_ samples: [Float], _ sampleRate: Double) -> Void)?

    /// Touch the input node and preallocate engine resources. Call once at
    /// launch (before any recording) — makes startRecording fast.
    func prepare() {
        _ = audioEngine.inputNode
        audioEngine.prepare()
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
            NSLog("[AudioRecorder] mic probe: engine start failed: \(error)")
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
            NSLog("[AudioRecorder] mic probe: \(buffers) buffers, peak \(peak)")
            completion(buffers, peak)
        }
    }

    func startRecording() throws {
        let inputNode = audioEngine.inputNode

        // Create temp file path
        let timestamp = Date().timeIntervalSince1970
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent("recording_\(Int(timestamp)).wav")
        recordingURL = fileURL

        // Get the native format and create our target format (16kHz, mono, 16-bit PCM)
        let nativeFormat = inputNode.outputFormat(forBus: 0)

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

        // Install tap on input node
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: nativeFormat) { [weak self] buffer, _ in
            guard let self = self, let audioFile = self.audioFile else { return }

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
                        NSLog("[AudioRecorder] write error: \(error)")
                    }
                }
            } else {
                NSLog("[AudioRecorder] dropped buffer (status \(status.rawValue), err \(error?.localizedDescription ?? "none"))")
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

        if let url = recordingURL,
           let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int {
            NSLog("[AudioRecorder] Recorded \(size) bytes to \(url.lastPathComponent)")
        }

        return recordingURL ?? URL(fileURLWithPath: "/tmp/error.wav")
    }

    enum RecorderError: Error {
        case formatCreationFailed
        case converterCreationFailed
    }
}

import AVFoundation
import Foundation

class AudioRecorder {
    private var audioEngine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var recordingURL: URL?

    private(set) var isRecording = false

    func startRecording() throws {
        let audioEngine = AVAudioEngine()
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

            // Calculate output frame capacity
            let ratio = targetFormat.sampleRate / nativeFormat.sampleRate
            let outputFrameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio)

            guard let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: outputFrameCapacity
            ) else { return }

            var error: NSError?
            let status = converter.convert(to: outputBuffer, error: &error) { inNumPackets, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }

            if status == .haveData || status == .endOfStream {
                do {
                    try audioFile.write(from: outputBuffer)
                } catch {
                    print("Error writing audio: \(error)")
                }
            }
        }

        audioEngine.prepare()
        try audioEngine.start()

        self.audioEngine = audioEngine
        isRecording = true
    }

    func stopRecording() -> URL {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        audioFile = nil
        isRecording = false

        return recordingURL ?? URL(fileURLWithPath: "/tmp/error.wav")
    }

    enum RecorderError: Error {
        case formatCreationFailed
        case converterCreationFailed
    }
}

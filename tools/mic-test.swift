// Mic smoke test: records 3s from the default input through the same
// tap -> convert-to-16kHz-mono -> WAV pipeline SpeakApp uses, printing
// per-stage diagnostics. Run via tools/mic-test.sh.
import AVFoundation
import Foundation

let engine = AVAudioEngine()
let inputNode = engine.inputNode
let nativeFormat = inputNode.outputFormat(forBus: 0)
print("nativeFormat:", nativeFormat)

let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
let fileURL = URL(fileURLWithPath: "/tmp/speak-mic-test.wav")
try? FileManager.default.removeItem(at: fileURL)
let audioFile = try! AVAudioFile(forWriting: fileURL, settings: targetFormat.settings, commonFormat: .pcmFormatInt16, interleaved: true)

guard let converter = AVAudioConverter(from: nativeFormat, to: targetFormat) else {
    print("FAIL: converter creation failed (native \(nativeFormat))"); exit(1)
}

var callbackCount = 0
var writeCount = 0
var peak: Float = 0
let writeQueue = DispatchQueue(label: "mictest.write")

inputNode.installTap(onBus: 0, bufferSize: 4096, format: nativeFormat) { buffer, _ in
    callbackCount += 1
    if let ch = buffer.floatChannelData?[0] {
        for i in 0..<Int(buffer.frameLength) { peak = max(peak, abs(ch[i])) }
    }
    let ratio = targetFormat.sampleRate / nativeFormat.sampleRate
    let cap = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
    guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: cap) else {
        print("cb\(callbackCount): output buffer alloc FAILED (cap \(cap))"); return
    }
    var consumed = false
    var error: NSError?
    let status = converter.convert(to: out, error: &error) { _, outStatus in
        if consumed { outStatus.pointee = .noDataNow; return nil }
        consumed = true
        outStatus.pointee = .haveData
        return buffer
    }
    if callbackCount <= 3 || status == .error {
        print("cb\(callbackCount): in \(buffer.frameLength) frames, status \(status.rawValue), out \(out.frameLength) frames, err \(error?.localizedDescription ?? "none")")
    }
    if (status == .haveData || status == .inputRanDry || status == .endOfStream), out.frameLength > 0 {
        writeQueue.async {
            do { try audioFile.write(from: out); writeCount += 1 }
            catch { print("WRITE ERROR: \(error)") }
        }
    }
}

engine.prepare()
try! engine.start()
print("recording 3s — say something...")
Thread.sleep(forTimeInterval: 3)

inputNode.removeTap(onBus: 0)
engine.stop()
writeQueue.sync {}
print("callbacks: \(callbackCount), writes: \(writeCount), input peak: \(peak), file frames: \(audioFile.length)")

let healthy = callbackCount > 10 && writeCount == callbackCount && audioFile.length > 30000 && peak > 0.0005
print(healthy ? "PASS — mic pipeline healthy (\(fileURL.path))" : "FAIL — see numbers above")
exit(healthy ? 0 : 1)

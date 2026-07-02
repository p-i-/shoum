import Foundation

/// The audio files behind one dictation, and the single place that knows when
/// each dies. A dictation produces the raw microphone WAV and — when culling
/// ran — a silence-culled "kebab" that's what actually went to whisper.
///
/// Every outcome funnels through exactly one disposal call, so the cleanup
/// matrix (success / failure / no-speech / cancel × keep_recordings ×
/// flag-retention) lives here instead of scattered across AppState's callbacks:
///   • no speech, error, or cancel → `discardAll()` — nothing outlives it;
///   • success → `discardAllButSent()` — the sent file is retained so the flag
///     feature can reproduce the conversion until the next dictation supersedes
///     it (AppState.releaseRetainedAudio disposes it then).
struct RecordingArtifacts {
    /// The raw microphone WAV from AudioRecorder.
    let raw: URL
    /// The silence-culled copy actually sent to whisper, when culling ran.
    private(set) var kebab: URL?

    /// What actually goes to the engine.
    var sent: URL { kebab ?? raw }

    mutating func culled(to url: URL) { kebab = url }

    /// The dictation produced no usable result — dispose everything.
    func discardAll() {
        Self.dispose(raw)
        if let kebab = kebab { Self.dispose(kebab) }
    }

    /// The dictation succeeded — dispose the raw (when distinct), keep the sent
    /// file for flagging.
    func discardAllButSent() {
        if kebab != nil { Self.dispose(raw) }
    }

    /// keep_recordings on → leave the file for the 24 h prune (debugging);
    /// off → delete now, and never SILENTLY fail: a failure here is either a
    /// benign already-gone file or a disk-filling bug — log it so the two are
    /// distinguishable.
    static func dispose(_ url: URL) {
        guard !Config.shared.keepRecordings else { return }
        do { try FileManager.default.removeItem(at: url) }
        catch { Log.debug("[Artifacts] could not remove \(url.lastPathComponent): \(error.localizedDescription)") }
    }
}

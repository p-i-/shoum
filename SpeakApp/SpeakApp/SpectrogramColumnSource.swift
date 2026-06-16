import Accelerate
import Foundation

/// Turns audio into spectrogram columns: 1024-point FFT → power spectrum →
/// absolute dBFS → viridis RGBA column, appended to the ring. Pure DSP, no UI.
/// The dBFS scale is anchored to a full-scale tone (see `fullScaleRefPower`) so
/// intensity is absolute — silence is dark, loud speech is bright. Runs on the
/// caller's serial queue.
final class SpectrogramColumnSource {
    let rows: Int
    private let ring: ColumnRing

    /// Per-frame speech/silence verdict — decides viridis vs grey and feeds the
    /// budget. Swappable (energy now, Silero later); only touched on this queue.
    private let detector: SpeechDetector

    /// Accumulated speech time (seconds) since the last `resetBudget`, for the
    /// fuel gauge. Written here (DSP queue), read from the display link, so locked.
    private let budgetLock = NSLock()
    private var _speechSeconds = 0.0

    private let fftSize = 1024
    private let fftLog2n: vDSP_Length = 10
    private let fftSetup = vDSP_create_fftsetup(10, FFTRadix(kFFTRadix2))!
    private lazy var hann: [Float] = {
        var w = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&w, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        return w
    }()

    private var rowBins: [(lo: Int, hi: Int)] = []
    private var pending: [Float] = []

    /// Box-drawing state. Each speech ("good") run gets a green outline. The
    /// right wall sits on the run's LAST speech column, which we only know once
    /// the next (silence) column arrives — so we hold one column back to amend it.
    private var lastSpeech: Bool?     // previous column's verdict (for the left wall)
    private var heldColumn: [UInt8]?  // column awaiting its possible right wall
    private var heldSpeech = false

    /// dBFS floor shown (maps to black); 0 dBFS = full-scale tone. Absolute, no
    /// auto-gain. brightnessGain lifts the mapped intensity since real mic
    /// levels never approach a full-scale sine.
    private let displayFloorDB: Float = -75
    private let brightnessGain: Float = 2

    /// Column emission rate (columns/sec) = sampleRate / fftSize. Drives the
    /// idle scroll speed so idle and live match. Default until first audio.
    private(set) var columnRate: Double = 48000.0 / 1024.0

    init(rows: Int, ring: ColumnRing, detector: SpeechDetector = EnergySpeechDetector()) {
        self.rows = rows
        self.ring = ring
        self.detector = detector
    }

    deinit { vDSP_destroy_fftsetup(fftSetup) }

    /// Feed audio; emits as many whole columns as the samples allow. Each frame
    /// is classified speech/silence: pertinent frames render viridis and add to
    /// the speech budget; the rest render grey.
    func push(_ samples: [Float], sampleRate: Double) {
        if rowBins.isEmpty { computeRowBins(sampleRate: sampleRate) }
        columnRate = sampleRate / Double(fftSize)
        pending.append(contentsOf: samples)
        let frameSeconds = Double(fftSize) / sampleRate
        while pending.count >= fftSize {
            let frame = Array(pending.prefix(fftSize))
            pending.removeFirst(fftSize)
            let speech = detector.classify(frame, sampleRate: sampleRate)
            var column = colorColumn(magnitudesDB(frame), speech: speech)
            if speech {
                drawBoxTopBottom(&column)               // box top/bottom along the run
                if lastSpeech != true { drawBoxWall(&column) } // left wall: run starts here
            }
            // Emit the held (previous) column, closing the box on its right if the
            // run ended at it (held was speech, this column isn't).
            if var held = heldColumn {
                if heldSpeech && !speech { drawBoxWall(&held) } // right wall
                ring.append(held)
            }
            heldColumn = column
            heldSpeech = speech
            lastSpeech = speech
            if speech {
                budgetLock.lock(); _speechSeconds += frameSeconds; budgetLock.unlock()
            }
        }
    }

    /// Accumulated speech seconds since the last `resetBudget` (thread-safe read).
    var speechSeconds: Double {
        budgetLock.lock(); defer { budgetLock.unlock() }
        return _speechSeconds
    }

    /// Zero the speech budget — call at the start of each recording.
    func resetBudget() {
        budgetLock.lock(); _speechSeconds = 0; budgetLock.unlock()
    }

    /// One scroll step with no signal: black column with the yellow flatline on
    /// the centre axis (time flows, signal is zero) — overwriting the axis line.
    func appendFlat() {
        var col = [UInt8](repeating: 0, count: rows * 4)
        setPixel(&col, rows / 2, (0xFF, 0xD6, 0x0A))
        ring.append(col)
    }

    /// Drop any half-accumulated samples and the detector's running state (on
    /// mode switch / clear). Does NOT zero the budget — see `resetBudget`.
    func resetPending() {
        pending.removeAll()
        detector.reset()
        lastSpeech = nil   // no spurious box wall at the start of a recording
        heldColumn = nil   // drop the held column (one frame, invisible)
        heldSpeech = false
    }

    // MARK: - DSP

    /// Build a column mirrored about the centre axis: lowest freq adjacent to
    /// the centre, highest at the top & bottom edges (−maxfreq … 0 … +maxfreq).
    /// The centre row is a faint axis in live; idle overwrites it with yellow.
    private func colorColumn(_ db: [Float], speech: Bool) -> [UInt8] {
        var col = [UInt8](repeating: 0, count: rows * 4)
        let span = -displayFloorDB
        let center = rows / 2
        setPixel(&col, center, Self.axisColor)
        for i in 0..<rowBins.count {
            let band = db[rowBins[i].lo...rowBins[i].hi].max() ?? -200
            let t = max(0, min(1, (band - displayFloorDB) / span * brightnessGain))
            // Pertinent (speech) frames get the vivid viridis ramp; non-pertinent
            // (silence/noise) frames get a dim grey ramp so they recede — the user
            // can see at a glance what's actually feeding whisper.
            let c: (UInt8, UInt8, UInt8)
            if speech {
                let rgb = Self.viridis[Int(t * 255)]
                c = (UInt8((rgb >> 16) & 0xFF), UInt8((rgb >> 8) & 0xFF), UInt8(rgb & 0xFF))
            } else {
                let g = UInt8(30 + t * 150)
                c = (g, g, g)
            }
            setPixel(&col, center - 1 - i, c) // mirror up   (toward +maxfreq)
            setPixel(&col, center + 1 + i, c) // mirror down (toward −maxfreq)
        }
        return col
    }

    /// Green box outline around a "good" (speech) run: top/bottom borders on every
    /// speech column, and a full-height wall at the run's first and last column.
    private func drawBoxTopBottom(_ col: inout [UInt8]) {
        setPixel(&col, 0, Self.boxColor); setPixel(&col, 1, Self.boxColor)
        setPixel(&col, rows - 1, Self.boxColor); setPixel(&col, rows - 2, Self.boxColor)
    }

    private func drawBoxWall(_ col: inout [UInt8]) {
        for r in 0..<rows { setPixel(&col, r, Self.boxColor) }
    }

    static let boxColor: (UInt8, UInt8, UInt8) = (50, 235, 100)

    private func setPixel(_ col: inout [UInt8], _ row: Int, _ rgb: (UInt8, UInt8, UInt8)) {
        guard row >= 0, row < rows else { return }
        let o = row * 4
        col[o] = rgb.0; col[o + 1] = rgb.1; col[o + 2] = rgb.2; col[o + 3] = 255
    }

    /// Half the rows: one band per side. i = 0 is adjacent to the centre axis
    /// (lowest freq); i = half-1 is the top/bottom edge (highest freq).
    private func computeRowBins(sampleRate: Double) {
        let binWidth = sampleRate / Double(fftSize)
        let fMin = 80.0, fMax = 8000.0
        let half = rows / 2
        rowBins = (0..<half).map { i in
            let tLo = Double(i) / Double(half)
            let tHi = Double(i + 1) / Double(half)
            let lo = max(1, Int(fMin * pow(fMax / fMin, tLo) / binWidth))
            let hi = max(lo, min(fftSize / 2 - 1, Int(fMin * pow(fMax / fMin, tHi) / binWidth)))
            return (lo, hi)
        }
    }

    /// Linear power spectrum (|FFT|²) of one frame — fftSize/2 bins.
    private func powerSpectrum(_ frame: [Float]) -> [Float] {
        var windowed = [Float](repeating: 0, count: fftSize)
        vDSP_vmul(frame, 1, hann, 1, &windowed, 1, vDSP_Length(fftSize))

        var realp = [Float](repeating: 0, count: fftSize / 2)
        var imagp = [Float](repeating: 0, count: fftSize / 2)
        var mags = [Float](repeating: 0, count: fftSize / 2)

        realp.withUnsafeMutableBufferPointer { rp in
            imagp.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBufferPointer { wp in
                    wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(fftSize / 2))
                    }
                }
                vDSP_fft_zrip(fftSetup, &split, 1, fftLog2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &mags, 1, vDSP_Length(fftSize / 2))
            }
        }
        return mags
    }

    /// 0 dBFS reference: peak power of a full-scale (±1) sine through the EXACT
    /// same window+FFT path — avoids hand-deriving vDSP's scaling.
    private lazy var fullScaleRefPower: Float = {
        var sine = [Float](repeating: 0, count: fftSize)
        let bin = 64.0 // any integer in-band bin
        for i in 0..<fftSize {
            sine[i] = Float(sin(2.0 * Double.pi * bin * Double(i) / Double(fftSize)))
        }
        return max(powerSpectrum(sine).max() ?? 1, 1e-12)
    }()

    private func magnitudesDB(_ frame: [Float]) -> [Float] {
        var mags = powerSpectrum(frame)
        var db = [Float](repeating: 0, count: fftSize / 2)
        var floorVal: Float = 1e-12
        vDSP_vsadd(mags, 1, &floorVal, &mags, 1, vDSP_Length(fftSize / 2))
        var ref = fullScaleRefPower // dBFS: 0 dB == full-scale tone
        vDSP_vdbcon(mags, 1, &ref, &db, 1, vDSP_Length(fftSize / 2), 0)
        return db
    }

    /// Faint neutral line drawn on the centre row in live mode (the 0 axis).
    static let axisColor: (UInt8, UInt8, UInt8) = (70, 70, 85)

    // matplotlib viridis, 256 entries, CC0.
    static let viridis: [UInt32] = [
        0x440154, 0x440256, 0x450457, 0x450559, 0x46075A, 0x46085C, 0x460A5D, 0x460B5E,
        0x470D60, 0x470E61, 0x471063, 0x471164, 0x471365, 0x481467, 0x481668, 0x481769,
        0x48186A, 0x481A6C, 0x481B6D, 0x481C6E, 0x481D6F, 0x481F70, 0x482071, 0x482173,
        0x482374, 0x482475, 0x482576, 0x482677, 0x482878, 0x482979, 0x472A7A, 0x472C7A,
        0x472D7B, 0x472E7C, 0x472F7D, 0x46307E, 0x46327E, 0x46337F, 0x463480, 0x453581,
        0x453781, 0x453882, 0x443983, 0x443A83, 0x443B84, 0x433D84, 0x433E85, 0x423F85,
        0x424086, 0x424186, 0x414287, 0x414487, 0x404588, 0x404688, 0x3F4788, 0x3F4889,
        0x3E4989, 0x3E4A89, 0x3E4C8A, 0x3D4D8A, 0x3D4E8A, 0x3C4F8A, 0x3C508B, 0x3B518B,
        0x3B528B, 0x3A538B, 0x3A548C, 0x39558C, 0x39568C, 0x38588C, 0x38598C, 0x375A8C,
        0x375B8D, 0x365C8D, 0x365D8D, 0x355E8D, 0x355F8D, 0x34608D, 0x34618D, 0x33628D,
        0x33638D, 0x32648E, 0x32658E, 0x31668E, 0x31678E, 0x31688E, 0x30698E, 0x306A8E,
        0x2F6B8E, 0x2F6C8E, 0x2E6D8E, 0x2E6E8E, 0x2E6F8E, 0x2D708E, 0x2D718E, 0x2C718E,
        0x2C728E, 0x2C738E, 0x2B748E, 0x2B758E, 0x2A768E, 0x2A778E, 0x2A788E, 0x29798E,
        0x297A8E, 0x297B8E, 0x287C8E, 0x287D8E, 0x277E8E, 0x277F8E, 0x27808E, 0x26818E,
        0x26828E, 0x26828E, 0x25838E, 0x25848E, 0x25858E, 0x24868E, 0x24878E, 0x23888E,
        0x23898E, 0x238A8D, 0x228B8D, 0x228C8D, 0x228D8D, 0x218E8D, 0x218F8D, 0x21908D,
        0x21918C, 0x20928C, 0x20928C, 0x20938C, 0x1F948C, 0x1F958B, 0x1F968B, 0x1F978B,
        0x1F988B, 0x1F998A, 0x1F9A8A, 0x1E9B8A, 0x1E9C89, 0x1E9D89, 0x1F9E89, 0x1F9F88,
        0x1FA088, 0x1FA188, 0x1FA187, 0x1FA287, 0x20A386, 0x20A486, 0x21A585, 0x21A685,
        0x22A785, 0x22A884, 0x23A983, 0x24AA83, 0x25AB82, 0x25AC82, 0x26AD81, 0x27AD81,
        0x28AE80, 0x29AF7F, 0x2AB07F, 0x2CB17E, 0x2DB27D, 0x2EB37C, 0x2FB47C, 0x31B57B,
        0x32B67A, 0x34B679, 0x35B779, 0x37B878, 0x38B977, 0x3ABA76, 0x3BBB75, 0x3DBC74,
        0x3FBC73, 0x40BD72, 0x42BE71, 0x44BF70, 0x46C06F, 0x48C16E, 0x4AC16D, 0x4CC26C,
        0x4EC36B, 0x50C46A, 0x52C569, 0x54C568, 0x56C667, 0x58C765, 0x5AC864, 0x5CC863,
        0x5EC962, 0x60CA60, 0x63CB5F, 0x65CB5E, 0x67CC5C, 0x69CD5B, 0x6CCD5A, 0x6ECE58,
        0x70CF57, 0x73D056, 0x75D054, 0x77D153, 0x7AD151, 0x7CD250, 0x7FD34E, 0x81D34D,
        0x84D44B, 0x86D549, 0x89D548, 0x8BD646, 0x8ED645, 0x90D743, 0x93D741, 0x95D840,
        0x98D83E, 0x9BD93C, 0x9DD93B, 0xA0DA39, 0xA2DA37, 0xA5DB36, 0xA8DB34, 0xAADC32,
        0xADDC30, 0xB0DD2F, 0xB2DD2D, 0xB5DE2B, 0xB8DE29, 0xBADE28, 0xBDDF26, 0xC0DF25,
        0xC2DF23, 0xC5E021, 0xC8E020, 0xCAE11F, 0xCDE11D, 0xD0E11C, 0xD2E21B, 0xD5E21A,
        0xD8E219, 0xDAE319, 0xDDE318, 0xDFE318, 0xE2E418, 0xE5E419, 0xE7E419, 0xEAE51A,
        0xECE51B, 0xEFE51C, 0xF1E51D, 0xF4E61E, 0xF6E620, 0xF8E621, 0xFBE723, 0xFDE725,
    ]
}

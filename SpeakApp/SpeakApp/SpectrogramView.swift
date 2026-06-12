import AppKit
import Accelerate

/// Scrolling spectrogram strip: a continuous timeline at ~46 columns/sec.
/// While the mic captures (.live), columns are 1024-point FFTs of the native
/// stream — log-frequency rows (80Hz–8kHz), viridis intensity. While the mic
/// is off (.idle), a timer keeps the scroll moving and the incoming columns
/// carry a yellow baseline at the bottom: time flows, signal is zero.
final class SpectrogramView: NSView {
    enum Mode { case idle, live }

    var mode: Mode = .idle {
        didSet { needsDisplay = true }
    }

    // matplotlib viridis, 256 entries, CC0. Generated from matplotlib 3.x;
    // endpoints #440154 / #FDE725, midpoint #21918C.
    private static let viridis: [UInt32] = [
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

    private let fftSize = 1024
    private let fftLog2n: vDSP_Length = 10
    private let fftSetup = vDSP_create_fftsetup(10, FFTRadix(kFFTRadix2))!
    private lazy var hann: [Float] = {
        var w = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&w, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        return w
    }()

    private let cols = 512
    private let rows = 48
    private var pixels: [UInt8]
    private var pending: [Float] = []
    private var rowBins: [(lo: Int, hi: Int)] = []
    private var runningMaxDB: Float = -20
    private var image: CGImage?
    private let queue = DispatchQueue(label: "speak.spectrogram", qos: .userInteractive)
    private var idleTimer: Timer?

    override init(frame: NSRect) {
        pixels = [UInt8](repeating: 0, count: 512 * 48 * 4)
        super.init(frame: frame)
        wantsLayer = true

        // Clocks the scroll while no audio buffers arrive (~46 cols/sec,
        // matching the live rate of 48000/1024). Only appends when the strip
        // is actually on screen and the mic is off.
        idleTimer = Timer.scheduledTimer(withTimeInterval: 1024.0 / 48000.0, repeats: true) { [weak self] _ in
            guard let self = self, self.mode == .idle, self.window?.isVisible == true else { return }
            self.queue.async {
                self.appendFlatColumn()
                let img = self.makeImage()
                DispatchQueue.main.async { self.image = img; self.needsDisplay = true }
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        idleTimer?.invalidate()
    }

    /// Called from the audio tap (any thread); cheap hand-off to our queue.
    func push(_ samples: [Float], sampleRate: Double) {
        guard mode == .live else { return } // tail buffers after stop don't draw
        queue.async { [weak self] in
            self?.process(samples, sampleRate: sampleRate)
        }
    }

    /// Wipe the timeline (used when the box is dismissed, so the next session
    /// starts with a clean strip).
    func clear() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.pending.removeAll()
            for i in 0..<self.pixels.count { self.pixels[i] = 0 }
            self.runningMaxDB = -20
            let img = self.makeImage()
            DispatchQueue.main.async { self.image = img; self.needsDisplay = true }
        }
    }

    // MARK: - DSP (on queue)

    private func process(_ samples: [Float], sampleRate: Double) {
        if rowBins.isEmpty { computeRowBins(sampleRate: sampleRate) }
        pending.append(contentsOf: samples)

        var advanced = false
        while pending.count >= fftSize {
            let frame = Array(pending.prefix(fftSize))
            pending.removeFirst(fftSize)
            appendColumn(magnitudesDB(frame))
            advanced = true
        }
        if advanced {
            let img = makeImage()
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.image = img
                self.needsDisplay = true
            }
        }
    }

    /// One scroll step with no signal: background column, yellow baseline
    /// pixels at the bottom edge.
    private func appendFlatColumn() {
        let stride = cols * 4
        for r in 0..<rows {
            let base = r * stride
            pixels.withUnsafeMutableBytes { buf in
                let p = buf.baseAddress!.advanced(by: base)
                memmove(p, p.advanced(by: 4), stride - 4)
            }
            let o = base + stride - 4
            if r >= rows - 2 { // bottom two pixel rows = the flatline
                pixels[o] = 0xFF; pixels[o + 1] = 0xD6; pixels[o + 2] = 0x0A; pixels[o + 3] = 255
            } else {
                pixels[o] = 0; pixels[o + 1] = 0; pixels[o + 2] = 0; pixels[o + 3] = 0
            }
        }
    }

    private func computeRowBins(sampleRate: Double) {
        let binWidth = sampleRate / Double(fftSize)
        let fMin = 80.0, fMax = 8000.0
        rowBins = (0..<rows).map { r in
            // row 0 = top of the image = highest frequency
            let tHi = Double(rows - r) / Double(rows)
            let tLo = Double(rows - r - 1) / Double(rows)
            let lo = max(1, Int(fMin * pow(fMax / fMin, tLo) / binWidth))
            let hi = max(lo, min(fftSize / 2 - 1, Int(fMin * pow(fMax / fMin, tHi) / binWidth)))
            return (lo, hi)
        }
    }

    private func magnitudesDB(_ frame: [Float]) -> [Float] {
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

        // 10*log10 of squared magnitudes = power dB (arbitrary reference)
        var db = [Float](repeating: 0, count: fftSize / 2)
        var floorVal: Float = 1e-12
        vDSP_vsadd(mags, 1, &floorVal, &mags, 1, vDSP_Length(fftSize / 2))
        var ref: Float = 1.0
        vDSP_vdbcon(mags, 1, &ref, &db, 1, vDSP_Length(fftSize / 2), 0)
        return db
    }

    private func appendColumn(_ db: [Float]) {
        // Slow-decay auto-gain so the map stays readable across mic levels
        let colMax = rowBins.map { db[$0.lo...$0.hi].max() ?? -120 }.max() ?? -120
        runningMaxDB = max(colMax, runningMaxDB - 0.5)
        runningMaxDB = max(runningMaxDB, -30) // don't amplify silence to full scale
        let lowDB = runningMaxDB - 60

        let stride = cols * 4
        for r in 0..<rows {
            let base = r * stride
            // shift this row one pixel left
            pixels.withUnsafeMutableBytes { buf in
                let p = buf.baseAddress!.advanced(by: base)
                memmove(p, p.advanced(by: 4), stride - 4)
            }
            let band = db[rowBins[r].lo...rowBins[r].hi].max() ?? -120
            let t = max(0, min(1, (band - lowDB) / 60))
            let rgb = Self.viridis[Int(t * 255)]
            let o = base + stride - 4
            pixels[o]     = UInt8((rgb >> 16) & 0xFF)
            pixels[o + 1] = UInt8((rgb >> 8) & 0xFF)
            pixels[o + 2] = UInt8(rgb & 0xFF)
            pixels[o + 3] = 255
        }
    }

    private func makeImage() -> CGImage? {
        pixels.withUnsafeMutableBytes { buf in
            CGContext(
                data: buf.baseAddress,
                width: cols,
                height: rows,
                bitsPerComponent: 8,
                bytesPerRow: cols * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )?.makeImage()
        }
    }

    // MARK: - Drawing (main thread)

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        ctx.setFillColor(NSColor.black.withAlphaComponent(0.55).cgColor)
        ctx.fill(bounds)

        if let image = image {
            ctx.interpolationQuality = .none
            ctx.draw(image, in: bounds)
        }
    }
}

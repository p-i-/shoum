import AppKit
import QuartzCore

/// Scrolling spectrogram strip. The display is driven by a `CADisplayLink` at
/// vsync, fully decoupled from audio arrival: the DSP producer
/// (`SpectrogramColumnSource`) deposits columns into a `ColumnRing` whenever
/// audio arrives (bursty is fine), and this view scrolls smoothly on its own
/// clock. A continuous fractional offset (sub-pixel layer translation) makes
/// motion smooth even though columns are discrete; the column image is only
/// rebuilt when a whole column scrolls in. Idle mode synthesises flat columns
/// at the same rate, so idle and live scroll identically.
final class SpectrogramView: NSView {
    enum Mode { case idle, live }

    var mode: Mode = .idle {
        didSet {
            guard mode != oldValue else { return }
            queue.async { [weak self] in self?.source.resetPending() }
            idleAccumulator = 0
        }
    }

    private let rows = 49 // odd → a true centre row for the mirror axis
    private let visibleCols = 512
    private let ring: ColumnRing
    private let source: SpectrogramColumnSource
    private let queue = DispatchQueue(label: "speak.spectrogram", qos: .userInteractive)

    private let stripLayer = CALayer()
    private var link: CADisplayLink?

    // Scroll state (consumer clock).
    private var displayPos = 0.0          // smoothed column position we chase to
    private var lastEnd = Int.min         // last integer column the texture showed
    private var lastTimestamp: CFTimeInterval = 0
    private var idleAccumulator = 0.0     // fractional flat columns owed
    private var composeBuf: [UInt8]

    /// Exponential smoothing time-constant: bursts of columns spread over ~this.
    private let smoothingTau = 0.10

    override init(frame: NSRect) {
        ring = ColumnRing(rows: 49, capacity: 512 + 128)
        source = SpectrogramColumnSource(rows: 49, ring: ring)
        composeBuf = [UInt8](repeating: 0, count: (512 + 1) * 49 * 4)
        super.init(frame: frame)

        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        layer?.masksToBounds = true
        stripLayer.magnificationFilter = .nearest
        stripLayer.anchorPoint = .zero
        // No implicit animations — we set frame/contents every frame ourselves.
        stripLayer.actions = ["position": NSNull(), "bounds": NSNull(),
                              "contents": NSNull(), "frame": NSNull()]
        layer?.addSublayer(stripLayer)
    }

    required init?(coder: NSCoder) { fatalError("not used") }
    deinit { link?.invalidate() }

    // MARK: - Public API (unchanged for callers)

    /// Called from the audio tap (any thread); cheap hand-off to the DSP queue.
    func push(_ samples: [Float], sampleRate: Double) {
        guard mode == .live else { return }
        queue.async { [weak self] in self?.source.push(samples, sampleRate: sampleRate) }
    }

    /// Wipe the timeline so the next session starts clean.
    func clear() {
        queue.async { [weak self] in self?.source.resetPending() }
        ring.reset()
        displayPos = 0
        lastEnd = .min
        idleAccumulator = 0
        stripLayer.contents = nil
    }

    // MARK: - Display link lifecycle

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { startLink() } else { stopLink() }
    }

    private func startLink() {
        guard link == nil else { return }
        let l = displayLink(target: self, selector: #selector(step(_:)))
        l.add(to: .main, forMode: .common)
        link = l
        lastTimestamp = 0
    }

    private func stopLink() {
        link?.invalidate()
        link = nil
    }

    @objc private func step(_ sender: CADisplayLink) {
        let now = sender.timestamp
        let dt = lastTimestamp == 0 ? sender.duration : max(0, now - lastTimestamp)
        lastTimestamp = now

        // Idle: synthesise flat columns at the real column rate so the strip
        // keeps scrolling at the same speed as live.
        if mode == .idle {
            idleAccumulator += dt * source.columnRate
            while idleAccumulator >= 1 {
                source.appendFlat()
                idleAccumulator -= 1
            }
        }

        // Smoothly chase the produced-column count (exponential, τ). Converts
        // bursty production into continuous motion.
        let produced = Double(ring.count)
        displayPos += (produced - displayPos) * (1 - exp(-dt / smoothingTau))
        if produced - displayPos < 0.01 { displayPos = produced } // settle exactly

        let end = Int(displayPos.rounded(.down))
        let frac = displayPos - Double(end)

        // Rebuild the texture only when a whole column has scrolled in.
        if end != lastEnd {
            ring.compose(endColumn: end, width: visibleCols + 1, into: &composeBuf)
            stripLayer.contents = makeImage()
            lastEnd = end
        }

        // Sub-pixel scroll: translate the (1-column-wider) strip left by the
        // fractional part. Free GPU compositing, runs every vsync.
        let px = pxPerColumn
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stripLayer.frame = CGRect(x: -(1 + frac) * px, y: 0,
                                  width: Double(visibleCols + 1) * px,
                                  height: bounds.height)
        CATransaction.commit()
    }

    private var pxPerColumn: Double {
        bounds.width > 0 ? bounds.width / Double(visibleCols) : 1
    }

    private func makeImage() -> CGImage? {
        composeBuf.withUnsafeMutableBytes { buf in
            CGContext(
                data: buf.baseAddress,
                width: visibleCols + 1,
                height: rows,
                bitsPerComponent: 8,
                bytesPerRow: (visibleCols + 1) * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )?.makeImage()
        }
    }

    override func layout() {
        super.layout()
        stripLayer.contentsScale = window?.backingScaleFactor ?? 2
    }
}

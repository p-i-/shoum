import AppKit

/// Minimal speech-budget meter beneath the spectrogram. It shows how full the
/// 30 s whisper window is, counting only *speech* time (silence is culled, so it
/// doesn't fill the window) — the user watches this and stops before overflowing.
///
/// The bar fills left→right with accumulated speech. A red line marks the 30 s
/// boundary: while under budget it sits at the right edge; once speech exceeds
/// 30 s the whole bar squashes to fit, so the red line slides left and the
/// overflow shows past it in red. Its entire contract is one scalar,
/// `speechSeconds` — a future fancier renderer (the conveyor-belt) can replace
/// this view without touching anything upstream.
final class FuelGaugeView: NSView {
    /// The whisper window we're budgeting against.
    var budgetSeconds: Double = 30

    /// Accumulated speech time in the current recording. Drives the whole render.
    var speechSeconds: Double = 0 {
        didSet { if speechSeconds != oldValue { needsDisplay = true } }
    }

    /// True while speech is actively coming in — fill is green; white when paused.
    var active: Bool = false {
        didSet { if active != oldValue { needsDisplay = true } }
    }

    override func draw(_ dirtyRect: NSRect) {
        let w = bounds.width, h = bounds.height
        guard w > 0, h > 0 else { return }

        let bg = NSBezierPath(roundedRect: bounds, xRadius: 2, yRadius: 2)
        NSColor.black.withAlphaComponent(0.55).setFill()
        bg.fill()
        bg.addClip() // keep the fill inside the rounded corners

        guard speechSeconds > 0 else { return } // nothing captured yet → empty track

        // Squash-to-fit: the bar spans max(budget, accumulated), so going over a
        // window rescales everything and slides the boundary markers inward.
        let span = max(budgetSeconds, speechSeconds)
        let scale = w / CGFloat(span)
        let fillW = CGFloat(speechSeconds) * scale

        // Fill: green while actively capturing, white when paused/idle.
        (active
            ? NSColor(calibratedRed: 0.15, green: 0.85, blue: 0.45, alpha: 0.95)
            : NSColor(calibratedWhite: 0.95, alpha: 0.9)).setFill()
        CGRect(x: 0, y: 0, width: fillW, height: h).fill()

        // One red bar per COMPLETED 30 s window (at 100%, 200%, …) — a visual
        // count of how many encoder frames this clip will cost.
        let fullWindows = Int(speechSeconds / budgetSeconds)
        if fullWindows >= 1 {
            NSColor(calibratedRed: 1.0, green: 0.25, blue: 0.20, alpha: 1.0).setFill()
            for k in 1...fullWindows {
                let x = CGFloat(Double(k) * budgetSeconds) * scale
                CGRect(x: min(w - 2, x - 1), y: 0, width: 2, height: h).fill()
            }
        }
    }
}

private extension CGRect {
    func fill() { NSBezierPath(rect: self).fill() }
}

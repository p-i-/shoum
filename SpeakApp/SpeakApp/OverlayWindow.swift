import AppKit

class OverlayWindow {
    private let panel: NSPanel
    private let visualEffectView: NSVisualEffectView
    private(set) var textView: NSTextView
    private let scrollView: NSScrollView
    let spectrogram = SpectrogramView(frame: .zero)
    let fuelGauge = FuelGaugeView(frame: .zero)

    /// Marks the in-text recording indicator so it can be found and replaced
    /// even if the user edits around it. Never matched by glyph — the user
    /// could legitimately type a 🎙️.
    private static let markerAttribute = NSAttributedString.Key("speakRecordingMarker")
    private static let recordingGlyph = "🎙️"
    private static let processingGlyph = "🧠"

    /// What the 🎙️ marker replaced when recording started — its
    /// capitalization is inherited by the transcribed chunk.
    private var replacedSelectionText = ""

    var isVisible: Bool {
        panel.isVisible
    }

    init() {
        // Create panel
        let panelRect = NSRect(x: 0, y: 0, width: 750, height: 300)
        panel = NSPanel(
            contentRect: panelRect,
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        panel.level = .floating
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // No window-level alphaValue: it flattens the .hudWindow vibrancy into
        // plain transparency. Letting the material do the work gives a proper
        // frosted-glass look — translucent *and* blurring the backdrop.

        // Visual effect view for background
        visualEffectView = NSVisualEffectView(frame: panelRect)
        visualEffectView.material = .popover
        visualEffectView.state = .active
        visualEffectView.blendingMode = .behindWindow
        visualEffectView.alphaValue = 0.8 // ~20% see-through layered on top of the frost
        visualEffectView.wantsLayer = true
        visualEffectView.layer?.cornerRadius = 12
        visualEffectView.layer?.masksToBounds = true

        // Spectrogram strip at top (state display: live / frozen / flatline)
        spectrogram.translatesAutoresizingMaskIntoConstraints = false
        // Speech-budget fuel gauge directly beneath it, half its height.
        fuelGauge.translatesAutoresizingMaskIntoConstraints = false

        // Text view in scroll view
        textView = NSTextView()
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isRichText = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 16, weight: .regular)
        textView.textColor = .white
        textView.insertionPointColor = .white
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false

        scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = false
        scrollView.scrollerStyle = .legacy // persistent visible bar when text overflows
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        // Set up text view size
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: panelRect.width - 40, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true

        // Layout
        visualEffectView.addSubview(spectrogram)
        visualEffectView.addSubview(fuelGauge)
        visualEffectView.addSubview(scrollView)
        panel.contentView = visualEffectView

        NSLayoutConstraint.activate([
            spectrogram.topAnchor.constraint(equalTo: visualEffectView.topAnchor, constant: 10),
            spectrogram.leadingAnchor.constraint(equalTo: visualEffectView.leadingAnchor, constant: 12),
            spectrogram.trailingAnchor.constraint(equalTo: visualEffectView.trailingAnchor, constant: -12),
            spectrogram.heightAnchor.constraint(equalToConstant: 36),

            fuelGauge.topAnchor.constraint(equalTo: spectrogram.bottomAnchor, constant: 4),
            fuelGauge.leadingAnchor.constraint(equalTo: spectrogram.leadingAnchor),
            fuelGauge.trailingAnchor.constraint(equalTo: spectrogram.trailingAnchor),
            fuelGauge.heightAnchor.constraint(equalToConstant: 4),

            scrollView.topAnchor.constraint(equalTo: fuelGauge.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: visualEffectView.leadingAnchor, constant: 12),
            scrollView.trailingAnchor.constraint(equalTo: visualEffectView.trailingAnchor, constant: -12),
            scrollView.bottomAnchor.constraint(equalTo: visualEffectView.bottomAnchor, constant: -12),
        ])

        // The gauge's inputs: accumulated speech seconds + whether we're actively
        // capturing right now (drives the green/white fill).
        spectrogram.onSpeechBudgetUpdate = { [weak self] seconds, active in
            self?.fuelGauge.speechSeconds = seconds
            self?.fuelGauge.active = active
        }
    }

    /// Float above other apps (default) so the box appears over whatever you're
    /// dictating into; temporarily drop to normal so the Settings window can
    /// come in front of it.
    func setFloating(_ floating: Bool) {
        panel.level = floating ? .floating : .normal
    }

    // MARK: - Visibility

    func show() {
        if !panel.isVisible { centerOnScreen() }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(textView)
    }

    func hide() {
        panel.orderOut(nil)
        textView.string = ""
        spectrogram.mode = .idle
        spectrogram.clear()
    }

    // MARK: - Recording lifecycle

    /// Show the box, focus the editor, and drop the 🎙️ marker at the
    /// insertion point: audio lands HERE.
    func showRecording() {
        show()
        removeMarkerIfAny()
        insertMarker(glyph: Self.recordingGlyph)
        spectrogram.mode = .live
    }

    /// Recording ended, transcription in flight: 🎙️ → 🧠; the strip keeps
    /// scrolling but new columns are flatline (mic is off).
    func markProcessing() {
        replaceMarker(glyph: Self.processingGlyph)
        spectrogram.mode = .idle
    }

    /// Transcription finished. Marker becomes the text (or vanishes when
    /// there's nothing to insert), with capitalization/punctuation/spacing
    /// adjusted to fit the surrounding text.
    func finish(with text: String?) {
        spectrogram.mode = .idle
        guard let range = markerRange(), let storage = textView.textStorage else {
            if let text = text { insertTextAtCursor(text) }
            return
        }

        let full = storage.string as NSString
        let left = full.substring(to: range.location)
        let right = full.substring(from: range.location + range.length)

        // Put the pre-recording selection back under the marker directly (kept off
        // the undo stack); the change registered below is the single undoable step
        // "what the user had" -> "the dictated chunk", so one Cmd+Z reverts a chunk.
        storage.replaceCharacters(
            in: range, with: NSAttributedString(string: replacedSelectionText, attributes: textAttributes()))
        let restored = NSRange(location: range.location, length: (replacedSelectionText as NSString).length)

        guard let text = text else {
            // Transcription failed/empty: leave the original selection in place
            // rather than deleting it along with the marker.
            textView.setSelectedRange(NSRange(location: range.location + restored.length, length: 0))
            return
        }

        let replacement = Self.smartJoin(
            chunk: text, left: left, right: right, replaced: replacedSelectionText)
        if textView.shouldChangeText(in: restored, replacementString: replacement) {
            storage.replaceCharacters(
                in: restored, with: NSAttributedString(string: replacement, attributes: textAttributes()))
            textView.didChangeText()
        }
        let cursor = NSRange(location: range.location + (replacement as NSString).length, length: 0)
        textView.setSelectedRange(cursor)
        textView.scrollRangeToVisible(cursor)
    }

    /// Whisper emits each chunk as a standalone sentence ("Putting it through
    /// its paces."); splice it to fit where it lands.
    static func smartJoin(chunk rawChunk: String, left: String, right: String, replaced: String) -> String {
        var chunk = rawChunk.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !chunk.isEmpty else { return chunk }

        let leftTrimmed = left.replacingOccurrences(
            of: "[ \\t]+$", with: "", options: .regularExpression)
        let rightTrimmed = right.replacingOccurrences(
            of: "^[ \\t]+", with: "", options: .regularExpression)

        // --- First-letter case ---
        // Never touch "I..." or acronyms; whisper capitalizes proper nouns on
        // its own and lowercasing those is rarer than mid-sentence splices.
        let firstWord = chunk.split(separator: " ").first.map(String.init) ?? chunk
        let looksProtected = firstWord == "I" || firstWord.hasPrefix("I'")
            || firstWord.count >= 2 && firstWord.prefix(2).allSatisfy { $0.isUppercase }

        if !looksProtected {
            if let replacedFirst = replaced.first(where: { $0.isLetter }) {
                // Inherit the replaced selection's case
                chunk = replacedFirst.isLowercase ? lowercasedFirst(chunk) : chunk
            } else if !leftTrimmed.isEmpty, !leftTrimmed.hasSuffix("\n") {
                // No selection: lowercase unless we're starting a sentence
                let sentenceEnders: Set<Character> = [".", "!", "?", "…"]
                if let lastChar = leftTrimmed.last, !sentenceEnders.contains(lastChar) {
                    chunk = lowercasedFirst(chunk)
                }
            }
        }

        // --- Trailing period ---
        // Drop the chunk's final "." when the text continues mid-sentence
        // (next char is lowercase or punctuation, incl. an existing ".").
        if chunk.hasSuffix(".") && !chunk.hasSuffix("..") {
            if let next = rightTrimmed.first, next.isLowercase || next.isPunctuation {
                chunk = String(chunk.dropLast())
            }
        }

        // --- Spacing at the seams ---
        let punctuationStart: Set<Character> = [",", ".", ";", ":", "!", "?", ")", "]", "}", "…"]
        if let lastLeft = left.last, !lastLeft.isWhitespace, !lastLeft.isNewline,
           let first = chunk.first, !punctuationStart.contains(first) {
            chunk = " " + chunk
        }
        if let firstRight = right.first, !firstRight.isWhitespace,
           !punctuationStart.contains(firstRight),
           let last = chunk.last, !last.isWhitespace {
            chunk += " "
        }

        return chunk
    }

    private static func lowercasedFirst(_ s: String) -> String {
        guard let first = s.first else { return s }
        return first.lowercased() + s.dropFirst()
    }

    // MARK: - Text

    func getText() -> String {
        // Exclude a marker if one is somehow still present
        guard let range = markerRange(), let storage = textView.textStorage else {
            return textView.string
        }
        return (storage.string as NSString).replacingCharacters(in: range, with: "")
    }

    func insertTextAtCursor(_ text: String) {
        show()
        let selectedRange = textView.selectedRange()
        if let textStorage = textView.textStorage,
           textView.shouldChangeText(in: selectedRange, replacementString: text) {
            let attributedText = NSAttributedString(string: text, attributes: textAttributes())
            textStorage.replaceCharacters(in: selectedRange, with: attributedText)
            textView.didChangeText()
        }
        let cursor = NSRange(location: selectedRange.location + (text as NSString).length, length: 0)
        textView.setSelectedRange(cursor)
        textView.scrollRangeToVisible(cursor)
    }

    // MARK: - Marker internals

    private func textAttributes() -> [NSAttributedString.Key: Any] {
        return [
            .font: textView.font ?? NSFont.monospacedSystemFont(ofSize: 16, weight: .regular),
            .foregroundColor: textView.textColor ?? NSColor.white,
        ]
    }

    private func insertMarker(glyph: String) {
        guard let storage = textView.textStorage else { return }
        var attrs = textAttributes()
        attrs[Self.markerAttribute] = true
        let marker = NSAttributedString(string: glyph, attributes: attrs)
        let range = textView.selectedRange()
        replacedSelectionText = (storage.string as NSString).substring(with: range)
        storage.replaceCharacters(in: range, with: marker)
        textView.setSelectedRange(NSRange(location: range.location + marker.length, length: 0))
    }

    private func replaceMarker(glyph: String) {
        guard let range = markerRange(), let storage = textView.textStorage else { return }
        var attrs = textAttributes()
        attrs[Self.markerAttribute] = true
        storage.replaceCharacters(in: range, with: NSAttributedString(string: glyph, attributes: attrs))
    }

    private func removeMarkerIfAny() {
        if let range = markerRange() {
            textView.textStorage?.replaceCharacters(in: range, with: "")
        }
    }

    private func markerRange() -> NSRange? {
        guard let storage = textView.textStorage, storage.length > 0 else { return nil }
        var found: NSRange?
        storage.enumerateAttribute(Self.markerAttribute,
                                   in: NSRange(location: 0, length: storage.length)) { value, range, stop in
            if value != nil {
                found = range
                stop.pointee = true
            }
        }
        return found
    }

    private func centerOnScreen() {
        guard let screen = NSScreen.main else { return }
        let screenRect = screen.visibleFrame
        let panelRect = panel.frame

        let x = screenRect.midX - panelRect.width / 2
        let y = screenRect.midY - panelRect.height / 2 + 100 // Slightly above center

        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

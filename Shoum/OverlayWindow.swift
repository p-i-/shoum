import AppKit

class OverlayWindow {
    private let panel: NSPanel
    private let visualEffectView: NSVisualEffectView
    private(set) var textView: NSTextView
    private let scrollView: NSScrollView
    let spectrogram = SpectrogramView(frame: .zero)
    let fuelGauge = FuelGaugeView(frame: .zero)

    /// Debug pane: the raw whisper response for the most recent chunk, in green.
    /// Hidden (height 0) unless `show_whisper_response` is on. See showWhisperResponse.
    private let whisperLabel: NSTextField = {
        let l = NSTextField(wrappingLabelWithString: "")
        l.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        l.textColor = .systemGreen
        l.maximumNumberOfLines = 3
        l.lineBreakMode = .byTruncatingTail
        l.translatesAutoresizingMaskIntoConstraints = false
        l.isHidden = true
        return l
    }()
    private var whisperHeight: NSLayoutConstraint!

    /// Marks the in-text recording indicator so it can be found and replaced
    /// even if the user edits around it. Never matched by glyph — the user
    /// could legitimately type a 🎙️.
    private static let markerAttribute = NSAttributedString.Key("speakRecordingMarker")
    private static let recordingGlyph = "🎙️"
    private static let processingGlyph = "🧠"

    /// What the 🎙️ marker replaced when recording started — its
    /// capitalization is inherited by the transcribed chunk.
    private var replacedSelectionText = ""

    /// The smartJoin I/O a successful `finish` performed — returned to the
    /// caller for the flag feature so a post-processing splice can be
    /// reproduced exactly.
    struct SpliceRecord {
        let boxBefore: String   // box text before the splice, marker included
        let replaced: String    // selection the marker replaced
        let chunk: String       // transcription going in
        let boxAfter: String    // box text after the splice
    }

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
        visualEffectView.addSubview(whisperLabel)
        visualEffectView.addSubview(scrollView)
        panel.contentView = visualEffectView

        whisperHeight = whisperLabel.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            spectrogram.topAnchor.constraint(equalTo: visualEffectView.topAnchor, constant: 10),
            spectrogram.leadingAnchor.constraint(equalTo: visualEffectView.leadingAnchor, constant: 12),
            spectrogram.trailingAnchor.constraint(equalTo: visualEffectView.trailingAnchor, constant: -12),
            spectrogram.heightAnchor.constraint(equalToConstant: 36),

            fuelGauge.topAnchor.constraint(equalTo: spectrogram.bottomAnchor, constant: 4),
            fuelGauge.leadingAnchor.constraint(equalTo: spectrogram.leadingAnchor),
            fuelGauge.trailingAnchor.constraint(equalTo: spectrogram.trailingAnchor),
            fuelGauge.heightAnchor.constraint(equalToConstant: 4),

            whisperLabel.topAnchor.constraint(equalTo: fuelGauge.bottomAnchor, constant: 6),
            whisperLabel.leadingAnchor.constraint(equalTo: visualEffectView.leadingAnchor, constant: 12),
            whisperLabel.trailingAnchor.constraint(equalTo: visualEffectView.trailingAnchor, constant: -12),
            whisperHeight,

            scrollView.topAnchor.constraint(equalTo: whisperLabel.bottomAnchor, constant: 8),
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
        fuelGauge.isHidden = true // shown only during recording/processing
    }

    /// Float above other apps (default) so the box appears over whatever you're
    /// dictating into; temporarily drop to normal so the Settings window can
    /// come in front of it.
    func setFloating(_ floating: Bool) {
        panel.level = floating ? .floating : .normal
    }

    // MARK: - Visibility

    func show() {
        snapHeightToLineGrid()
        if !panel.isVisible { centerOnScreen() }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(textView)
    }

    /// Trim the panel so the text scroll view's visible height is an exact whole
    /// number of text lines (plus the top/bottom inset). Left unsnapped, the clip
    /// view is a hair taller than a line multiple, so a scrolled box shows the
    /// bottom sliver of the line above — a row of stray pixels at the top edge.
    /// Runs once (the panel is fixed-size); shrinks from the bottom so the top
    /// edge stays put.
    private var didSnapHeight = false
    private func snapHeightToLineGrid() {
        guard !didSnapHeight else { return }
        panel.contentView?.layoutSubtreeIfNeeded()
        guard let lm = textView.layoutManager, let font = textView.font else { return }
        let lineHeight = lm.defaultLineHeight(for: font)
        let inset = textView.textContainerInset.height
        let clipHeight = scrollView.contentView.bounds.height
        let lines = floor((clipHeight - inset) / lineHeight)
        guard lines >= 1 else { return } // not laid out yet — retry on next show
        didSnapHeight = true
        let residual = clipHeight - (inset + lines * lineHeight)
        guard residual > 0.5 else { return }
        var frame = panel.frame
        frame.origin.y += residual      // keep the top edge fixed while shrinking
        frame.size.height -= residual
        panel.setFrame(frame, display: true)
    }

    func hide() {
        panel.orderOut(nil)
        textView.string = ""
        // Setting .string doesn't clear the undo stack — without this, ⌘Z in the
        // next session would resurrect the previous session's text.
        textView.undoManager?.removeAllActions()
        spectrogram.mode = .idle
        spectrogram.clear()
        fuelGauge.isHidden = true
        showWhisperResponse(nil)
    }

    /// Show the raw whisper response for the latest chunk in the green debug pane
    /// (or hide it when `text` is nil — e.g. the toggle is off). Lets you see what
    /// whisper actually produced before command processing.
    func showWhisperResponse(_ text: String?) {
        if let t = text, !t.isEmpty {
            whisperLabel.stringValue = "whisper › " + t
            whisperLabel.isHidden = false
            whisperHeight.constant = 42
        } else {
            whisperLabel.stringValue = ""
            whisperLabel.isHidden = true
            whisperHeight.constant = 0
        }
    }

    // MARK: - Recording lifecycle

    /// Show the box, focus the editor, and drop the 🎙️ marker at the
    /// insertion point: audio lands HERE.
    func showRecording() {
        show()
        removeMarkerIfAny()
        insertMarker(glyph: Self.recordingGlyph)
        spectrogram.mode = .live
        fuelGauge.phase = .recording
        fuelGauge.isHidden = false
    }

    /// Recording ended, transcription in flight: 🎙️ → 🧠; the strip keeps
    /// scrolling but new columns are flatline (mic is off).
    func markProcessing() {
        replaceMarker(glyph: Self.processingGlyph)
        spectrogram.mode = .idle
        fuelGauge.phase = .processing // pink
    }

    /// Transcription finished. Marker becomes the text (or vanishes when
    /// there's nothing to insert), with capitalization/punctuation/spacing
    /// adjusted to fit the surrounding text. Returns the splice it performed
    /// (nil when there was no text to insert).
    @discardableResult
    func finish(with text: String?) -> SpliceRecord? {
        spectrogram.mode = .idle
        fuelGauge.isHidden = true // processing done — gauge disappears
        guard let range = markerRange(), let storage = textView.textStorage else {
            if let text = text {
                let before = textView.string
                insertTextAtCursor(text)
                return SpliceRecord(
                    boxBefore: before, replaced: "", chunk: text, boxAfter: textView.string)
            }
            return nil
        }

        // Box text before any mutation (the 🧠 marker still in place encodes the
        // insertion point) — captured for the flag record's post-processing half.
        let boxBeforeWithMarker = storage.string
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
            return nil
        }

        let replacement = TextSplicer.smartJoin(
            chunk: text, left: left, right: right, replaced: replacedSelectionText)
        if textView.shouldChangeText(in: restored, replacementString: replacement) {
            storage.replaceCharacters(
                in: restored, with: NSAttributedString(string: replacement, attributes: textAttributes()))
            textView.didChangeText()
        }
        let cursor = NSRange(location: range.location + (replacement as NSString).length, length: 0)
        textView.setSelectedRange(cursor)
        textView.scrollRangeToVisible(cursor)

        return SpliceRecord(
            boxBefore: boxBeforeWithMarker, replaced: replacedSelectionText,
            chunk: text, boxAfter: storage.string)
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
        guard let range = markerRange(), let storage = textView.textStorage else {
            // Not an invariant violation: the user can edit the marker away
            // while recording (finish() then inserts at the cursor instead) —
            // but log it, since it also shows up in state-desync traces.
            Log.debug("[OverlayWindow] replaceMarker(\(glyph)): no marker present (user edited it away?)")
            return
        }
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

import AppKit

class OverlayWindow {
    private let panel: NSPanel
    private let visualEffectView: NSVisualEffectView
    private(set) var textView: NSTextView
    private let scrollView: NSScrollView
    private let statusLabel: NSTextField

    var isVisible: Bool {
        panel.isVisible
    }

    init() {
        // Create panel
        let panelRect = NSRect(x: 0, y: 0, width: 500, height: 200)
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

        // Visual effect view for background
        visualEffectView = NSVisualEffectView(frame: panelRect)
        visualEffectView.material = .hudWindow
        visualEffectView.state = .active
        visualEffectView.blendingMode = .behindWindow
        visualEffectView.wantsLayer = true
        visualEffectView.layer?.cornerRadius = 12
        visualEffectView.layer?.masksToBounds = true

        // Status label at top
        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        statusLabel.textColor = .lightGray
        statusLabel.alignment = .center
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

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
        scrollView.autohidesScrollers = true
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
        visualEffectView.addSubview(statusLabel)
        visualEffectView.addSubview(scrollView)
        panel.contentView = visualEffectView

        NSLayoutConstraint.activate([
            statusLabel.topAnchor.constraint(equalTo: visualEffectView.topAnchor, constant: 12),
            statusLabel.leadingAnchor.constraint(equalTo: visualEffectView.leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(equalTo: visualEffectView.trailingAnchor, constant: -16),

            scrollView.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: visualEffectView.leadingAnchor, constant: 12),
            scrollView.trailingAnchor.constraint(equalTo: visualEffectView.trailingAnchor, constant: -12),
            scrollView.bottomAnchor.constraint(equalTo: visualEffectView.bottomAnchor, constant: -12),
        ])
    }

    func show() {
        statusLabel.stringValue = ""
        centerOnScreen()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(textView)
    }

    func showWithStatus(_ status: String) {
        statusLabel.stringValue = status
        centerOnScreen()
        panel.makeKeyAndOrderFront(nil)
    }

    func hide() {
        panel.orderOut(nil)
        // Clear text when hiding
        textView.string = ""
        statusLabel.stringValue = ""
    }

    func getText() -> String {
        return textView.string
    }

    func insertTextAtCursor(_ text: String) {
        // Activate app and focus window before inserting (ensures correct text styling)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(textView)

        // This replaces the current selection (or inserts at cursor if no selection)
        let selectedRange = textView.selectedRange()
        if let textStorage = textView.textStorage {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: textView.font ?? NSFont.monospacedSystemFont(ofSize: 16, weight: .regular),
                .foregroundColor: textView.textColor ?? NSColor.white
            ]
            let attributedText = NSAttributedString(string: text, attributes: attributes)
            textStorage.replaceCharacters(in: selectedRange, with: attributedText)
            // Move cursor to end of inserted text
            let newCursorPosition = selectedRange.location + text.count
            textView.setSelectedRange(NSRange(location: newCursorPosition, length: 0))
        }

        // Clear status after inserting text
        statusLabel.stringValue = ""
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

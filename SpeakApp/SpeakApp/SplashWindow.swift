import AppKit

/// Startup checklist window: one row per CheckItem, live-updated by
/// ReadinessChecker via AppDelegate. Stays summonable from the menu bar as
/// the app's diagnostic view.
class SplashWindow: NSObject {
    static let autoCloseKey = "autoCloseSplash"

    private let panel: NSPanel
    private var rowLabels: [CheckItem: NSTextField] = [:]
    private let statusLine = NSTextField(labelWithString: "Starting up…")
    private var bottomRow: NSStackView!

    var isVisible: Bool { panel.isVisible }

    override init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 340),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Speak — startup checks"
        panel.isReleasedWhenClosed = false
        panel.level = .floating

        super.init()

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false

        statusLine.font = .systemFont(ofSize: 13, weight: .semibold)
        stack.addArrangedSubview(statusLine)
        stack.setCustomSpacing(14, after: statusLine)

        for item in CheckItem.allCases {
            let label = NSTextField(labelWithString: "⚪️ \(item.title)")
            label.font = .monospacedSystemFont(ofSize: 12.5, weight: .regular)
            label.lineBreakMode = .byTruncatingTail
            rowLabels[item] = label
            stack.addArrangedSubview(label)
        }

        let checkbox = NSButton(checkboxWithTitle: "Auto-close when ready",
                                target: self, action: #selector(toggleAutoClose(_:)))
        checkbox.state = UserDefaults.standard.bool(forKey: Self.autoCloseKey) ? .on : .off

        let closeButton = NSButton(title: "Close", target: self, action: #selector(closeClicked))
        closeButton.keyEquivalent = "\r"

        bottomRow = NSStackView(views: [checkbox, NSView(), closeButton])
        bottomRow.orientation = .horizontal
        bottomRow.distribution = .fill
        bottomRow.isHidden = true // appears once every check has resolved
        stack.addArrangedSubview(bottomRow)
        stack.setCustomSpacing(18, after: stack.arrangedSubviews[stack.arrangedSubviews.count - 2])

        let content = NSView()
        content.addSubview(stack)
        panel.contentView = content
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
            bottomRow.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
        ])
    }

    func show() {
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func update(_ item: CheckItem, state: CheckState) {
        guard let label = rowLabels[item] else { return }
        let detail = state.detail.isEmpty ? "" : " — \(state.detail)"
        label.stringValue = "\(state.emoji) \(item.title)\(detail)"
        label.textColor = state.isFailed ? .systemRed : .labelColor
    }

    /// Show the Close/auto-close controls once no check is still in flight.
    func setControlsVisible(_ visible: Bool) {
        bottomRow.isHidden = !visible
    }

    func markReady(autoCloseAllowed: Bool) {
        statusLine.stringValue = "Ready — double-tap to dictate"
        if autoCloseAllowed && UserDefaults.standard.bool(forKey: Self.autoCloseKey) {
            panel.orderOut(nil)
        }
    }

    func markFailed() {
        statusLine.stringValue = "Problems found — fix the ❌ items below"
    }

    @objc private func toggleAutoClose(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: Self.autoCloseKey)
    }

    @objc private func closeClicked() {
        panel.orderOut(nil)
    }
}

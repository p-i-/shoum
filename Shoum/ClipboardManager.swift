import AppKit
import Carbon.HIToolbox

class ClipboardManager {
    private var rememberedApp: NSRunningApplication?
    private var savedItems: [NSPasteboardItem]?
    private var didSave = false

    func rememberFrontmostApp() {
        rememberedApp = NSWorkspace.shared.frontmostApplication
    }

    /// Terminal emulators where keystroke injection (instead of ⌘V) sidesteps
    /// Claude Code's "[Pasted N lines]" paste-collapse. Editors with embedded
    /// terminals (VS Code/Cursor) are deliberately excluded — their bundle id is
    /// the editor's, indistinguishable from the editor pane.
    private static let terminalBundleIDs: Set<String> = [
        "com.googlecode.iterm2",          // iTerm2
        "com.apple.Terminal",             // Apple Terminal
        "com.mitchellh.ghostty",          // Ghostty
        "net.kovidgoyal.kitty",           // kitty
        "org.alacritty", "io.alacritty",  // Alacritty
        "com.github.wez.wezterm",         // WezTerm
        "dev.warp.Warp-Stable",           // Warp
        "co.zeit.hyper",                  // Hyper
    ]

    /// Whether the app captured at double-tap is a known terminal emulator.
    var rememberedAppIsTerminal: Bool {
        guard let id = rememberedApp?.bundleIdentifier else { return false }
        return Self.terminalBundleIDs.contains(id)
    }

    func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Snapshot the user's current clipboard (every item and type, best-effort)
    /// so it can be handed back after we borrow the pasteboard to deliver a paste.
    func saveClipboard() {
        let pb = NSPasteboard.general
        savedItems = pb.pasteboardItems?.compactMap { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy.types.isEmpty ? nil : copy
        }
        didSave = true
    }

    /// Restore the snapshotted clipboard (no-op if nothing was saved). An empty
    /// snapshot restores to empty — matching what the user actually had.
    func restoreClipboard() {
        guard didSave else { return }
        didSave = false
        let pb = NSPasteboard.general
        pb.clearContents()
        if let items = savedItems, !items.isEmpty { pb.writeObjects(items) }
        savedItems = nil
    }

    /// Give keyboard focus back to whatever app was frontmost before the
    /// overlay appeared (used when dismissing without pasting).
    func refocusRememberedApp() {
        rememberedApp?.activate(options: [])
    }

    func pasteToRememberedApp(_ text: String, restoreClipboardAfter: Bool = false) {
        // The clipboard still holds the user's own content at this point; snapshot
        // it before we overwrite it with our payload so we can hand it back once
        // the paste has landed.
        if restoreClipboardAfter { saveClipboard() }
        copyToClipboard(text)

        guard let app = rememberedApp else {
            print("No remembered app to paste to")
            return
        }

        // Activate the remembered app
        app.activate(options: [])

        // Brief delay to ensure app is active
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.simulatePaste()
            if restoreClipboardAfter {
                // The target reads the pasteboard only when IT processes the ⌘V
                // (a busy terminal can defer this), so restoring too soon lets the
                // deferred read grab the restored clipboard instead of our payload.
                // A generous 1s margin avoids that.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self?.restoreClipboard() }
            }
        }
    }

    // MARK: - Keystroke injection (terminals)

    private let eventTap: CGEventTapLocation = .cgAnnotatedSessionEventTap

    /// Deliver `text` by SYNTHESIZING KEYSTROKES — no clipboard at all: each line
    /// typed as Unicode key events, newlines as Shift+Return. For terminals where
    /// a ⌘V paste would collapse to a "[Pasted N lines]" placeholder. Paces itself
    /// with short sleeps on a background queue, so it never stalls the UI and the
    /// target keeps up. No clipboard means no race and no clobber.
    func typeToRememberedApp(_ text: String) {
        guard let app = rememberedApp else {
            print("No remembered app to type into")
            return
        }
        app.activate(options: [])
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.12) { [weak self] in
            self?.typeText(text)
        }
    }

    private func typeText(_ text: String) {
        let lines = text.components(separatedBy: "\n")
        for (i, line) in lines.enumerated() {
            typeLine(line)
            if i < lines.count - 1 { sendShiftReturn() }
        }
    }

    private func typeLine(_ line: String) {
        let src = CGEventSource(stateID: .hidSystemState)
        var i = line.startIndex
        while i < line.endIndex {
            // ≤18 UTF-16 units per event — a single key event's unicode string is
            // only reliably delivered up to ~20.
            let j = line.index(i, offsetBy: 18, limitedBy: line.endIndex) ?? line.endIndex
            let u = Array(line[i..<j].utf16)
            if let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true) {
                down.keyboardSetUnicodeString(stringLength: u.count, unicodeString: u)
                down.post(tap: eventTap)
            }
            if let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false) {
                up.keyboardSetUnicodeString(stringLength: u.count, unicodeString: u)
                up.post(tap: eventTap)
            }
            usleep(6000)
            i = j
        }
    }

    private func sendShiftReturn() {
        let src = CGEventSource(stateID: .hidSystemState)
        if let down = CGEvent(keyboardEventSource: src, virtualKey: 0x24, keyDown: true) { // 0x24 = Return
            down.flags = .maskShift
            down.post(tap: eventTap)
        }
        if let up = CGEvent(keyboardEventSource: src, virtualKey: 0x24, keyDown: false) {
            up.flags = .maskShift
            up.post(tap: eventTap)
        }
        usleep(6000)
    }

    private func simulatePaste() {
        // Create Cmd+V key event
        let source = CGEventSource(stateID: .hidSystemState)

        // Key codes: Command = 55, V = 9
        let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Command), keyDown: true)
        let vDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true)
        let vUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Command), keyDown: false)

        // Set command flag on V key events
        vDown?.flags = .maskCommand
        vUp?.flags = .maskCommand

        // Post events
        cmdDown?.post(tap: .cgAnnotatedSessionEventTap)
        vDown?.post(tap: .cgAnnotatedSessionEventTap)
        vUp?.post(tap: .cgAnnotatedSessionEventTap)
        cmdUp?.post(tap: .cgAnnotatedSessionEventTap)
    }
}

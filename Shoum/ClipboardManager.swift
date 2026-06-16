import AppKit
import Carbon.HIToolbox

class ClipboardManager {
    private var rememberedApp: NSRunningApplication?
    private var savedItems: [NSPasteboardItem]?
    private var didSave = false

    func rememberFrontmostApp() {
        rememberedApp = NSWorkspace.shared.frontmostApplication
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
                // Give the target app a moment to consume the synthetic ⌘V before
                // we put the user's clipboard back.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.restoreClipboard() }
            }
        }
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

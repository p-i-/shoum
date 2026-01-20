import AppKit
import Carbon.HIToolbox

class ClipboardManager {
    private var rememberedApp: NSRunningApplication?

    func rememberFrontmostApp() {
        rememberedApp = NSWorkspace.shared.frontmostApplication
    }

    func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    func pasteToRememberedApp(_ text: String) {
        copyToClipboard(text)

        guard let app = rememberedApp else {
            print("No remembered app to paste to")
            return
        }

        // Activate the remembered app
        app.activate(options: [.activateIgnoringOtherApps])

        // Brief delay to ensure app is active
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.simulatePaste()
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

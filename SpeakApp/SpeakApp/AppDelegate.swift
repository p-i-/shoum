import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate, AppStateDelegate {
    private var statusItem: NSStatusItem!
    private var appStateCoordinator: AppStateCoordinator!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("[SpeakApp] Starting up...")

        // Check for accessibility permissions
        checkAccessibilityPermissions()

        // Set up status item
        setupStatusItem()
        NSLog("[SpeakApp] Status item created")

        // Initialize app state coordinator
        appStateCoordinator = AppStateCoordinator()
        appStateCoordinator.delegate = self
        appStateCoordinator.start()
        NSLog("[SpeakApp] Ready - hold left-shift to record")
    }

    func applicationWillTerminate(_ notification: Notification) {
        appStateCoordinator?.stop()
    }

    // MARK: - Status Item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "waveform.circle", accessibilityDescription: "Speak")
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Speak", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - AppStateDelegate

    func appStateDidChange(to state: SpeakState) {
        updateStatusItemIcon(for: state)
    }

    private func updateStatusItemIcon(for state: SpeakState) {
        guard let button = statusItem?.button else { return }

        let symbolName: String
        switch state {
        case .idle:
            symbolName = "waveform.circle"
        case .recording:
            symbolName = "waveform.circle.fill"
        case .processing:
            symbolName = "ellipsis.circle"
        case .editing:
            symbolName = "pencil.circle"
        }

        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Speak")
    }

    // MARK: - Permissions

    private func checkAccessibilityPermissions() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        let trusted = AXIsProcessTrustedWithOptions(options as CFDictionary)

        if trusted {
            NSLog("[SpeakApp] Accessibility: GRANTED")
        } else {
            NSLog("[SpeakApp] Accessibility: NOT GRANTED - Please enable in System Settings > Privacy & Security > Accessibility")
        }
    }
}

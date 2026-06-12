import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate, AppStateDelegate, ReadinessDelegate {
    private var statusItem: NSStatusItem!
    private var appStateCoordinator: AppStateCoordinator!
    private var splash: SplashWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("[SpeakApp] Starting up...")

        // Check for accessibility permissions (prompts on first run)
        checkAccessibilityPermissions()

        // Set up status item
        setupStatusItem()

        splash = SplashWindow()
        splash.show()

        // Initialize app state coordinator; its ReadinessChecker drives the splash
        appStateCoordinator = AppStateCoordinator()
        appStateCoordinator.delegate = self
        appStateCoordinator.readiness.delegate = self
        appStateCoordinator.start()
        NSLog("[SpeakApp] Startup checks running")
    }

    func applicationWillTerminate(_ notification: Notification) {
        appStateCoordinator?.stop()
    }

    // MARK: - Status Item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "hourglass.circle", accessibilityDescription: "Speak (starting)")
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Speak", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Show Status…", action: #selector(showStatus), keyEquivalent: "s"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    @objc private func showStatus() {
        splash.show()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func setStatusIcon(_ symbolName: String, _ description: String) {
        statusItem?.button?.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: description)
    }

    // MARK: - ReadinessDelegate

    func readinessDidUpdate(_ item: CheckItem, state: CheckState) {
        let readiness = appStateCoordinator.readiness
        splash.update(item, state: state)
        splash.setControlsVisible(readiness.allResolved)
        if readiness.anyFailed {
            splash.markFailed()
            setStatusIcon("xmark.circle", "Speak (problem)")
            // A failure should be seen even if the splash was closed
            if !splash.isVisible { splash.show() }
        } else if !readiness.isReady {
            setStatusIcon("hourglass.circle", "Speak (starting)")
        }
    }

    func readinessDidBecomeReady() {
        splash.markReady(autoCloseAllowed: !appStateCoordinator.readiness.anyFailed)
        setStatusIcon("waveform.circle", "Speak")
    }

    // MARK: - AppStateDelegate

    func appStateDidChange(to state: SpeakState) {
        // Until ready, the icon belongs to the readiness flow
        guard appStateCoordinator.readiness.isReady else { return }

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
        setStatusIcon(symbolName, "Speak")
    }

    func appStateNeedsAttention() {
        splash.show()
    }

    // MARK: - Permissions

    private func checkAccessibilityPermissions() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        let trusted = AXIsProcessTrustedWithOptions(options as CFDictionary)
        NSLog("[SpeakApp] Accessibility: \(trusted ? "GRANTED" : "NOT GRANTED")")
    }
}

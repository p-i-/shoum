import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate, AppStateDelegate, ReadinessDelegate {
    private var statusItem: NSStatusItem!
    private var appStateCoordinator: AppStateCoordinator!
    private var splash: SplashWindow!
    /// Did any check ever fail? If the user had to fix something, we keep the
    /// window up on success (don't auto-close, surface the resolved state).
    private var everFailed = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.info("[SpeakApp] Starting up...")

        // Capture any crash (NSException reason + backtrace) to the app log —
        // installed right after the log file is opened, before anything risky.
        CrashReporter.install(logPath: Config.appLogPath)

        // Check for accessibility permissions (prompts on first run)
        checkAccessibilityPermissions()

        // Set up status item
        setupStatusItem()

        splash = SplashWindow()
        splash.show() // foreground our window; the modal is now user-triggered via its button

        // Initialize app state coordinator; its ReadinessChecker drives the splash
        appStateCoordinator = AppStateCoordinator()
        appStateCoordinator.delegate = self
        appStateCoordinator.readiness.delegate = self
        appStateCoordinator.start()

        // Settings pane applies changes live via the coordinator.
        splash.onApply = { [weak self] engineChanged in
            self?.appStateCoordinator.applySettings(engineChanged: engineChanged)
        }
        // Drop the floating box below the Settings window while it's frontmost.
        splash.onKeyChange = { [weak self] settingsIsKey in
            self?.appStateCoordinator.setOverlayFloating(!settingsIsKey)
        }

        Log.info("[SpeakApp] Startup checks running")
    }

    func applicationWillTerminate(_ notification: Notification) {
        appStateCoordinator?.stop()
    }

    // MARK: - Status Item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "hourglass.circle", accessibilityDescription: "Speak (starting)")
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    // Left-click toggles the window; right-click (or control-click) shows a menu.
    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        let isRight = event?.type == .rightMouseUp
            || (event?.modifierFlags.contains(.control) ?? false)
        if isRight { showMenu() } else { splash.toggle() }
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Show Speak…", action: #selector(showStatus), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Speak", action: #selector(quit), keyEquivalent: "q"))
        if let button = statusItem.button {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
        }
    }

    @objc private func showStatus() {
        splash.show()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    /// Set the tray symbol. A non-nil `color` is applied via SF Symbol
    /// configuration (renders reliably in the menu bar); `contentTintColor` on a
    /// TEMPLATE status image draws NOTHING — confirmed root cause, see TRAYBUG.md.
    /// nil color → plain template image (auto-adapts to the menu-bar appearance).
    private func setIcon(_ symbolName: String, color: NSColor? = nil) {
        guard let button = statusItem?.button,
              let base = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Speak") else { return }
        if let color = color {
            let config = NSImage.SymbolConfiguration(hierarchicalColor: color)
            button.image = base.withSymbolConfiguration(config) ?? base
        } else {
            base.isTemplate = true
            button.image = base
        }
    }

    // MARK: - Tray pulse (startup)

    private var pulseTimer: Timer?

    private func startPulse() {
        guard pulseTimer == nil, let button = statusItem?.button else { return }
        button.alphaValue = 1.0
        var dim = false
        pulseTimer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in
            guard let button = self?.statusItem?.button else { return }
            dim.toggle()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.6
                button.animator().alphaValue = dim ? 0.4 : 1.0
            }
        }
    }

    private func stopPulse() {
        pulseTimer?.invalidate()
        pulseTimer = nil
        statusItem?.button?.alphaValue = 1.0
    }

    // MARK: - ReadinessDelegate

    func readinessDidUpdate(_ item: CheckItem, state: CheckState) {
        let readiness = appStateCoordinator.readiness
        splash.update(item, state: state)
        splash.setControlsVisible(readiness.allResolved)
        if readiness.anyFailed {
            everFailed = true
            splash.markFailed()
            stopPulse()
            setIcon("xmark.circle", color: .systemRed)
            // A failure should be seen even if the splash was closed
            if !splash.isVisible { splash.show() }
        } else if !readiness.isReady {
            startPulse()
            setIcon("hourglass.circle") // template, pulsing
        }
    }

    func readinessDidBecomeReady() {
        // Auto-close only on a clean startup. If the user fixed a problem (e.g.
        // granted Accessibility), keep the window and bring it back to front so
        // they land on the now-passing checklist instead of it vanishing.
        splash.markReady(autoCloseAllowed: !everFailed)
        if everFailed { splash.show() }
        stopPulse()
        setIcon("waveform.circle", color: .systemGreen)
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
        // Stay green once ready; swap only the symbol.
        setIcon(symbolName, color: .systemGreen)
    }

    func appStateNeedsAttention() {
        splash.show()
    }

    // MARK: - Permissions

    private func checkAccessibilityPermissions() {
        // Silent check only — no launch popup. The modal is triggered on demand
        // when the user clicks the Status window's "Open Settings…" button
        // (SplashWindow.openAccessibility), which both registers the app and
        // navigates. User-initiated, no surprise unanchored popup at launch.
        let trusted = AXIsProcessTrusted()
        Log.info("[SpeakApp] Accessibility: \(trusted ? "GRANTED" : "NOT GRANTED")")
    }
}

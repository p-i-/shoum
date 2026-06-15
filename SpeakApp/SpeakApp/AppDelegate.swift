import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate, AppStateDelegate, ReadinessDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var appStateCoordinator: AppStateCoordinator!
    private var splash: SplashWindow!
    private let updateChecker = UpdateChecker()
    private var updateAvailable = false
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

        // Notify-only update check (async; the menu reads `updateAvailable` the
        // next time it opens).
        updateChecker.check { [weak self] available in
            self?.updateAvailable = available
        }

        Log.info("[SpeakApp] Startup checks running")
    }

    func applicationWillTerminate(_ notification: Notification) {
        appStateCoordinator?.stop()
    }

    // MARK: - Status Item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "hourglass.circle",
                                           accessibilityDescription: "Speak (starting)")
        // A menu on the status item means every click — left OR right — opens it
        // (Docker-style). It's rebuilt on each open (menuNeedsUpdate) so the
        // status line reflects the current state.
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    // MARK: - Status-item menu (NSMenuDelegate)

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let status = NSMenuItem(title: statusLineTitle(), action: nil, keyEquivalent: "")
        status.isEnabled = false
        status.image = statusDot()
        menu.addItem(status)
        menu.addItem(.separator())

        menu.addItem(menuItem("Status…", "waveform.circle", #selector(openStatusTab)))
        menu.addItem(menuItem("Settings…", "gearshape", #selector(openSettingsTab), key: ","))
        menu.addItem(menuItem("About…", "info.circle", #selector(openAboutTab)))

        if updateAvailable {
            menu.addItem(.separator())
            let label = updateChecker.latestRemote.map { "Update available → \($0)" } ?? "Update available"
            menu.addItem(menuItem(label, "arrow.down.circle", #selector(openUpdate)))
        }

        menu.addItem(.separator())
        menu.addItem(menuItem("Quit Speak", "power", #selector(quit), key: "q"))
    }

    private func menuItem(_ title: String, _ symbol: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        return item
    }

    private func statusLineTitle() -> String {
        let readiness = appStateCoordinator.readiness
        if readiness.anyFailed { return "Setup needed — open Status" }
        if !readiness.isReady { return "Starting…" }
        switch appStateCoordinator.currentState {
        case .idle:       return "Ready — double-tap ⇧ to dictate"
        case .recording:  return "Recording — tap ⇧ to stop"
        case .processing: return "Transcribing…"
        case .editing:    return "Editing — tap ⇧ to paste"
        }
    }

    /// A small colored dot mirroring the tray state (Docker's green-dot idiom).
    private func statusDot() -> NSImage? {
        let readiness = appStateCoordinator.readiness
        let color: NSColor = readiness.anyFailed ? .systemRed
            : (readiness.isReady ? .systemGreen : .systemYellow)
        let config = NSImage.SymbolConfiguration(hierarchicalColor: color)
        return NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
    }

    @objc private func openStatusTab()   { splash.show(tab: "status") }
    @objc private func openSettingsTab() { splash.show(tab: "settings") }
    @objc private func openAboutTab()    { splash.show(tab: "about") }
    @objc private func openUpdate()      { NSWorkspace.shared.open(UpdateChecker.repoURL) }

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

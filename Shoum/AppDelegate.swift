import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate, AppStateDelegate, ReadinessDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    /// The constant menu-bar glyph (bundled template image). Loaded once; pulses
    /// while loading, tinted red on failure, otherwise drawn as-is (auto-adapts
    /// to the menu-bar appearance).
    private var trayGlyph: NSImage?
    private var appStateCoordinator: AppStateCoordinator!
    private var splash: SplashWindow!
    private let updateChecker = UpdateChecker()
    private var updateAvailable = false
    private var updateTimer: Timer?
    /// Fire the one-shot Accessibility prompt at most once per launch.
    private var didAutoPromptAccessibility = false
    /// One-shot observer that re-foregrounds our window once the user returns
    /// from System Settings after granting a permission during onboarding.
    private var postOnboardingObserver: NSObjectProtocol?
    /// Did any check ever fail? If the user had to fix something, we keep the
    /// window up on success (don't auto-close, surface the resolved state).
    private var everFailed = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.info("[Shoum] Starting up...")

        // Capture any crash (NSException reason + backtrace) to the app log —
        // installed right after the log file is opened, before anything risky.
        CrashReporter.install(logPath: Config.appLogPath)

        // Check for accessibility permissions (prompts on first run)
        checkAccessibilityPermissions()

        // Set up status item
        setupStatusItem()

        // Standard Edit menu so the dictation box gets native Cut/Copy/Paste/
        // Select All/Undo/Redo + the Emoji & Symbols palette.
        setupMainMenu()

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
        // next time it opens). Re-checked daily — as a login item the app can
        // run for weeks, so once-per-launch would go stale.
        updateChecker.check { [weak self] available in
            self?.updateAvailable = available
        }
        updateTimer = Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { [weak self] _ in
            self?.updateChecker.check { available in
                self?.updateAvailable = available
            }
        }

        Log.info("[Shoum] Startup checks running")
    }

    func applicationWillTerminate(_ notification: Notification) {
        disarmPostOnboardingForeground()
        appStateCoordinator?.stop()
    }

    // MARK: - Status Item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        // Load the bundled menu-bar glyph (a template, so it tints to the bar).
        // Sized to ~18pt tall; falls back to an SF Symbol if the asset is missing.
        if let url = Bundle.main.url(forResource: "menubar-glyph", withExtension: "png"),
           let img = NSImage(contentsOf: url), img.size.height > 0 {
            let h: CGFloat = 18
            img.size = NSSize(width: (h * img.size.width / img.size.height).rounded(), height: h)
            img.isTemplate = true
            trayGlyph = img
            statusItem.button?.image = img
        } else {
            Log.error("[AppDelegate] menu-bar glyph asset missing — using SF Symbol fallback")
            statusItem.button?.image = NSImage(systemSymbolName: "waveform.circle",
                                               accessibilityDescription: "Shoum")
        }
        // A menu on the status item means every click — left OR right — opens it
        // (Docker-style). It's rebuilt on each open (menuNeedsUpdate) so the
        // status line reflects the current state.
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    // MARK: - Main menu (Edit)

    /// As an `LSUIElement` app with no nib, we have no menu bar — so the standard
    /// editing shortcuts (⌘C/⌘V/⌘X/⌘A, ⌘Z/⌘⇧Z) and the Emoji & Symbols palette
    /// (⌃⌘Space) have nowhere to dispatch, even though the dictation box's
    /// NSTextView is first responder. A minimal main menu fixes all of them at
    /// once: each item targets the first responder (nil), so AppKit routes the
    /// key equivalents into the text view through the responder chain. The menu
    /// bar shows only while one of our windows is key.
    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // App menu (first slot; macOS labels it with the app name).
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Shoum",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        // Edit menu.
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        let emoji = editMenu.addItem(withTitle: "Emoji & Symbols",
                                     action: #selector(NSApplication.orderFrontCharacterPalette(_:)),
                                     keyEquivalent: " ")
        emoji.keyEquivalentModifierMask = [.command, .control]
        editItem.submenu = editMenu

        NSApp.mainMenu = mainMenu
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
        menu.addItem(menuItem("Commands…", "list.bullet", #selector(openCommandsTab)))
        menu.addItem(menuItem("About…", "info.circle", #selector(openAboutTab)))
        menu.addItem(menuItem("Report an issue…", "exclamationmark.bubble", #selector(reportIssue)))

        // Flag the last conversion for later review — only when there is one.
        if appStateCoordinator?.hasFlaggableInteraction == true {
            menu.addItem(.separator())
            menu.addItem(menuItem("Flag last dictation…", "flag", #selector(flagLast)))
        }

        if updateAvailable {
            menu.addItem(.separator())
            let label = updateChecker.latestRemote.map { "Update available → \($0)" } ?? "Update available"
            menu.addItem(menuItem(label, "arrow.down.circle", #selector(openUpdate)))
        }

        menu.addItem(.separator())
        menu.addItem(menuItem("Restart Engine", "arrow.clockwise", #selector(restartEngine)))
        menu.addItem(menuItem("Quit Shoum", "power", #selector(quit), key: "q"))
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
        if readiness.engineRestarting { return "Restarting engine…" }
        if readiness.anyWarning, !readiness.isReady { return "Action needed — open Status" }
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

    /// Prompt for an optional "what it should have said" note, then persist the
    /// last conversion (audio + box-before/after) as a flagged incident.
    @objc private func flagLast() {
        guard appStateCoordinator?.hasFlaggableInteraction == true else { return }

        let alert = NSAlert()
        alert.messageText = "Flag last dictation"
        alert.informativeText = "Saves the audio sent to the engine plus the box before/after, for later review. Optionally note what it should have said."
        alert.addButton(withTitle: "Flag")
        alert.addButton(withTitle: "Cancel")

        // Multi-line note field (~3 lines visible) in a scroll view.
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 58))
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        let field = NSTextView(frame: scroll.bounds)
        field.font = .systemFont(ofSize: 12)
        field.isRichText = false
        field.textContainerInset = NSSize(width: 4, height: 4)
        scroll.documentView = field
        alert.accessoryView = scroll
        alert.window.initialFirstResponder = field

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let ok = appStateCoordinator?.flagLastInteraction(note: field.string) ?? false
        if ok, Config.shared.sounds { NSSound(named: "Glass")?.play() }
    }

    @objc private func openStatusTab()   { splash.show(tab: "status") }
    @objc private func openSettingsTab() { splash.show(tab: "settings") }
    @objc private func openCommandsTab() { splash.show(tab: "commands") }
    @objc private func openAboutTab()    { splash.show(tab: "about") }
    @objc private func openUpdate()      { NSWorkspace.shared.open(UpdateChecker.repoURL) }

    /// Preview-then-open a prefilled GitHub issue (text only, logs opt-in —
    /// see IssueReporter's privacy contract).
    @objc private func reportIssue() {
        IssueReporter(readiness: appStateCoordinator?.readiness).run()
    }

    /// Docker-style engine restart: relaunch whisper-server, re-verify with a
    /// round-trip (menu status shows "Restarting engine…" meanwhile).
    @objc private func restartEngine() {
        appStateCoordinator?.restartEngine()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    /// Tray health: plain = working, yellow = degraded-but-usable (a warning
    /// needs the user), red = dictation cannot work. The glyph itself is
    /// constant; only its tint conveys health.
    private enum TrayHealth { case ok, warning, error }

    /// `contentTintColor` on a TEMPLATE status image draws NOTHING — so the
    /// colored states are NON-template tinted copies (confirmed root cause,
    /// see ARCHITECTURE.md invariant 7).
    private func setTray(_ health: TrayHealth) {
        guard let button = statusItem?.button, let glyph = trayGlyph else { return }
        switch health {
        case .ok:
            glyph.isTemplate = true
            button.image = glyph
        case .warning:
            button.image = tinted(glyph, .systemYellow)
        case .error:
            button.image = tinted(glyph, .systemRed)
        }
    }

    /// A non-template copy of `image` filled with `color` over its opaque pixels.
    private func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
        let out = NSImage(size: image.size)
        out.lockFocus()
        let rect = NSRect(origin: .zero, size: image.size)
        image.draw(in: rect, from: rect, operation: .sourceOver, fraction: 1.0)
        color.set()
        rect.fill(using: .sourceAtop)
        out.unlockFocus()
        out.isTemplate = false
        return out
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

        // First launch: the system shows the Microphone dialog automatically;
        // dismissing it hands focus back to whoever launched us (the Terminal),
        // burying our window. Once that resolves, re-assert our window — and
        // then, with it in front, auto-trigger the Accessibility prompt too.
        // Sequencing it AFTER mic (not at launch) keeps the two system dialogs
        // from stacking and anchors this one to our visible window — which is
        // exactly the "unanchored popup" problem that made us defer it before.
        // The small delay lets the mic dialog's focus-return settle first.
        if item == .micPermission, state.isOK || state.isFailed {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self = self else { return }
                self.splash.show()
                self.autoPromptAccessibilityIfNeeded()
            }
        }
        if readiness.anyFailed {
            everFailed = true
            splash.markFailed()
            stopPulse()
            setTray(.error)
            // A failure should be seen even if the splash was closed
            if !splash.isVisible { splash.show() }
        } else if readiness.anyWarning {
            // Something needs the user (permission grant, missing VAD model) —
            // degraded-but-usable: yellow, not red. everFailed keeps the
            // post-grant window/re-foreground handling onboarding relies on.
            everFailed = true
            splash.markWarning()
            setTray(.warning)
            startPulse()
            if !splash.isVisible { splash.show() }
        } else if !readiness.isReady {
            setTray(.ok)
            startPulse() // constant glyph, pulsing while loading
        }
    }

    func readinessDidBecomeReady() {
        // Auto-close only on a clean startup. If the user fixed a problem (e.g.
        // granted Accessibility), keep the window and bring it back to front so
        // they land on the now-passing checklist instead of it vanishing.
        splash.markReady(autoCloseAllowed: !everFailed)
        if everFailed {
            splash.show()
            armPostOnboardingForeground()
        }
        stopPulse()
        // Ready gates on mic+engine+hotkey only — a lingering warning (e.g. a
        // missing VAD model) keeps the tray yellow even though dictation works.
        setTray(appStateCoordinator.readiness.anyWarning ? .warning : .ok)
    }

    // MARK: - AppStateDelegate

    // (No per-state callback: the tray glyph is constant — recording/processing/
    // editing are conveyed by the overlay window, and the status-line title reads
    // currentState when the menu opens.)

    func appStateNeedsAttention() {
        splash.show()
    }

    // MARK: - Permissions

    private func checkAccessibilityPermissions() {
        // Silent check at launch — the prompt is NOT fired here (that was the old
        // "unanchored popup at startup" bug). It's auto-triggered later, after the
        // mic dialog resolves and our window is foregrounded (see
        // readinessDidUpdate → autoPromptAccessibilityIfNeeded), so the two system
        // dialogs sequence cleanly.
        let trusted = AXIsProcessTrusted()
        Log.info("[Shoum] Accessibility: \(trusted ? "GRANTED" : "NOT GRANTED")")
    }

    /// After the mic dialog has resolved and our window is in front, fire the
    /// system Accessibility prompt once (if still untrusted). One-shot: it
    /// registers the app in the Accessibility list and shows the dialog only
    /// until then — re-launches won't re-pester, and the Status window's button
    /// navigates straight to the pane afterward.
    private func autoPromptAccessibilityIfNeeded() {
        guard !didAutoPromptAccessibility, !AXIsProcessTrusted() else { return }
        didAutoPromptAccessibility = true
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(opts as CFDictionary)
        Log.info("[Shoum] auto-prompted Accessibility (post-mic)")
    }

    /// Onboarding required a grant, so the user was bounced through System
    /// Settings — and on a Stage Manager / Terminal-launched setup, closing it
    /// hands focus back to that app, burying our window. There's no "Settings
    /// closed" event, so we watch for the next activation of an app that's
    /// neither us nor System Settings (the practical "they're back in their own
    /// app" signal) and re-assert our window once, then stop fighting for focus.
    private func armPostOnboardingForeground() {
        guard postOnboardingObserver == nil else { return }
        postOnboardingObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self = self else { return }
            let bid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            if bid == Bundle.main.bundleIdentifier || bid == "com.apple.systempreferences" { return }
            self.disarmPostOnboardingForeground()
            self.splash.show()
            Log.info("[Shoum] post-onboarding: re-foregrounded over \(bid ?? "?")")
        }
    }

    private func disarmPostOnboardingForeground() {
        if let observer = postOnboardingObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            postOnboardingObserver = nil
        }
    }
}

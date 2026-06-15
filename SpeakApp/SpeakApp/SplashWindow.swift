import AppKit
import ServiceManagement

/// The app's window: a tabbed Status + Settings panel, summonable from the menu
/// bar. The Status tab is the live readiness checklist (updated by
/// ReadinessChecker via AppDelegate) plus a gesture cheat-sheet, the install
/// path, and deep-link buttons for missing permissions. The Settings tab mirrors
/// config.yaml as form controls (written back surgically) plus a prompt.txt
/// editor and the Start-at-login toggle.
class SplashWindow: NSObject, NSWindowDelegate, NSTextFieldDelegate, NSTextViewDelegate {
    static let autoCloseKey = "autoCloseSplash"

    private let panel: NSPanel
    private var tabView: NSTabView!
    private var rowLabels: [CheckItem: NSTextField] = [:]
    /// "Open Settings…" buttons for the two permission rows, shown when failed.
    private var permissionButtons: [CheckItem: NSButton] = [:]
    private let statusLine = NSTextField(labelWithString: "Starting up…")
    private var bottomRow: NSStackView!

    // Settings controls (read on Save).
    private let modelField = NSTextField()
    private let modelDirField = NSTextField()
    private let useANECheckbox = NSButton(checkboxWithTitle: "Use Neural Engine (CoreML)", target: nil, action: nil)
    private let portField = NSTextField()
    private let logLevelPopup = NSPopUpButton()
    private let doubleTapField = NSTextField()
    private let tapMaxField = NSTextField()
    private let holdReleaseField = NSTextField()
    private let hotkeyPopup = NSPopUpButton()
    private let soundsCheckbox = NSButton(checkboxWithTitle: "Sound feedback", target: nil, action: nil)
    private let pasteModePopup = NSPopUpButton()
    private let loginCheckbox = NSButton(checkboxWithTitle: "Start at login", target: nil, action: nil)
    private let promptTextView = NSTextView()
    private let settingsStatus = NSTextField(labelWithString: "")
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    /// Prompt text as last loaded/saved — baseline for dirty detection.
    private var baselinePrompt = ""

    var isVisible: Bool { panel.isVisible }

    /// Called after the user saves settings. Bool = an engine-affecting setting
    /// changed (needs the whisper-server restarted); light settings apply live.
    var onApply: ((Bool) -> Void)?

    /// Fired when this window gains/loses key, so the box can be dropped below
    /// it (key) or restored to floating (not key).
    var onKeyChange: ((Bool) -> Void)?

    override init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 580),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Speak"
        panel.isReleasedWhenClosed = false
        panel.level = .normal // not .floating — must not force itself above other apps' windows
        panel.hidesOnDeactivate = false // NSPanel defaults to true → vanishes when app loses focus

        super.init()
        panel.delegate = self

        tabView = NSTabView()
        tabView.translatesAutoresizingMaskIntoConstraints = false

        let statusItem = NSTabViewItem(identifier: "status")
        statusItem.label = "Status"
        statusItem.view = buildStatusTab()
        tabView.addTabViewItem(statusItem)

        let settingsItem = NSTabViewItem(identifier: "settings")
        settingsItem.label = "Settings"
        settingsItem.view = buildSettingsTab()
        tabView.addTabViewItem(settingsItem)

        let aboutItem = NSTabViewItem(identifier: "about")
        aboutItem.label = "About"
        aboutItem.view = buildAboutTab()
        tabView.addTabViewItem(aboutItem)

        let content = NSView()
        content.addSubview(tabView)
        panel.contentView = content
        NSLayoutConstraint.activate([
            tabView.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            tabView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            tabView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            tabView.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])
    }

    // MARK: - Status tab

    private func buildStatusTab() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false

        statusLine.font = .systemFont(ofSize: 13, weight: .semibold)
        stack.addArrangedSubview(statusLine)
        stack.setCustomSpacing(12, after: statusLine)

        for item in CheckItem.allCases {
            let label = NSTextField(labelWithString: "⚪️ \(item.title)")
            label.font = .monospacedSystemFont(ofSize: 12.5, weight: .regular)
            label.lineBreakMode = .byTruncatingTail
            rowLabels[item] = label

            // The two permission rows get a deep-link button to System Settings.
            if item == .accessibility || item == .micPermission {
                let button = NSButton(title: "Open Settings…", target: self,
                                      action: item == .accessibility ? #selector(openAccessibility) : #selector(openMicrophone))
                button.controlSize = .small
                button.isHidden = true
                permissionButtons[item] = button
                let row = NSStackView(views: [label, button])
                row.orientation = .horizontal
                row.spacing = 10
                stack.addArrangedSubview(row)
            } else {
                stack.addArrangedSubview(label)
            }
        }

        stack.setCustomSpacing(14, after: stack.arrangedSubviews.last!)

        let gestures = NSTextField(wrappingLabelWithString: """
        Gestures — the whole UI is the left shift key:
          • double-tap — start recording (🎙️ marks where text lands)
          • single tap while recording — stop & transcribe
          • double-tap and hold — push-to-talk (release stops)
          • single tap while editing — paste into the previous app
          • Esc — cancel recording, then close the box
          • ⌘Z / ⌘⇧Z — undo / redo a dictated chunk
        """)
        gestures.font = .systemFont(ofSize: 11.5)
        gestures.textColor = .secondaryLabelColor
        stack.addArrangedSubview(gestures)
        stack.setCustomSpacing(12, after: gestures)

        let info = NSTextField(wrappingLabelWithString: installInfo())
        info.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        info.textColor = .tertiaryLabelColor
        stack.addArrangedSubview(info)

        // Bottom controls (auto-close + close), revealed once checks resolve.
        let checkbox = NSButton(checkboxWithTitle: "Auto-close when ready",
                                target: self, action: #selector(toggleAutoClose(_:)))
        checkbox.state = UserDefaults.standard.bool(forKey: Self.autoCloseKey) ? .on : .off
        let closeButton = NSButton(title: "Close", target: self, action: #selector(closeClicked))
        closeButton.keyEquivalent = "\r"
        bottomRow = NSStackView(views: [checkbox, NSView(), closeButton])
        bottomRow.orientation = .horizontal
        bottomRow.distribution = .fill
        bottomRow.isHidden = true

        return wrapInTab(stack, bottom: bottomRow)
    }

    private func installInfo() -> String {
        let mode = Config.isInstalled ? "Installed app" : "Dev build"
        return """
        \(mode)
        app:    \(Bundle.main.bundlePath)
        model:  \(Config.canonicalModelStore)
        log:    \(Config.appLogPath)
        """
    }

    // MARK: - Settings tab

    private func buildSettingsTab() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        let cfg = Config.shared

        modelField.stringValue = cfg.model
        modelDirField.stringValue = cfg.modelDir
        modelDirField.placeholderString = "shared default (\(Config.canonicalModelStore))"
        useANECheckbox.state = cfg.useANE ? .on : .off
        portField.stringValue = String(cfg.serverPort)
        soundsCheckbox.state = cfg.sounds ? .on : .off
        doubleTapField.stringValue = String(cfg.doubleTapWindowMs)
        tapMaxField.stringValue = String(cfg.tapMaxMs)
        holdReleaseField.stringValue = String(cfg.holdReleaseMs)

        logLevelPopup.addItems(withTitles: ["error", "info", "debug"])
        logLevelPopup.selectItem(withTitle: cfg.logLevel)

        pasteModePopup.addItems(withTitles: ["paste", "copy"])
        pasteModePopup.selectItem(withTitle: cfg.pasteMode)

        hotkeyPopup.addItem(withTitle: "Left Shift")
        hotkeyPopup.lastItem?.tag = 56
        hotkeyPopup.addItem(withTitle: "Right Shift")
        hotkeyPopup.lastItem?.tag = 60
        hotkeyPopup.selectItem(withTag: cfg.hotkeyKeycode)

        for f in [modelField, modelDirField, portField, doubleTapField, tapMaxField, holdReleaseField] {
            f.translatesAutoresizingMaskIntoConstraints = false
            f.widthAnchor.constraint(equalToConstant: 240).isActive = true
            f.delegate = self // live edits → dirty check
        }
        // Dirty-tracking on the non-text controls (login is applied instantly, not saved).
        for popup in [logLevelPopup, pasteModePopup, hotkeyPopup] {
            popup.target = self; popup.action = #selector(settingChanged)
        }
        for box in [useANECheckbox, soundsCheckbox] {
            box.target = self; box.action = #selector(settingChanged)
        }

        stack.addArrangedSubview(formRow("Model", modelField))
        stack.addArrangedSubview(formRow("Model dir", modelDirField))
        stack.addArrangedSubview(useANECheckbox)
        stack.addArrangedSubview(formRow("Server port", portField))
        stack.addArrangedSubview(formRow("Log level", logLevelPopup))
        stack.addArrangedSubview(formRow("Double-tap window (ms)", doubleTapField))
        stack.addArrangedSubview(formRow("Tap max (ms)", tapMaxField))
        stack.addArrangedSubview(formRow("Hold-release (ms)", holdReleaseField))
        stack.addArrangedSubview(formRow("Hotkey", hotkeyPopup))
        stack.addArrangedSubview(formRow("Paste mode", pasteModePopup))
        stack.addArrangedSubview(soundsCheckbox)

        // Start at login — only meaningful for an installed app (registering the
        // dev build's path would point the login item at the clone).
        configureLoginCheckbox()
        stack.addArrangedSubview(loginCheckbox)

        let promptLabel = NSTextField(labelWithString: "Vocabulary prompt (biases transcription):")
        promptLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
        stack.addArrangedSubview(promptLabel)

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        baselinePrompt = (try? String(contentsOfFile: Config.promptFilePath, encoding: .utf8)) ?? ""
        promptTextView.string = baselinePrompt
        promptTextView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        promptTextView.isRichText = false
        promptTextView.autoresizingMask = [.width]
        promptTextView.delegate = self // live edits → dirty check
        scroll.documentView = promptTextView
        stack.addArrangedSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.heightAnchor.constraint(equalToConstant: 90),
            scroll.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
        ])

        settingsStatus.font = .systemFont(ofSize: 11)
        settingsStatus.textColor = .secondaryLabelColor
        saveButton.target = self
        saveButton.action = #selector(saveSettings)
        saveButton.keyEquivalent = "s"
        saveButton.keyEquivalentModifierMask = [.command]
        saveButton.isHidden = true // appears only once a setting actually changes
        let saveRow = NSStackView(views: [settingsStatus, NSView(), saveButton])
        saveRow.orientation = .horizontal

        return wrapInTab(stack, bottom: saveRow)
    }

    private func configureLoginCheckbox() {
        if #available(macOS 13.0, *), Config.isInstalled {
            loginCheckbox.isEnabled = true
            loginCheckbox.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
            loginCheckbox.target = self
            loginCheckbox.action = #selector(toggleLogin(_:))
            loginCheckbox.toolTip = nil
        } else {
            loginCheckbox.isEnabled = false
            loginCheckbox.state = .off
            loginCheckbox.toolTip = "Available once Speak is installed to /Applications."
        }
    }

    // MARK: - About tab

    private func buildAboutTab() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "Speak")
        title.font = .systemFont(ofSize: 22, weight: .bold)
        stack.addArrangedSubview(title)

        let tagline = NSTextField(labelWithString: "Local, private speech-to-text for macOS.")
        tagline.font = .systemFont(ofSize: 12)
        tagline.textColor = .secondaryLabelColor
        stack.addArrangedSubview(tagline)
        stack.setCustomSpacing(14, after: tagline)

        let commit = Bundle.main.object(forInfoDictionaryKey: "SpeakGitCommit") as? String ?? "unknown"
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let version = NSTextField(labelWithString: "Version \(short)   build \(commit)")
        version.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        version.textColor = .secondaryLabelColor
        stack.addArrangedSubview(version)
        stack.setCustomSpacing(16, after: version)

        let credits = NSTextField(wrappingLabelWithString:
            "Built on whisper.cpp (MIT) and OpenAI's Whisper models, with the encoder "
            + "running on the Apple Neural Engine. Viridis colormap from matplotlib (CC0).")
        credits.font = .systemFont(ofSize: 11.5)
        credits.textColor = .secondaryLabelColor
        stack.addArrangedSubview(credits)
        stack.setCustomSpacing(16, after: credits)

        let github = NSButton(title: "View on GitHub", target: self, action: #selector(openRepo))
        stack.addArrangedSubview(github)

        return wrapInTab(stack, bottom: NSView())
    }

    @objc private func openRepo() {
        NSWorkspace.shared.open(UpdateChecker.repoURL)
    }

    // MARK: - Layout helpers

    private func formRow(_ labelText: String, _ control: NSView) -> NSView {
        let label = NSTextField(labelWithString: labelText)
        label.alignment = .left
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: 170).isActive = true
        let row = NSStackView(views: [label, control])
        row.orientation = .horizontal
        row.spacing = 10
        row.alignment = .firstBaseline
        return row
    }

    /// Pin a content stack to the top of a tab view and a bottom row to the
    /// bottom, so the tab fills predictably.
    private func wrapInTab(_ stack: NSView, bottom: NSView) -> NSView {
        let view = NSView()
        bottom.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        view.addSubview(bottom)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18),
            bottom.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
            bottom.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18),
            bottom.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -14),
        ])
        return view
    }

    // MARK: - Public API (used by AppDelegate / ReadinessChecker)

    /// `activate: false` shows the window WITHOUT pulling our app in front — used
    /// at launch so the system's Accessibility-permission dialog (which it
    /// presents frontmost) isn't buried behind our window. Manual shows (tray
    /// click) activate normally.
    func show(activate: Bool = true) {
        panel.center()
        if activate {
            panel.makeKeyAndOrderFront(nil)
            // orderFrontRegardless brings the window above OTHER apps' windows
            // even when we're a background accessory app (LSUIElement) that
            // can't reliably steal activation — e.g. right after a system
            // permission dialog hands focus back to the launching Terminal.
            panel.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
        } else {
            panel.orderFront(nil)
        }
    }

    func toggle() {
        if panel.isVisible { panel.orderOut(nil) } else { show() }
    }

    /// Open the window with a specific tab selected (menu deep-links).
    func show(tab: String) {
        tabView.selectTabViewItem(withIdentifier: tab)
        show()
    }

    // MARK: - NSWindowDelegate (drive the box's z-order)

    func windowDidBecomeKey(_ notification: Notification) { onKeyChange?(true) }
    func windowDidResignKey(_ notification: Notification) { onKeyChange?(false) }

    func update(_ item: CheckItem, state: CheckState) {
        guard let label = rowLabels[item] else { return }
        let detail = state.detail.isEmpty ? "" : " — \(state.detail)"
        label.stringValue = "\(state.emoji) \(item.title)\(detail)"
        label.textColor = state.isFailed ? .systemRed : .labelColor
        permissionButtons[item]?.isHidden = !state.isFailed
    }

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

    // MARK: - Actions

    @objc private func toggleAutoClose(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: Self.autoCloseKey)
    }

    @objc private func closeClicked() {
        panel.orderOut(nil)
    }

    @objc private func openAccessibility() {
        // The first-launch auto-prompt (AppDelegate.autoPromptAccessibilityIfNeeded)
        // already registered the app and consumed the one-shot
        // AXIsProcessTrustedWithOptions dialog, so this fallback just navigates
        // straight to the Accessibility pane (where the app is now listed).
        openPrivacy("Privacy_Accessibility")
    }

    @objc private func openMicrophone() {
        openPrivacy("Privacy_Microphone")
    }

    private func openPrivacy(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func toggleLogin(_ sender: NSButton) {
        guard #available(macOS 13.0, *) else { return }
        do {
            if sender.state == .on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            Log.info("[Settings] login item \(sender.state == .on ? "registered" : "unregistered")")
        } catch {
            Log.error("[Settings] login item toggle failed: \(error)")
            sender.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        }
    }

    /// The single UI → config.yaml mapping, used for BOTH dirty-detection and
    /// saving (no duplicated field lists).
    private func configValues() -> [String: String] {
        func t(_ f: NSTextField) -> String { f.stringValue.trimmingCharacters(in: .whitespaces) }
        return [
            "model": t(modelField),
            "model_dir": t(modelDirField),
            "use_ane": useANECheckbox.state == .on ? "true" : "false",
            "server_port": t(portField),
            "log_level": logLevelPopup.titleOfSelectedItem ?? "info",
            "double_tap_window_ms": t(doubleTapField),
            "tap_max_ms": t(tapMaxField),
            "hold_release_ms": t(holdReleaseField),
            "hotkey_keycode": String(hotkeyPopup.selectedItem?.tag ?? 56),
            "sounds": soundsCheckbox.state == .on ? "true" : "false",
            "paste_mode": pasteModePopup.titleOfSelectedItem ?? "paste",
        ]
    }

    @objc private func saveSettings() {
        let old = Config.shared // pre-reload, to decide what needs an engine restart
        let oldPrompt = baselinePrompt
        let newPrompt = promptTextView.string
        let values = configValues()

        Config.write(values)
        if newPrompt != oldPrompt {
            do { try newPrompt.write(toFile: Config.promptFilePath, atomically: true, encoding: .utf8) }
            catch { Log.error("[Settings] failed to write prompt.txt: \(error)") }
        }

        // Only an engine-affecting change needs the whisper-server relaunched.
        let engineChanged = values["model"] != old.model
            || values["model_dir"] != old.modelDir
            || (values["use_ane"] == "true") != old.useANE
            || values["server_port"] != String(old.serverPort)
            || newPrompt != oldPrompt

        onApply?(engineChanged) // reloads Config.shared (light settings live now)
        baselinePrompt = newPrompt
        updateSaveVisibility() // controls now match saved config → hides again
        Log.info("[Settings] applied (engineChanged=\(engineChanged))")
        panel.orderOut(nil) // close the window on save
    }

    // MARK: - Dirty tracking (Save shows only when something changed)

    /// Clean one-liner: would saving change the file (config.yaml or prompt.txt)?
    private func isDirty() -> Bool {
        Config.wouldChange(configValues()) || promptTextView.string != baselinePrompt
    }

    private func updateSaveVisibility() { saveButton.isHidden = !isDirty() }

    @objc private func settingChanged() { updateSaveVisibility() }
    func controlTextDidChange(_ obj: Notification) { updateSaveVisibility() }
    func textDidChange(_ notification: Notification) { updateSaveVisibility() }
}

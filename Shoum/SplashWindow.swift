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

    // Settings controls (read on apply).
    private let modelPopup = NSPopUpButton()   // installed models only — a model can't be mistyped
    private let modelDirField = NSTextField()
    private let useANECheckbox = NSButton(checkboxWithTitle: "Use Neural Engine (CoreML)", target: nil, action: nil)
    private let portField = NSTextField()
    private let serverArgsField = NSTextField()
    private let logLevelPopup = NSPopUpButton()
    private let doubleTapField = NSTextField()
    private let tapMaxField = NSTextField()
    private let holdReleaseField = NSTextField()
    private let minSpeechField = NSTextField()
    private let hotkeyPopup = NSPopUpButton()
    private let soundsCheckbox = NSButton(checkboxWithTitle: "Sound feedback", target: nil, action: nil)
    private let pruneCheckbox = NSButton(checkboxWithTitle: "Prune dead audio (VAD removes silence before transcribing)", target: nil, action: nil)
    private let pasteModePopup = NSPopUpButton()
    private let typeIntoTerminalsCheckbox = NSButton(checkboxWithTitle: "Type directly into terminals (Claude-Code friendly)", target: nil, action: nil)
    private let restoreClipboardCheckbox = NSButton(checkboxWithTitle: "Restore clipboard after pasting", target: nil, action: nil)
    private let voiceCommandsCheckbox = NSButton(checkboxWithTitle: "Voice commands (speak symbols & markdown — see lexicon.md)", target: nil, action: nil)
    private let showWhisperCheckbox = NSButton(checkboxWithTitle: "Show last whisper response (debug — green pane in the box)", target: nil, action: nil)
    private let keepRecordingsCheckbox = NSButton(checkboxWithTitle: "Keep recordings 24h (/tmp/shoum/wavs — debugging)", target: nil, action: nil)
    private let checkUpdatesCheckbox = NSButton(checkboxWithTitle: "Check for updates (daily, notify-only)", target: nil, action: nil)
    private let loginCheckbox = NSButton(checkboxWithTitle: "Start at login", target: nil, action: nil)
    private let promptTextView = NSTextView()
    private let settingsStatus = NSTextField(labelWithString: "")
    /// Prompt text as last loaded/applied — baseline for change detection.
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
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Shoum"
        panel.isReleasedWhenClosed = false
        panel.level = .normal // not .floating — must not force itself above other apps' windows
        panel.hidesOnDeactivate = false // NSPanel defaults to true → vanishes when app loses focus
        panel.minSize = NSSize(width: 520, height: 420) // tabs scroll below this

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

        let commandsItem = NSTabViewItem(identifier: "commands")
        commandsItem.label = "Commands"
        commandsItem.view = buildCommandsTab()
        tabView.addTabViewItem(commandsItem)

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
          • Esc — cancel recording/transcribing, then close the box
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

        populateModelPopup()
        modelDirField.stringValue = cfg.modelDir
        modelDirField.placeholderString = "shared default (\(Config.canonicalModelStore))"
        useANECheckbox.state = cfg.useANE ? .on : .off
        portField.stringValue = String(cfg.serverPort)
        serverArgsField.stringValue = cfg.serverArgs
        serverArgsField.placeholderString = "extra whisper-server flags, e.g. -t 6"
        soundsCheckbox.state = cfg.sounds ? .on : .off
        pruneCheckbox.state = cfg.pruneDeadAudio ? .on : .off
        typeIntoTerminalsCheckbox.state = cfg.typeIntoTerminals ? .on : .off
        restoreClipboardCheckbox.state = cfg.restoreClipboard ? .on : .off
        voiceCommandsCheckbox.state = cfg.voiceCommands ? .on : .off
        showWhisperCheckbox.state = cfg.showWhisperResponse ? .on : .off
        keepRecordingsCheckbox.state = cfg.keepRecordings ? .on : .off
        checkUpdatesCheckbox.state = cfg.checkForUpdates ? .on : .off
        doubleTapField.stringValue = String(cfg.doubleTapWindowMs)
        tapMaxField.stringValue = String(cfg.tapMaxMs)
        holdReleaseField.stringValue = String(cfg.holdReleaseMs)
        minSpeechField.stringValue = String(cfg.minSpeechDBFS)

        logLevelPopup.addItems(withTitles: ["error", "info", "debug"])
        logLevelPopup.selectItem(withTitle: cfg.logLevel)

        pasteModePopup.addItems(withTitles: ["paste", "copy"])
        pasteModePopup.selectItem(withTitle: cfg.pasteMode)

        hotkeyPopup.addItem(withTitle: "Left Shift")
        hotkeyPopup.lastItem?.tag = 56
        hotkeyPopup.addItem(withTitle: "Right Shift")
        hotkeyPopup.lastItem?.tag = 60
        hotkeyPopup.selectItem(withTag: cfg.hotkeyKeycode)

        for f in [modelDirField, portField, serverArgsField, doubleTapField,
                  tapMaxField, holdReleaseField, minSpeechField] {
            f.translatesAutoresizingMaskIntoConstraints = false
            f.widthAnchor.constraint(equalToConstant: 240).isActive = true
            f.delegate = self // commit (Enter/blur) → applySettings
        }
        // Dirty-tracking on the non-text controls (login is applied instantly, not saved).
        for popup in [modelPopup, logLevelPopup, pasteModePopup, hotkeyPopup] {
            popup.target = self; popup.action = #selector(settingChanged)
        }
        for box in [useANECheckbox, soundsCheckbox, pruneCheckbox,
                    typeIntoTerminalsCheckbox, restoreClipboardCheckbox, voiceCommandsCheckbox,
                    showWhisperCheckbox, keepRecordingsCheckbox, checkUpdatesCheckbox] {
            box.target = self; box.action = #selector(settingChanged)
        }

        stack.addArrangedSubview(formRow("Model", modelPopup))
        stack.addArrangedSubview(formRow("Model dir", modelDirField))
        stack.addArrangedSubview(useANECheckbox)
        stack.addArrangedSubview(formRow("Server port", portField))
        stack.addArrangedSubview(formRow("Extra server args", serverArgsField))
        stack.addArrangedSubview(formRow("Log level", logLevelPopup))
        stack.addArrangedSubview(formRow("Double-tap window (ms)", doubleTapField))
        stack.addArrangedSubview(formRow("Tap max (ms)", tapMaxField))
        stack.addArrangedSubview(formRow("Hold-release (ms)", holdReleaseField))
        stack.addArrangedSubview(formRow("No-speech floor (dBFS)", minSpeechField))
        stack.addArrangedSubview(formRow("Hotkey", hotkeyPopup))
        stack.addArrangedSubview(formRow("Paste mode", pasteModePopup))
        stack.addArrangedSubview(typeIntoTerminalsCheckbox)
        stack.addArrangedSubview(restoreClipboardCheckbox)
        stack.addArrangedSubview(voiceCommandsCheckbox)
        stack.addArrangedSubview(showWhisperCheckbox)
        stack.addArrangedSubview(soundsCheckbox)
        stack.addArrangedSubview(pruneCheckbox)
        stack.addArrangedSubview(keepRecordingsCheckbox)
        stack.addArrangedSubview(checkUpdatesCheckbox)

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
        promptTextView.delegate = self // commit (Enter/blur) → applySettings
        scroll.documentView = promptTextView
        stack.addArrangedSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.heightAnchor.constraint(equalToConstant: 90),
            scroll.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
        ])

        // No Save button — settings apply instantly (toggles on change, text
        // fields/prompt on commit). A quiet hint says so.
        settingsStatus.font = .systemFont(ofSize: 11)
        settingsStatus.textColor = .tertiaryLabelColor
        settingsStatus.stringValue = "Settings apply as you change them."
        let hintRow = NSStackView(views: [settingsStatus, NSView()])
        hintRow.orientation = .horizontal

        return wrapInTab(stack, bottom: hintRow)
    }

    /// Fill the model dropdown with the models actually present on disk
    /// (Config.availableModels) — selection instead of free text, so a typo'd
    /// model can't silently kill the engine. The configured model stays
    /// selectable even if its file has gone missing (marked so).
    private func populateModelPopup() {
        let current = Config.shared.model
        let installed = Config.availableModels
        var names = installed
        if !names.contains(current) { names.append(current) }

        modelPopup.removeAllItems()
        for name in names.sorted() {
            let missing = !installed.contains(name)
            modelPopup.addItem(withTitle: missing ? "\(name) (missing)" : name)
            modelPopup.lastItem?.representedObject = name
        }
        if let idx = modelPopup.itemArray.firstIndex(where: { ($0.representedObject as? String) == current }) {
            modelPopup.selectItem(at: idx)
        }
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
            loginCheckbox.toolTip = "Available once Shoum is installed to /Applications."
        }
    }

    // MARK: - About tab

    private func buildAboutTab() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "Shoum")
        title.font = .systemFont(ofSize: 22, weight: .bold)
        stack.addArrangedSubview(title)

        let tagline = NSTextField(labelWithString: "Local, private speech-to-text for macOS.")
        tagline.font = .systemFont(ofSize: 12)
        tagline.textColor = .secondaryLabelColor
        stack.addArrangedSubview(tagline)
        stack.setCustomSpacing(14, after: tagline)

        let commit = Bundle.main.object(forInfoDictionaryKey: "ShoumGitCommit") as? String ?? "unknown"
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

    /// Pin a scrollable content stack to the top of a tab and a bottom row to the
    /// bottom. The stack scrolls vertically when it's taller than the window (the
    /// Settings tab outgrew a fixed window), so it stays usable at any size.
    private func wrapInTab(_ stack: NSView, bottom: NSView) -> NSView {
        let view = NSView()
        bottom.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.documentView = stack

        view.addSubview(scroll)
        view.addSubview(bottom)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18),
            scroll.bottomAnchor.constraint(equalTo: bottom.topAnchor, constant: -8),

            bottom.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
            bottom.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18),
            bottom.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -14),

            // Stack fills the scroll horizontally and defines its own height (no
            // bottom pin → intrinsic height → it scrolls vertically when tall).
            stack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            stack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        return view
    }

    // MARK: - Commands tab (read-only reference, sourced from CommandProcessor)

    private func buildCommandsTab() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 9
        stack.translatesAutoresizingMaskIntoConstraints = false

        let intro = NSTextField(wrappingLabelWithString:
            "Speak these to insert symbols and formatting. Prefix a symbol with "
            + "\u{201C}ascii\u{201D} (\u{201C}ascii slash\u{201D} \u{2192} /), or say "
            + "\u{201C}mode ascii\u{201D} to drop the prefix until \u{201C}mode normal\u{201D}. "
            + "Turn the feature on/off with Voice Commands in Settings.")
        intro.font = .systemFont(ofSize: 11.5)
        intro.textColor = .secondaryLabelColor
        intro.preferredMaxLayoutWidth = 520
        stack.addArrangedSubview(intro)

        func header(_ t: String) -> NSTextField {
            let l = NSTextField(labelWithString: t)
            l.font = .systemFont(ofSize: 12, weight: .semibold)
            return l
        }
        func symCell(_ s: String) -> NSTextField {
            let l = NSTextField(labelWithString: s)
            l.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
            return l
        }
        func nameCell(_ s: String) -> NSTextField {
            let l = NSTextField(labelWithString: s)
            l.font = .systemFont(ofSize: 11.5)
            l.textColor = .secondaryLabelColor
            return l
        }
        // A symbol|name 2-column grid for one slice of entries.
        func subGrid(_ entries: [(String, String)]) -> NSGridView {
            let cells: [[NSView]] = entries.isEmpty ? [[NSView(), NSView()]]
                : entries.map { [symCell($0.0), nameCell($0.1)] }
            let g = NSGridView(views: cells)
            g.rowSpacing = 3
            g.columnSpacing = 8
            g.column(at: 0).xPlacement = .leading
            g.column(at: 1).xPlacement = .leading
            return g
        }
        // `cols` EQUAL-width columns (each 1/3 of the width), filled COLUMN-MAJOR
        // (all of column 1 down, then column 2, …) so the lexicon's grouping stays
        // vertically adjacent.
        func columns(_ entries: [(String, String)], _ cols: Int) -> NSStackView {
            let n = entries.count
            let per = max(1, (n + cols - 1) / cols)
            let subs: [NSView] = (0..<cols).map { c in
                subGrid(Array(entries[min(c * per, n)..<min(c * per + per, n)]))
            }
            let h = NSStackView(views: subs)
            h.orientation = .horizontal
            h.distribution = .fillEqually
            h.alignment = .top
            h.spacing = 12
            return h
        }

        stack.addArrangedSubview(header("Symbols \u{2014} say \u{201C}ascii <name>\u{201D}"))
        let symCols = columns(CommandProcessor.symbols.map { ($0.0, $0.1.first ?? "") }, 3)
        stack.addArrangedSubview(symCols)
        symCols.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        stack.addArrangedSubview(header("Bare words \u{2014} no prefix needed"))
        let bareDisplay: [(String, String)] = CommandProcessor.bareWords.map { (out, names) in
            let label = out == "\n\n" ? "blank line" : out == "\n" ? "line break" : out
            return (label, names.joined(separator: ", "))
        }
        stack.addArrangedSubview(subGrid(bareDisplay))

        stack.addArrangedSubview(header("Modes & casing"))
        for line in [
            "mode ascii \u{2026} mode normal \u{2014} symbols without the \u{201C}ascii\u{201D} prefix",
            "mode all caps \u{2026} mode normal \u{2014} UPPERCASE the span",
            "cap <word> \u{2014} capitalise the next word",
        ] {
            let l = NSTextField(wrappingLabelWithString: "\u{2022}  " + line)
            l.font = .systemFont(ofSize: 11.5)
            l.preferredMaxLayoutWidth = 520
            stack.addArrangedSubview(l)
        }

        let note = NSTextField(wrappingLabelWithString:
            "Many symbols accept synonyms (e.g. \u{201C}star\u{201D} = \u{201C}asterisk\u{201D}); "
            + "the full list and rules are in lexicon.md.")
        note.font = .systemFont(ofSize: 10.5)
        note.textColor = .tertiaryLabelColor
        note.preferredMaxLayoutWidth = 520
        stack.setCustomSpacing(14, after: stack.arrangedSubviews.last!)
        stack.addArrangedSubview(note)

        let close = NSButton(title: "Close", target: self, action: #selector(closeClicked))
        let bottom = NSStackView(views: [NSView(), close])
        bottom.orientation = .horizontal
        return wrapInTab(stack, bottom: bottom)
    }

    // MARK: - Public API (used by AppDelegate / ReadinessChecker)

    /// `activate: false` shows the window WITHOUT pulling our app in front — used
    /// at launch so the system's Accessibility-permission dialog (which it
    /// presents frontmost) isn't buried behind our window. Manual shows (tray
    /// click) activate normally.
    func show(activate: Bool = true) {
        // Center only on first appearance — re-centering an already-visible (or
        // user-positioned) window discards where they put it.
        if !panel.isVisible { panel.center() }
        populateModelPopup() // models staged since launch appear without a relaunch
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
        label.textColor = state.isFailed ? .systemRed : (state.isWarning ? .systemYellow : .labelColor)
        // Show the "Open Settings…" action for actionable rows — failures AND
        // warnings (e.g. a permission still to grant).
        permissionButtons[item]?.isHidden = !(state.isFailed || state.isWarning)
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

    /// No hard failures, but something needs the user (a permission grant, a
    /// missing VAD model, …).
    func markWarning() {
        statusLine.stringValue = "Action needed — see the ⚠️ items below"
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
            "model": (modelPopup.selectedItem?.representedObject as? String) ?? Config.shared.model,
            "model_dir": t(modelDirField),
            "use_ane": useANECheckbox.state == .on ? "true" : "false",
            "server_port": t(portField),
            "server_args": t(serverArgsField),
            "log_level": logLevelPopup.titleOfSelectedItem ?? "info",
            "double_tap_window_ms": t(doubleTapField),
            "tap_max_ms": t(tapMaxField),
            "hold_release_ms": t(holdReleaseField),
            "min_speech_dbfs": t(minSpeechField),
            "hotkey_keycode": String(hotkeyPopup.selectedItem?.tag ?? 56),
            "sounds": soundsCheckbox.state == .on ? "true" : "false",
            "prune_dead_audio": pruneCheckbox.state == .on ? "true" : "false",
            "paste_mode": pasteModePopup.titleOfSelectedItem ?? "paste",
            "type_into_terminals": typeIntoTerminalsCheckbox.state == .on ? "true" : "false",
            "restore_clipboard": restoreClipboardCheckbox.state == .on ? "true" : "false",
            "voice_commands": voiceCommandsCheckbox.state == .on ? "true" : "false",
            "show_whisper_response": showWhisperCheckbox.state == .on ? "true" : "false",
            "keep_recordings": keepRecordingsCheckbox.state == .on ? "true" : "false",
            "check_for_updates": checkUpdatesCheckbox.state == .on ? "true" : "false",
        ]
    }

    // MARK: - Instant apply (no Save button)

    /// Write the current control values + prompt to disk and apply them live.
    /// Toggles/popups call this on change; text fields and the prompt call it on
    /// commit (Enter / focus-loss). A no-op when nothing actually changed, so
    /// repeated calls — and the whisper-server restart an engine setting triggers
    /// — only happen on a real change.
    private func applySettings() {
        let old = Config.shared // pre-reload, to decide what needs an engine restart
        let newPrompt = promptTextView.string
        let promptChanged = newPrompt != baselinePrompt
        let values = configValues()
        guard Config.wouldChange(values) || promptChanged else { return }

        Config.write(values)
        if promptChanged {
            do { try newPrompt.write(toFile: Config.promptFilePath, atomically: true, encoding: .utf8) }
            catch { Log.error("[Settings] failed to write prompt.txt: \(error)") }
        }

        // Only an engine-affecting change needs the whisper-server relaunched —
        // which keys those are is the registry's knowledge, not this pane's.
        let engineChanged = Config.engineAffecting(values, comparedTo: old) || promptChanged

        onApply?(engineChanged) // reloads Config.shared (light settings live now)
        baselinePrompt = newPrompt
        Log.info("[Settings] applied (engineChanged=\(engineChanged))")
    }

    // Toggles/popups apply immediately; text fields and the prompt apply on
    // commit (Enter / focus-loss), never per keystroke — so we don't act on a
    // half-typed value or restart the server mid-edit.
    @objc private func settingChanged() { applySettings() }
    func controlTextDidEndEditing(_ obj: Notification) { applySettings() }
    func textDidEndEditing(_ notification: Notification) { applySettings() }
}

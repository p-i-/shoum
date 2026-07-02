import AppKit

/// "Report an issue" flow: build a TEXT-ONLY diagnostics report, show the user
/// exactly what it contains, then open a prefilled GitHub issue in the browser.
///
/// Privacy contract:
///   • Audio is never included, ever.
///   • The vocabulary prompt (prompt.txt) is never included.
///   • Logs are OPT-IN and previewed verbatim — the app log contains excerpts
///     of dictated text, and the checkbox says so.
/// Nothing leaves the machine except the previewed text, and only via the
/// user's own browser submitting the issue.
final class IssueReporter: NSObject {
    private static let newIssueBase = "https://github.com/p-i-/shoum/issues/new"
    /// GitHub rejects very long URLs (~8 KB); past this the logs travel via the
    /// clipboard instead of the URL.
    private static let maxURLLength = 7500

    private let summary: String
    private let logsSection: String
    private let textView = NSTextView()
    private let logsCheckbox = NSButton(
        checkboxWithTitle: "Include recent logs — they contain excerpts of what you dictated",
        target: nil, action: nil)

    init(readiness: ReadinessChecker?) {
        summary = Self.buildSummary(readiness: readiness)
        logsSection = Self.buildLogsSection()
        super.init()
    }

    func run() {
        let alert = NSAlert()
        alert.messageText = "Report an issue"
        alert.informativeText = "The text below is prefilled into a GitHub issue in your browser — nothing else is sent. Logs are optional (shown verbatim before anything leaves this Mac); audio and your vocabulary prompt are never included."
        alert.addButton(withTitle: "Open GitHub Issue")
        alert.addButton(withTitle: "Cancel")

        logsCheckbox.state = .off // logs are opt-IN
        logsCheckbox.target = self
        logsCheckbox.action = #selector(refreshPreview)

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 520, height: 240))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        textView.frame = scroll.bounds
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: 4, height: 4)
        scroll.documentView = textView

        let stack = NSStackView(views: [logsCheckbox, scroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 520, height: 272)
        alert.accessoryView = stack
        refreshPreview()

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        openIssue(body: currentBody())
    }

    private func currentBody() -> String {
        logsCheckbox.state == .on ? summary + "\n" + logsSection : summary
    }

    @objc private func refreshPreview() {
        textView.string = currentBody()
    }

    private func openIssue(body: String) {
        let title = "Issue report — \(Self.appVersion())"
        func url(_ body: String) -> URL? {
            var comps = URLComponents(string: Self.newIssueBase)
            comps?.queryItems = [URLQueryItem(name: "title", value: title),
                                 URLQueryItem(name: "body", value: body)]
            return comps?.url
        }

        var candidate = url(body)
        if let u = candidate, u.absoluteString.count > Self.maxURLLength {
            // Too long for a URL: put the FULL previewed report on the
            // clipboard and keep the URL body to the summary.
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(body, forType: .string)
            candidate = url(summary
                + "\n_(The full report incl. logs exceeded the URL limit — it's on the reporter's clipboard; please paste it here.)_")
            Log.info("[IssueReporter] report exceeded URL limit — full text placed on the clipboard")
        }
        if let u = candidate { NSWorkspace.shared.open(u) }
    }

    // MARK: - Content

    private static func appVersion() -> String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let commit = info?["ShoumGitCommit"] as? String ?? "?"
        return "v\(short) (\(commit))"
    }

    private static func buildSummary(readiness: ReadinessChecker?) -> String {
        let cfg = Config.shared
        var s = "### What happened\n\n_(describe the issue here)_\n\n"
        s += "### Environment\n\n"
        s += "- Shoum: \(appVersion()), \(Config.isInstalled ? "installed" : "dev build")\n"
        s += "- macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)\n"
        s += "- model: \(cfg.model), use_ane: \(cfg.useANE), prune_dead_audio: \(cfg.pruneDeadAudio), "
        s += "paste_mode: \(cfg.pasteMode), type_into_terminals: \(cfg.typeIntoTerminals), voice_commands: \(cfg.voiceCommands)\n"
        if let r = readiness {
            s += "\n### Status checklist\n\n"
            for item in CheckItem.allCases {
                let state = r.states[item] ?? .pending
                s += "- \(state.emoji) \(item.title)\(state.detail.isEmpty ? "" : " — \(state.detail)")\n"
            }
        }
        return s
    }

    private static func buildLogsSection() -> String {
        var s = "### Logs (user-approved)\n\n"
        s += "app log (last 40 lines):\n```\n\(tail(Config.appLogPath, lines: 40))\n```\n\n"
        s += "server.log (last 20 lines):\n```\n\(tail(Config.serverLogPath, lines: 20))\n```\n"
        return s
    }

    private static func tail(_ path: String, lines n: Int) -> String {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return "(unavailable)" }
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .suffix(n).joined(separator: "\n")
    }
}

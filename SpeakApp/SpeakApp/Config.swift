import Foundation

/// Loads config.yaml and resolves every on-disk location the app needs.
///
/// Two run modes, detected by the install location itself — no env var:
///   • **installed** — a self-contained `.app` in /Applications, with the
///     whisper-server binary, model, encoder and sample wav staged inside
///     `Contents/Resources`. User-editable files (config.yaml, prompt.txt) and
///     logs (server.log) live in `~/Library/Application Support/Speak` because
///     the bundle's Resources are read-only (writing there breaks the
///     signature).
///   • **dev** — running from the git clone via run.sh. Both roots collapse to
///     the clone, so behavior is identical to before this refactor.
///
/// config.yaml format is a flat subset of YAML: `key: value  # comment` lines,
/// blank lines, and full-line comments. No nesting, no lists — server_args is a
/// whitespace-split string.
struct Config {
    // Server
    var model = "medium.en"
    var modelDir = "" // empty → shared store (see canonicalModelStore)
    var useANE = true
    var serverPort = 8178
    var serverArgs = ""
    var logLevel = "info" // error | info | debug

    // Gesture (milliseconds)
    var doubleTapWindowMs = 350
    var tapMaxMs = 250
    var holdReleaseMs = 400
    var hotkeyKeycode = 56 // left shift

    // Behavior
    var sounds = true
    var pasteMode = "paste" // "paste" = activate previous app + Cmd+V; "copy" = clipboard only
    var keepRecordings = true // retain WAVs in /tmp/speak for 24h (debugging)
    var minSpeechDBFS = -60.0 // clips quieter than this are no-speech; skip whisper
    var checkForUpdates = true // query GitHub on launch to notify of a newer build

    /// Single source of truth. `private(set) var` so the Settings pane can
    /// reload it live; in-process consumers read this (or derive from it) rather
    /// than caching copies, so a reload propagates for free.
    static private(set) var shared = Config.load()

    /// Re-read config.yaml after the Settings pane writes it. Light settings
    /// apply instantly because consumers read Config.shared directly; only the
    /// external whisper-server process needs an explicit restart.
    static func reload() { shared = load() }

    // MARK: - Run mode

    /// Installed iff the staged whisper-server binary sits inside the bundle's
    /// Resources. The presence of that file is the whole signal.
    static let isInstalled: Bool = {
        guard let res = Bundle.main.resourceURL else { return false }
        return FileManager.default.fileExists(
            atPath: res.appendingPathComponent("whisper-server").path)
    }()

    /// The dev checkout root: walk up from the bundle to the dir containing
    /// `whisper.cpp/`. Falls back to ~/code/speak. Only meaningful in dev mode.
    private static let cloneRoot: String = {
        var dir = Bundle.main.bundlePath as NSString
        for _ in 0..<8 {
            dir = dir.deletingLastPathComponent as NSString
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("whisper.cpp")) {
                return dir as String
            }
        }
        return NSString(string: "~/code/speak").expandingTildeInPath
    }()

    /// Read-only assets (server binary, model, encoder, sample wav).
    /// Installed → the bundle's Resources; dev → the clone.
    static let resourceRoot: String = {
        if isInstalled, let res = Bundle.main.resourceURL { return res.path }
        return cloneRoot
    }()

    /// Writable user data + logs (config.yaml, prompt.txt, server.log).
    /// Installed → ~/Library/Application Support/Speak (created on demand);
    /// dev → the clone.
    static let dataRoot: String = {
        if isInstalled {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let dir = base.appendingPathComponent("Speak", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir.path
        }
        return cloneRoot
    }()

    private static func resourcePath(_ relative: String) -> String {
        (resourceRoot as NSString).appendingPathComponent(relative)
    }

    private static func dataPath(_ relative: String) -> String {
        (dataRoot as NSString).appendingPathComponent(relative)
    }

    // MARK: - Asset locations (resourceRoot)

    /// Single shared location for the heavy model assets (the ggml `.bin` and
    /// its ANE `-encoder.mlmodelc`), referenced by BOTH dev and installed runs
    /// so the ~2 GB is never duplicated. Application Support — NOT Caches, which
    /// the OS (and disk-cleanups) purge.
    static let canonicalModelStore: String = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Speak/models", isDirectory: true).path
    }()

    /// Directory holding the model `.bin` and its sibling `-encoder.mlmodelc`
    /// (the CoreML encoder MUST stay a sibling of the `.bin` — whisper.cpp
    /// resolves it relative to the model file). Resolution order:
    ///   1. `model_dir` override in config.yaml (e.g. an external drive)
    ///   2. the shared store, if it actually holds this model
    ///   3. dev fallback: the clone's own whisper.cpp/models (pre-install)
    ///   4. installed with nothing found → the store, so errors name it
    private static var modelsDir: String {
        let override = shared.modelDir.trimmingCharacters(in: .whitespaces)
        if !override.isEmpty { return (override as NSString).expandingTildeInPath }

        let store = canonicalModelStore
        let bin = (store as NSString).appendingPathComponent("ggml-\(shared.model).bin")
        if FileManager.default.fileExists(atPath: bin) { return store }

        if !isInstalled { return resourcePath("whisper.cpp/models") }
        return store
    }

    private static var samplesDir: String {
        isInstalled ? resourcePath("samples") : resourcePath("whisper.cpp/samples")
    }

    static var modelPath: String {
        (modelsDir as NSString).appendingPathComponent("ggml-\(shared.model).bin")
    }

    static var encoderPath: String {
        (modelsDir as NSString).appendingPathComponent("ggml-\(shared.model)-encoder.mlmodelc")
    }

    static var samplePath: String {
        (samplesDir as NSString).appendingPathComponent("jfk.wav")
    }

    /// The whisper-server binary path the app will use. Existence-agnostic so
    /// callers can both launch it and report it when missing.
    /// Installed → the single staged static binary. Dev → the first build that
    /// actually exists (honoring use_ane), else the preferred build's path.
    static var serverBinaryPath: String {
        if isInstalled { return resourcePath("whisper-server") }
        let builds = shared.useANE ? ["build-coreml", "build"] : ["build", "build-coreml"]
        for b in builds {
            let p = resourcePath("whisper.cpp/\(b)/bin/whisper-server")
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return resourcePath("whisper.cpp/\(builds[0])/bin/whisper-server")
    }

    // MARK: - Data locations (dataRoot), seeded from bundle on first run

    static var configFilePath: String {
        let p = dataPath("config.yaml")
        seedIfNeeded(p, from: "config.default.yaml")
        return p
    }

    static var promptFilePath: String {
        let p = dataPath("prompt.txt")
        seedIfNeeded(p, from: "prompt.default.txt")
        return p
    }

    static var serverLogPath: String { dataPath("server.log") }

    /// The app's own log file. Installed → ~/Library/Logs/Speak/speak.log
    /// (conventional macOS log location); dev → the clone's log.txt.
    static var appLogPath: String {
        if isInstalled {
            let logs = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Logs/Speak")
            try? FileManager.default.createDirectory(atPath: logs, withIntermediateDirectories: true)
            return (logs as NSString).appendingPathComponent("speak.log")
        }
        return (dataRoot as NSString).appendingPathComponent("log.txt")
    }

    /// Installed-mode only: if a user file is absent, copy the bundled default
    /// into dataRoot so the data dir survives deletion and a fresh install has
    /// editable files immediately. In dev mode the real files already exist at
    /// the clone root, so this is a no-op.
    private static func seedIfNeeded(_ target: String, from defaultName: String) {
        guard isInstalled, !FileManager.default.fileExists(atPath: target) else { return }
        let seed = resourcePath(defaultName)
        guard FileManager.default.fileExists(atPath: seed) else {
            Log.info("[Config] no bundled default \(defaultName) to seed \(target)")
            return
        }
        do {
            try FileManager.default.copyItem(atPath: seed, toPath: target)
            Log.info("[Config] seeded \(target) from \(defaultName)")
        } catch {
            Log.error("[Config] failed to seed \(target): \(error)")
        }
    }

    // MARK: - Surgical write-back (for the Settings pane)

    private static func currentConfigText() -> String {
        (try? String(contentsOfFile: configFilePath, encoding: .utf8)) ?? ""
    }

    /// Render config.yaml with `values` applied, rewriting ONLY lines whose
    /// value actually changed — so unchanged lines keep their exact bytes. That
    /// invariant is what lets `wouldChange` be a clean whole-file comparison
    /// instead of fragile per-field logic. Comments (own-line, §2.3) and keys
    /// not in `values` (e.g. server_args) are preserved; missing keys appended.
    private static func rendered(_ values: [String: String], into text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        var remaining = values
        for i in lines.indices {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            guard !t.hasPrefix("#"), let colon = t.firstIndex(of: ":") else { continue }
            let key = String(t[..<colon]).trimmingCharacters(in: .whitespaces)
            guard let newValue = remaining.removeValue(forKey: key) else { continue }
            let currentValue = String(t[t.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if currentValue != newValue {
                lines[i] = newValue.isEmpty ? "\(key):" : "\(key): \(newValue)"
            }
        }
        for (key, value) in remaining {
            lines.append(value.isEmpty ? "\(key):" : "\(key): \(value)")
        }
        return lines.joined(separator: "\n")
    }

    /// True iff applying `values` would change config.yaml. One whole-file
    /// comparison — the Settings pane uses this for Save-visibility.
    static func wouldChange(_ values: [String: String]) -> Bool {
        let current = currentConfigText()
        return rendered(values, into: current) != current
    }

    /// Write config.yaml with `values` applied (one read, one write).
    @discardableResult
    static func write(_ values: [String: String]) -> Bool {
        let out = rendered(values, into: currentConfigText())
        do {
            try out.write(toFile: configFilePath, atomically: true, encoding: .utf8)
            return true
        } catch {
            Log.error("[Config] failed to write config.yaml: \(error)")
            return false
        }
    }

    // MARK: - Load

    private static func load() -> Config {
        var config = Config()
        let path = configFilePath

        Log.info("[Config] mode=\(isInstalled ? "installed" : "dev") resourceRoot=\(resourceRoot) dataRoot=\(dataRoot) modelStore=\(canonicalModelStore)")

        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            Log.info("[Config] no config.yaml at \(path) - using defaults")
            return config
        }

        for rawLine in text.components(separatedBy: .newlines) {
            // Strip comments (no # is legal inside our values) and whitespace
            let line = rawLine.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
                .trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            guard let colon = line.firstIndex(of: ":") else {
                Log.info("[Config] skipping malformed line: \(rawLine)")
                continue
            }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)

            switch key {
            case "model": config.model = value
            case "model_dir": config.modelDir = value
            case "log_level": config.logLevel = value
            case "use_ane": config.useANE = (value == "true")
            case "server_port": config.serverPort = Int(value) ?? config.serverPort
            case "server_args": config.serverArgs = value
            case "double_tap_window_ms": config.doubleTapWindowMs = Int(value) ?? config.doubleTapWindowMs
            case "tap_max_ms": config.tapMaxMs = Int(value) ?? config.tapMaxMs
            case "hold_release_ms": config.holdReleaseMs = Int(value) ?? config.holdReleaseMs
            case "hotkey_keycode": config.hotkeyKeycode = Int(value) ?? config.hotkeyKeycode
            case "sounds": config.sounds = (value == "true")
            case "paste_mode": config.pasteMode = value
            case "keep_recordings": config.keepRecordings = (value == "true")
            case "min_speech_dbfs": config.minSpeechDBFS = Double(value) ?? config.minSpeechDBFS
            case "check_for_updates": config.checkForUpdates = (value == "true")
            default:
                Log.info("[Config] unknown key '\(key)' - ignoring")
            }
        }

        Log.level = Log.Level(name: config.logLevel)
        Log.info("[Config] loaded from \(path): ane=\(config.useANE) model=\(config.model) port=\(config.serverPort) modelDir='\(config.modelDir)' log=\(config.logLevel)")
        Log.debug("[Config] gesture=\(config.doubleTapWindowMs)/\(config.tapMaxMs)/\(config.holdReleaseMs)ms key=\(config.hotkeyKeycode)")
        return config
    }
}

import Foundation

/// Loads config.yaml and resolves every on-disk location the app needs.
///
/// Two run modes, detected by the install location itself — no env var:
///   • **installed** — a self-contained `.app` in /Applications, with the
///     whisper-server binary, model, encoder and sample wav staged inside
///     `Contents/Resources`. User-editable files (config.yaml, prompt.txt) and
///     logs (server.log) live in `~/Library/Application Support/Shoum` because
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
    var typeIntoTerminals = false // in terminals, keystroke-inject instead of ⌘V (avoids Claude Code's "[Pasted N lines]" collapse)
    var restoreClipboard = true // put the user's clipboard back after a paste
    var voiceCommands = true // process spoken symbol/markdown commands ("ascii slash" → /); see lexicon.md
    var showWhisperResponse = false // debug: show the raw whisper text for the latest chunk in the box
    var keepRecordings = true // retain WAVs in /tmp/shoum for 24h (debugging)
    var minSpeechDBFS = -60.0 // clips quieter than this are no-speech; skip whisper
    var pruneDeadAudio = true // VAD-cull silence before sending to whisper (kebab)
    var checkForUpdates = true // query GitHub on launch to notify of a newer build

    /// Single source of truth. In-process consumers read this (or derive from
    /// it) rather than caching copies, so a reload propagates for free.
    /// Lock-protected: the main thread replaces it on a Settings change while
    /// background work (audio, transcription) reads it — an unguarded
    /// read-during-replace is a data race.
    static var shared: Config {
        sharedLock.lock(); defer { sharedLock.unlock() }
        return _shared
    }
    private static let sharedLock = NSLock()
    private static var _shared = Config.load()

    /// Re-read config.yaml after the Settings pane writes it. Light settings
    /// apply instantly because consumers read Config.shared directly; only the
    /// external whisper-server process needs an explicit restart.
    static func reload() {
        let fresh = load() // outside the lock — load() logs and touches disk
        sharedLock.lock(); _shared = fresh; sharedLock.unlock()
    }

    // MARK: - Key registry

    /// ONE table drives config.yaml parsing (`load`) and engine-restart
    /// detection (`engineAffecting`). Adding a setting = a stored property, a
    /// row here, and a control in SplashWindow — nothing else to keep in sync.
    private enum Kind {
        case string(WritableKeyPath<Config, String>)
        case int(WritableKeyPath<Config, Int>)
        case double(WritableKeyPath<Config, Double>)
        case bool(WritableKeyPath<Config, Bool>)
    }
    private struct Key {
        let name: String
        let kind: Kind
        /// True when the whisper-server process bakes this in at launch — a
        /// change requires an engine restart.
        let engine: Bool
    }
    private static let registry: [Key] = [
        Key(name: "model", kind: .string(\.model), engine: true),
        Key(name: "model_dir", kind: .string(\.modelDir), engine: true),
        Key(name: "use_ane", kind: .bool(\.useANE), engine: true),
        Key(name: "server_port", kind: .int(\.serverPort), engine: true),
        Key(name: "server_args", kind: .string(\.serverArgs), engine: true),
        Key(name: "log_level", kind: .string(\.logLevel), engine: false),
        Key(name: "double_tap_window_ms", kind: .int(\.doubleTapWindowMs), engine: false),
        Key(name: "tap_max_ms", kind: .int(\.tapMaxMs), engine: false),
        Key(name: "hold_release_ms", kind: .int(\.holdReleaseMs), engine: false),
        Key(name: "hotkey_keycode", kind: .int(\.hotkeyKeycode), engine: false),
        Key(name: "sounds", kind: .bool(\.sounds), engine: false),
        Key(name: "paste_mode", kind: .string(\.pasteMode), engine: false),
        Key(name: "type_into_terminals", kind: .bool(\.typeIntoTerminals), engine: false),
        Key(name: "restore_clipboard", kind: .bool(\.restoreClipboard), engine: false),
        Key(name: "voice_commands", kind: .bool(\.voiceCommands), engine: true), // primer is part of the server prompt
        Key(name: "show_whisper_response", kind: .bool(\.showWhisperResponse), engine: false),
        Key(name: "keep_recordings", kind: .bool(\.keepRecordings), engine: false),
        Key(name: "min_speech_dbfs", kind: .double(\.minSpeechDBFS), engine: false),
        Key(name: "prune_dead_audio", kind: .bool(\.pruneDeadAudio), engine: false),
        Key(name: "check_for_updates", kind: .bool(\.checkForUpdates), engine: false),
    ]
    private static let registryByName = Dictionary(uniqueKeysWithValues: registry.map { ($0.name, $0) })

    /// The canonical string rendering of a key's value (for change comparisons).
    private static func valueString(_ key: Key, of config: Config) -> String {
        switch key.kind {
        case .string(let kp): return config[keyPath: kp]
        case .int(let kp):    return String(config[keyPath: kp])
        case .double(let kp): return String(config[keyPath: kp])
        case .bool(let kp):   return config[keyPath: kp] ? "true" : "false"
        }
    }

    /// Would applying `values` change a setting the whisper-server bakes in at
    /// launch? Drives the restart decision in applySettings.
    static func engineAffecting(_ values: [String: String], comparedTo old: Config) -> Bool {
        registry.contains { key in
            key.engine && values[key.name].map { $0 != valueString(key, of: old) } == true
        }
    }

    // MARK: - Run mode

    /// Installed iff the staged whisper-server binary sits inside the bundle's
    /// Resources. The presence of that file is the whole signal.
    static let isInstalled: Bool = {
        guard let res = Bundle.main.resourceURL else { return false }
        return FileManager.default.fileExists(
            atPath: res.appendingPathComponent("whisper-server").path)
    }()

    /// The dev checkout root: walk up from the bundle to the dir containing
    /// `whisper.cpp/`. Only meaningful in dev mode; failing to find it means the
    /// dev build is running from somewhere unexpected — fail fast in dev, fall
    /// back to a last-resort guess in release.
    private static let cloneRoot: String = {
        var dir = Bundle.main.bundlePath as NSString
        for _ in 0..<8 {
            dir = dir.deletingLastPathComponent as NSString
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("whisper.cpp")) {
                return dir as String
            }
        }
        softAssert(false, "[Config] dev mode but no clone root found above \(Bundle.main.bundlePath)")
        return NSString(string: "~/code/2026/Shoum").expandingTildeInPath
    }()

    /// Read-only assets (server binary, model, encoder, sample wav).
    /// Installed → the bundle's Resources; dev → the clone.
    static let resourceRoot: String = {
        if isInstalled, let res = Bundle.main.resourceURL { return res.path }
        return cloneRoot
    }()

    /// Writable user data + logs (config.yaml, prompt.txt, server.log).
    /// Installed → ~/Library/Application Support/Shoum (created on demand);
    /// dev → the clone.
    static let dataRoot: String = {
        if isInstalled {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let dir = base.appendingPathComponent("Shoum", isDirectory: true)
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
        return base.appendingPathComponent("Shoum/models", isDirectory: true).path
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

    /// Whisper models actually present on this machine (install.sh / manual
    /// staging put them there) — drives the Settings model dropdown, so a model
    /// can only be *selected*, never mistyped. Scans the shared store, a
    /// model_dir override, and (dev) the clone's whisper.cpp/models; excludes
    /// the Silero VAD net and ANE encoders.
    static var availableModels: [String] {
        var dirs = [canonicalModelStore]
        let override = shared.modelDir.trimmingCharacters(in: .whitespaces)
        if !override.isEmpty { dirs = [(override as NSString).expandingTildeInPath] }
        if !isInstalled { dirs.append(resourcePath("whisper.cpp/models")) }

        var names = Set<String>()
        for dir in dirs {
            for file in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] {
                guard file.hasPrefix("ggml-"), file.hasSuffix(".bin"),
                      !file.contains("silero"), !file.contains("encoder") else { continue }
                names.insert(String(file.dropFirst("ggml-".count).dropLast(".bin".count)))
            }
        }
        return names.sorted()
    }

    static var encoderPath: String {
        (modelsDir as NSString).appendingPathComponent("ggml-\(shared.model)-encoder.mlmodelc")
    }

    static var samplePath: String {
        (samplesDir as NSString).appendingPathComponent("jfk.wav")
    }

    /// Silero VAD model (the small ~1 MB net, NOT whisper). Prefer a canonically
    /// named copy in the model store; fall back to the fixture shipped in the
    /// whisper.cpp clone (dev). Stage 2 will bundle a canonical copy at install.
    static var vadModelPath: String {
        let canonical = (modelsDir as NSString).appendingPathComponent("ggml-silero-v6.2.0.bin")
        if FileManager.default.fileExists(atPath: canonical) { return canonical }
        return resourcePath("whisper.cpp/models/for-tests-silero-v6.2.0-ggml.bin")
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

    /// The app's own log file. Installed → ~/Library/Logs/Shoum/shoum.log
    /// (conventional macOS log location); dev → the clone's log.txt.
    static var appLogPath: String {
        if isInstalled {
            let logs = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Logs/Shoum")
            try? FileManager.default.createDirectory(atPath: logs, withIntermediateDirectories: true)
            return (logs as NSString).appendingPathComponent("shoum.log")
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

        // Malformed values fall back to the default, but NEVER silently — a
        // typo'd port would otherwise run on 8178 while the file (and Settings
        // pane) show something else, with nothing connecting the two.
        func intValue(_ raw: String, _ key: String, _ fallback: Int) -> Int {
            if let v = Int(raw) { return v }
            Log.error("[Config] bad value '\(raw)' for \(key) — using \(fallback)")
            return fallback
        }
        func doubleValue(_ raw: String, _ key: String, _ fallback: Double) -> Double {
            if let v = Double(raw) { return v }
            Log.error("[Config] bad value '\(raw)' for \(key) — using \(fallback)")
            return fallback
        }
        func boolValue(_ raw: String, _ key: String, _ fallback: Bool) -> Bool {
            switch raw {
            case "true": return true
            case "false": return false
            default:
                Log.error("[Config] bad value '\(raw)' for \(key) (expected true/false) — using \(fallback)")
                return fallback
            }
        }

        var seenKeys = Set<String>()
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

            // Duplicate keys are a trap: this loader honors the LAST occurrence,
            // but the Settings pane's surgical writer edits the FIRST — so edits
            // would silently not take. Warn so the user removes one.
            if !seenKeys.insert(key).inserted {
                Log.error("[Config] duplicate key '\(key)' — the last value wins, but Settings edits the first; remove one")
            }

            guard let spec = registryByName[key] else {
                Log.info("[Config] unknown key '\(key)' - ignoring")
                continue
            }
            switch spec.kind {
            case .string(let kp): config[keyPath: kp] = value
            case .int(let kp):    config[keyPath: kp] = intValue(value, key, config[keyPath: kp])
            case .double(let kp): config[keyPath: kp] = doubleValue(value, key, config[keyPath: kp])
            case .bool(let kp):   config[keyPath: kp] = boolValue(value, key, config[keyPath: kp])
            }
        }

        Log.level = Log.Level(name: config.logLevel)
        Log.info("[Config] loaded from \(path): ane=\(config.useANE) model=\(config.model) port=\(config.serverPort) modelDir='\(config.modelDir)' log=\(config.logLevel)")
        Log.debug("[Config] gesture=\(config.doubleTapWindowMs)/\(config.tapMaxMs)/\(config.holdReleaseMs)ms key=\(config.hotkeyKeycode)")
        return config
    }
}

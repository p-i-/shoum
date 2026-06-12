import Foundation

/// Loads config.yaml from the speak root. The format is a flat subset of
/// YAML: `key: value  # optional comment` lines, blank lines, and full-line
/// comments. No nesting, no lists — server_args is a whitespace-split string.
struct Config {
    // Server
    var model = "medium.en"
    var useANE = true
    var serverPort = 8178
    var serverArgs = ""

    // Gesture (milliseconds)
    var doubleTapWindowMs = 350
    var tapMaxMs = 250
    var holdReleaseMs = 400
    var hotkeyKeycode = 56 // left shift

    // Behavior
    var sounds = true
    var pasteMode = "paste" // "paste" = activate previous app + Cmd+V; "copy" = clipboard only

    static let shared = Config.load()

    /// Walk up from the app bundle looking for the speak checkout (identified
    /// by its whisper.cpp directory). Falls back to ~/code/speak.
    static let speakRoot: String = {
        var dir = Bundle.main.bundlePath as NSString
        for _ in 0..<8 {
            dir = dir.deletingLastPathComponent as NSString
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("whisper.cpp")) {
                return dir as String
            }
        }
        return NSString(string: "~/code/speak").expandingTildeInPath
    }()

    static func rootPath(_ relative: String) -> String {
        return (speakRoot as NSString).appendingPathComponent(relative)
    }

    private static func load() -> Config {
        var config = Config()
        let path = rootPath("config.yaml")

        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            NSLog("[Config] no config.yaml at \(path) - using defaults")
            return config
        }

        for rawLine in text.components(separatedBy: .newlines) {
            // Strip comments (no # is legal inside our values) and whitespace
            let line = rawLine.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
                .trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            guard let colon = line.firstIndex(of: ":") else {
                NSLog("[Config] skipping malformed line: \(rawLine)")
                continue
            }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)

            switch key {
            case "model": config.model = value
            case "use_ane": config.useANE = (value == "true")
            case "server_port": config.serverPort = Int(value) ?? config.serverPort
            case "server_args": config.serverArgs = value
            case "double_tap_window_ms": config.doubleTapWindowMs = Int(value) ?? config.doubleTapWindowMs
            case "tap_max_ms": config.tapMaxMs = Int(value) ?? config.tapMaxMs
            case "hold_release_ms": config.holdReleaseMs = Int(value) ?? config.holdReleaseMs
            case "hotkey_keycode": config.hotkeyKeycode = Int(value) ?? config.hotkeyKeycode
            case "sounds": config.sounds = (value == "true")
            case "paste_mode": config.pasteMode = value
            default:
                NSLog("[Config] unknown key '\(key)' - ignoring")
            }
        }

        NSLog("[Config] loaded: model=\(config.model) ane=\(config.useANE) port=\(config.serverPort) gesture=\(config.doubleTapWindowMs)/\(config.tapMaxMs)/\(config.holdReleaseMs)ms key=\(config.hotkeyKeycode)")
        return config
    }
}

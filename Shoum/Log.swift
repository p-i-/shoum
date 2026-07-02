import Foundation

/// Minimal leveled logger. Writes to an app-owned file (so detached / installed
/// runs keep logs without depending on run.sh's `tee`) AND to stderr (terminal
/// + unified logging). The level is set once from config.yaml at the end of
/// `Config.load()`; until then it defaults to `.info`.
///
/// Log deliberately never reads `Config.shared` — doing so during Config's own
/// lazy initialization would deadlock. `Config.appLogPath` only touches static
/// state (`isInstalled`/`dataRoot`), so opening the file is safe at any time.
enum Log {
    enum Level: Int, Comparable {
        case error = 0, info = 1, debug = 2
        init(name: String) {
            switch name.lowercased() {
            case "error": self = .error
            case "debug": self = .debug
            default:      self = .info
            }
        }
        var tag: String {
            switch self {
            case .error: return "ERROR"
            case .info:  return "INFO "
            case .debug: return "DEBUG"
            }
        }
        static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }

    /// Set from config.yaml at the end of Config.load(). Default until then.
    static var level: Level = .info

    private static let queue = DispatchQueue(label: "shoum.log")
    private static let stderrHandle = FileHandle.standardError

    /// Opened once on first emit — one fresh log file per launch. The previous
    /// session's log is ROTATED to <path>.1 (not truncated in place): it may hold
    /// a crash report CrashReporter appended after our last write, and wiping it
    /// on relaunch would destroy exactly the evidence it exists to preserve.
    private static let fileHandle: FileHandle? = {
        let path = Config.appLogPath
        let fm = FileManager.default
        if fm.fileExists(atPath: path) {
            let prev = path + ".1"
            try? fm.removeItem(atPath: prev)
            try? fm.moveItem(atPath: path, toPath: prev)
        }
        fm.createFile(atPath: path, contents: nil)
        return FileHandle(forWritingAtPath: path)
    }()

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func error(_ message: @autoclosure () -> String) { emit(.error, message()) }
    static func info(_ message: @autoclosure () -> String)  { emit(.info,  message()) }
    static func debug(_ message: @autoclosure () -> String) { emit(.debug, message()) }

    /// Emit if the message's severity is at least as important as the configured
    /// verbosity (error always shows; debug only when level == debug).
    private static func emit(_ messageLevel: Level, _ message: String) {
        guard messageLevel <= level else { return }
        let line = "\(formatter.string(from: Date())) [\(messageLevel.tag)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        queue.async {
            stderrHandle.write(data)
            fileHandle?.write(data)
        }
    }
}

/// Fail fast in dev, log-and-degrade in production. `assertionFailure` is active
/// in a `--dev` build (-Onone) and compiled out of `--static` (-O), so a broken
/// internal invariant STOPS a dev run at the point of breakage while an installed
/// app logs it and carries on with the caller's fallback.
func softAssert(_ condition: @autoclosure () -> Bool,
                _ message: @autoclosure () -> String,
                file: StaticString = #fileID, line: UInt = #line) {
    if !condition() {
        let msg = message()
        Log.error("[ASSERT] \(msg) (\(file):\(line))")
        assertionFailure(msg, file: file, line: line)
    }
}

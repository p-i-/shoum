import Foundation
import Darwin

/// Captures crashes to the app log. The OS `.ips` for an ad-hoc app omits the
/// NSException *reason* — which is exactly what we need — so we install our own
/// nets. Distribution-grade: an app that dies silently is unshippable.
///
///  • `NSSetUncaughtExceptionHandler` — Objective-C / NSException (what crashed
///    us): logs name + reason + userInfo + symbolicated stack. Runs in normal
///    context, so Foundation/malloc are fine here.
///  • POSIX signal handlers — non-ObjC fatals (SIGSEGV/SIGILL/…): log the signal
///    + a backtrace using only async-signal-safe calls (`write`,
///    `backtrace_symbols_fd`), then re-raise so the OS still writes its `.ips`.
enum CrashReporter {
    private static var logFD: Int32 = -1
    private static var frames = [UnsafeMutableRawPointer?](repeating: nil, count: 128)
    private static let banner = Array("\n===== FATAL SIGNAL — backtrace follows =====\n".utf8)

    static func install(logPath: String) {
        logFD = open(logPath, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        // Force lazy statics to initialize NOW, not inside a signal handler
        // (where the one-time-init guard wouldn't be async-signal-safe).
        _ = (banner.count, frames.count)

        NSSetUncaughtExceptionHandler { exception in
            var s = "\n===== UNCAUGHT EXCEPTION =====\n"
            s += "name:    \(exception.name.rawValue)\n"
            s += "reason:  \(exception.reason ?? "(nil)")\n"
            if let info = exception.userInfo, !info.isEmpty { s += "userInfo: \(info)\n" }
            s += "stack:\n" + exception.callStackSymbols.joined(separator: "\n") + "\n"
            CrashReporter.writeNow(s)
        }

        for sig in [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP] {
            signal(sig) { CrashReporter.handleSignal($0) }
        }
    }

    /// Pre-crash, normal context — malloc/Foundation OK.
    private static func writeNow(_ s: String) {
        Array(s.utf8).withUnsafeBytes { buf in
            if logFD >= 0 { _ = write(logFD, buf.baseAddress, buf.count) }
            _ = write(2, buf.baseAddress, buf.count)
        }
    }

    /// Signal context — async-signal-safe only (no malloc/Foundation).
    private static func handleSignal(_ sig: Int32) {
        banner.withUnsafeBytes { buf in
            if logFD >= 0 { _ = write(logFD, buf.baseAddress, buf.count) }
            _ = write(2, buf.baseAddress, buf.count)
        }
        let n = backtrace(&frames, Int32(frames.count))
        if logFD >= 0 { backtrace_symbols_fd(&frames, n, logFD) }
        backtrace_symbols_fd(&frames, n, 2)
        signal(sig, SIG_DFL) // restore default and re-raise so the OS still writes its .ips
        raise(sig)
    }
}

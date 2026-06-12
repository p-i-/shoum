import Cocoa
import Carbon.HIToolbox

protocol KeyMonitorDelegate: AnyObject {
    /// Double-tap on left shift — engage recording.
    func keyMonitorDidDetectDoubleTap()
    /// Clean single tap on left shift — stop recording / confirm paste.
    func keyMonitorDidDetectTap()
    /// Release after a double-tap-and-hold — push-to-talk style stop.
    func keyMonitorDidDetectHoldRelease()
}

class KeyMonitor {
    weak var delegate: KeyMonitorDelegate?

    /// When true, a single tap is only reported after the double-tap window
    /// expires, so it can be distinguished from the first tap of a double-tap.
    /// Enable in states where both gestures are meaningful (editing); leave
    /// off where taps should fire instantly (recording).
    var disambiguatesTaps = false

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    // All times come from CGEvent.timestamp — stamped by the HID system at the
    // physical keypress. The tap's runloop source lives on the MAIN runloop, so
    // both delivery and processing can be delayed by main-thread work (window
    // creation, engine start); any clock read on our side, however early,
    // inflates apparent press durations. Only the hardware timestamp is safe.
    private var shiftDownTime: TimeInterval?
    private var usedAsModifier = false
    private var lastTapReleaseTime: TimeInterval?
    private var pendingTapTimer: Timer?
    private var engagedByThisPress = false

    /// A press longer than this is not a tap.
    private let tapMaxDuration = TimeInterval(Config.shared.tapMaxMs) / 1000
    /// Max gap between a tap's release and the next press to count as a double-tap.
    private let doubleTapWindow = TimeInterval(Config.shared.doubleTapWindowMs) / 1000
    /// Holding the second press of a double-tap at least this long makes its
    /// release stop the recording (push-to-talk).
    private let holdReleaseThreshold = TimeInterval(Config.shared.holdReleaseMs) / 1000

    /// Which modifier key triggers gestures (56 = left shift, 60 = right shift)
    private let hotkeyKeyCode = CGKeyCode(Config.shared.hotkeyKeycode)

    // CGEvent.timestamp units differ across systems (mach ticks vs
    // nanoseconds). Calibrate once against the system clock instead of
    // assuming: both clocks count from boot, so the right conversion is the
    // one that lands near systemUptime.
    private static var timestampScale: Double = 0

    private static func eventTime(_ event: CGEvent) -> TimeInterval {
        let raw = Double(event.timestamp)

        if timestampScale == 0 {
            var info = mach_timebase_info_data_t()
            mach_timebase_info(&info)
            let machScale = Double(info.numer) / Double(info.denom) / 1_000_000_000.0
            let nsScale = 1.0 / 1_000_000_000.0

            let uptime = ProcessInfo.processInfo.systemUptime
            let machErr = abs(raw * machScale - uptime)
            let nsErr = abs(raw * nsScale - uptime)
            timestampScale = nsErr < machErr ? nsScale : machScale
            NSLog("[KeyMonitor] timestamp units calibrated: %@ (event %.1fs vs uptime %.1fs)",
                  nsErr < machErr ? "nanoseconds" : "mach ticks", raw * timestampScale, uptime)

            if min(machErr, nsErr) > 60 {
                NSLog("[KeyMonitor] WARNING: neither unit matches uptime; gesture timing may be wrong")
            }
        }

        return raw * timestampScale
    }

    @discardableResult
    func start() -> Bool {
        // flagsChanged for shift itself, keyDown so intervening keystrokes
        // (shift used as a modifier, typing between taps) cancel tap gestures.
        let eventMask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { proxy, type, event, refcon in
                guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<KeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                return monitor.handleEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            NSLog("[KeyMonitor] FAILED to create event tap - Accessibility permissions required!")
            return false
        }

        eventTap = tap

        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        NSLog("[KeyMonitor] Event tap created successfully")
        return true
    }

    func stop() {
        pendingTapTimer?.invalidate()
        pendingTapTimer = nil

        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }

        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }

        eventTap = nil
        runLoopSource = nil
    }

    private func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Handle tap disabled event (re-enable if needed)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        if type == .keyDown {
            DispatchQueue.main.async { [weak self] in
                self?.processOtherKeyDown()
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == .flagsChanged else {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard keyCode == hotkeyKeyCode else {
            return Unmanaged.passUnretained(event)
        }

        let shiftPressed = event.flags.contains(.maskShift)
        let hardwareTime = Self.eventTime(event)

        DispatchQueue.main.async { [weak self] in
            self?.processShiftState(isPressed: shiftPressed, at: hardwareTime)
        }

        return Unmanaged.passUnretained(event)
    }

    private func processOtherKeyDown() {
        // Any real keystroke means shift is being used as a modifier and/or
        // the user is typing — either way, cancel tap sequences in flight.
        if shiftDownTime != nil {
            usedAsModifier = true
        }
        pendingTapTimer?.invalidate()
        pendingTapTimer = nil
        lastTapReleaseTime = nil
    }

    private func processShiftState(isPressed: Bool, at now: TimeInterval) {
        // How stale is this event by the time we process it? Nonzero lag means
        // the main thread was busy; durations stay correct regardless because
        // they're computed from hardware timestamps.
        let lag = (ProcessInfo.processInfo.systemUptime - now) * 1000
        if lag > 50 {
            NSLog("[KeyMonitor] shift %@ processed %.0fms late (main thread was busy)", isPressed ? "down" : "up", lag)
        }

        if isPressed {
            usedAsModifier = false
            shiftDownTime = now

            if let lastRelease = lastTapReleaseTime, now - lastRelease <= doubleTapWindow {
                // Second tap of a double-tap: engage immediately on key-down.
                pendingTapTimer?.invalidate()
                pendingTapTimer = nil
                lastTapReleaseTime = nil
                engagedByThisPress = true
                NSLog("[KeyMonitor] double-tap (gap %.0fms) -> engage", (now - lastRelease) * 1000)
                delegate?.keyMonitorDidDetectDoubleTap()
            }
        } else {
            guard let downTime = shiftDownTime else { return }
            let duration = now - downTime
            shiftDownTime = nil

            if engagedByThisPress {
                // Release of the press that triggered the double-tap. A quick
                // release leaves recording toggled on; a long hold means
                // push-to-talk, so the release stops it.
                engagedByThisPress = false
                if duration >= holdReleaseThreshold {
                    NSLog("[KeyMonitor] engaging press held %.0fms -> hold-release (stop)", duration * 1000)
                    delegate?.keyMonitorDidDetectHoldRelease()
                } else {
                    NSLog("[KeyMonitor] engaging press released after %.0fms -> toggle stays on", duration * 1000)
                }
                return
            }

            guard !usedAsModifier, duration <= tapMaxDuration else {
                // Bare shift presses are gesture attempts; modifier use is
                // ordinary typing and stays out of the log.
                if !usedAsModifier {
                    NSLog("[KeyMonitor] bare shift press %.0fms - too long for a tap (max %.0fms)", duration * 1000, tapMaxDuration * 1000)
                }
                lastTapReleaseTime = nil
                return
            }

            lastTapReleaseTime = now

            if disambiguatesTaps {
                NSLog("[KeyMonitor] tap (%.0fms), waiting %.0fms to rule out double-tap", duration * 1000, doubleTapWindow * 1000)
                pendingTapTimer?.invalidate()
                pendingTapTimer = Timer.scheduledTimer(withTimeInterval: doubleTapWindow, repeats: false) { [weak self] _ in
                    self?.pendingTapTimer = nil
                    self?.lastTapReleaseTime = nil
                    NSLog("[KeyMonitor] single tap confirmed")
                    self?.delegate?.keyMonitorDidDetectTap()
                }
            } else {
                NSLog("[KeyMonitor] tap (%.0fms) -> immediate", duration * 1000)
                delegate?.keyMonitorDidDetectTap()
            }
        }
    }
}

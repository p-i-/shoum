import Cocoa
import Carbon.HIToolbox

protocol KeyMonitorDelegate: AnyObject {
    /// Double-tap on left shift — engage recording.
    func keyMonitorDidDetectDoubleTap()
    /// Clean single tap on left shift — stop recording / confirm paste.
    /// Return true if the tap TRIGGERED an action: an actioned tap must not
    /// also count as the first tap of a double-tap (a stop-tap followed by an
    /// ordinary shift press within the window would phantom-start a recording).
    /// Return false when the tap was ignored (idle) — an ignored tap stays
    /// eligible to pair up, which is exactly how dictation starts from idle.
    func keyMonitorDidDetectTap() -> Bool
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

    /// Whether the created tap is actually enabled (receiving events). A tap can
    /// be CREATED without Accessibility permission but stays disabled/dead — so
    /// this, not tap-creation success, is the real "is the hotkey live" signal.
    var isTapEnabled: Bool {
        guard let tap = eventTap else { return false }
        return CGEvent.tapIsEnabled(tap: tap)
    }

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
    /// Logged on each double-tap: whether its first tap had already fired as an
    /// immediate tap (only an IGNORED immediate tap may chain — see delegate doc).
    private var lastTapFiredImmediately = false
    /// Hardware timestamp of the newest flagsChanged event (ANY keycode) we've
    /// processed — compared against the HID system's own record to detect
    /// events still queued behind a busy main thread (see confirmPendingSingleTap).
    private var lastSeenFlagsChangedTime: TimeInterval = 0

    // Derived from Config.shared each read (single source of truth) so a live
    // config reload applies with no caching/invalidation.

    /// A press longer than this is not a tap.
    private var tapMaxDuration: TimeInterval { TimeInterval(Config.shared.tapMaxMs) / 1000 }
    /// Max gap between a tap's release and the next press to count as a double-tap.
    private var doubleTapWindow: TimeInterval { TimeInterval(Config.shared.doubleTapWindowMs) / 1000 }
    /// Holding the second press of a double-tap at least this long makes its
    /// release stop the recording (push-to-talk).
    private var holdReleaseThreshold: TimeInterval { TimeInterval(Config.shared.holdReleaseMs) / 1000 }

    /// Which modifier key triggers gestures (56 = left shift, 60 = right shift)
    private var hotkeyKeyCode: CGKeyCode { CGKeyCode(Config.shared.hotkeyKeycode) }

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
            Log.info("[KeyMonitor] timestamp units calibrated: \(nsErr < machErr ? "nanoseconds" : "mach ticks") (event \(String(format: "%.1f", raw * timestampScale))s vs uptime \(String(format: "%.1f", uptime))s)")

            if min(machErr, nsErr) > 60 {
                Log.error("[KeyMonitor] WARNING: neither unit matches uptime; gesture timing may be wrong")
            }
        }

        return raw * timestampScale
    }

    @discardableResult
    func start(quiet: Bool = false) -> Bool {
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
            if quiet {
                Log.debug("[KeyMonitor] event tap not created yet (awaiting Accessibility)")
            } else {
                Log.error("[KeyMonitor] FAILED to create event tap - Accessibility permissions required!")
            }
            return false
        }

        eventTap = tap

        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        Log.info("[KeyMonitor] Event tap created successfully")
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

        // Invalidate the mach port too — disabling alone leaks it across the
        // stop/re-arm cycle the Accessibility grant flow performs.
        if let tap = eventTap {
            CFMachPortInvalidate(tap)
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
        let shiftPressed = event.flags.contains(.maskShift)
        let hardwareTime = Self.eventTime(event)
        let isHotkey = keyCode == hotkeyKeyCode

        // Every flagsChanged (any keycode) advances lastSeenFlagsChangedTime on
        // the same serialized main hop as gesture processing, so the pending-
        // single-tap confirm can tell "processed everything" from "events still
        // queued".
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.lastSeenFlagsChangedTime = max(self.lastSeenFlagsChangedTime, hardwareTime)
            if isHotkey { self.processShiftState(isPressed: shiftPressed, at: hardwareTime) }
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
            Log.debug("[KeyMonitor] shift \(isPressed ? "down" : "up") processed \(String(format: "%.0f", lag))ms late (main thread was busy)")
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
                Log.debug("[KeyMonitor] double-tap (gap \(String(format: "%.0f", (now - lastRelease) * 1000))ms, first tap \(lastTapFiredImmediately ? "ALREADY FIRED as immediate tap" : "was pending")) -> engage")
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
                    Log.debug("[KeyMonitor] engaging press held \(String(format: "%.0f", duration * 1000))ms -> hold-release (stop)")
                    delegate?.keyMonitorDidDetectHoldRelease()
                } else {
                    Log.debug("[KeyMonitor] engaging press released after \(String(format: "%.0f", duration * 1000))ms -> toggle stays on")
                }
                return
            }

            guard !usedAsModifier, duration <= tapMaxDuration else {
                // Bare shift presses are gesture attempts; modifier use is
                // ordinary typing and stays out of the log.
                if !usedAsModifier {
                    Log.debug("[KeyMonitor] bare shift press \(String(format: "%.0f", duration * 1000))ms - too long for a tap (max \(String(format: "%.0f", tapMaxDuration * 1000))ms)")
                }
                lastTapReleaseTime = nil
                return
            }

            lastTapReleaseTime = now

            if disambiguatesTaps {
                lastTapFiredImmediately = false
                Log.debug("[KeyMonitor] tap (\(String(format: "%.0f", duration * 1000))ms), waiting \(String(format: "%.0f", doubleTapWindow * 1000))ms to rule out double-tap")
                pendingTapTimer?.invalidate()
                pendingTapTimer = Timer.scheduledTimer(withTimeInterval: doubleTapWindow, repeats: false) { [weak self] _ in
                    self?.pendingTapTimer = nil
                    self?.confirmPendingSingleTap(defersLeft: 4)
                }
            } else {
                lastTapFiredImmediately = true
                Log.debug("[KeyMonitor] tap (\(String(format: "%.0f", duration * 1000))ms) -> immediate")
                let actioned = delegate?.keyMonitorDidDetectTap() ?? false
                if actioned {
                    // An actioned tap must not double as the first tap of a
                    // double-tap (see the delegate doc); an ignored one stays
                    // eligible — that's how idle's double-tap forms.
                    lastTapReleaseTime = nil
                }
            }
        }
    }

    /// The wall-clock disambiguation timer has expired — but the double-tap
    /// window is judged in HARDWARE time, and under main-thread lag a second
    /// press that is physically inside the window can still be queued behind
    /// us. Before declaring a single tap, ask the HID system whether a
    /// flagsChanged newer than anything we've processed exists; if so, defer
    /// briefly so the queued event runs first (if it's the double-tap press,
    /// it invalidates this pending confirm). Bounded: unrelated modifier
    /// activity can cost a few 50 ms defers, never a livelock.
    private func confirmPendingSingleTap(defersLeft: Int) {
        guard let release = lastTapReleaseTime else { return } // already consumed
        let now = ProcessInfo.processInfo.systemUptime
        let newestPhysical = now - CGEventSource.secondsSinceLastEventType(
            .hidSystemState, eventType: .flagsChanged)
        let newestProcessed = max(lastSeenFlagsChangedTime, release)
        if defersLeft > 0, newestPhysical > newestProcessed + 0.005 {
            Log.debug("[KeyMonitor] single-tap verdict deferred \(String(format: "%.0f", (newestPhysical - newestProcessed) * 1000))ms — an unprocessed flagsChanged is in flight")
            pendingTapTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: false) { [weak self] _ in
                self?.pendingTapTimer = nil
                self?.confirmPendingSingleTap(defersLeft: defersLeft - 1)
            }
            return
        }
        lastTapReleaseTime = nil
        Log.debug("[KeyMonitor] single tap confirmed")
        _ = delegate?.keyMonitorDidDetectTap()
    }
}

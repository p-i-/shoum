import Cocoa
import Carbon.HIToolbox

protocol KeyMonitorDelegate: AnyObject {
    func keyMonitorDidDetectHoldStart()
    func keyMonitorDidDetectHoldEnd()
    func keyMonitorDidDetectTap()
}

class KeyMonitor {
    weak var delegate: KeyMonitorDelegate?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private var keyDownTime: Date?
    private var holdTimer: Timer?
    private var isHolding = false

    private let holdThreshold: TimeInterval = 0.3 // 300ms

    // Left shift keycode
    private let leftShiftKeyCode: CGKeyCode = 56

    func start() {
        // Create event tap for key events
        let eventMask = (1 << CGEventType.flagsChanged.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { proxy, type, event, refcon in
                guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<KeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                return monitor.handleEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            NSLog("[KeyMonitor] FAILED to create event tap - Accessibility permissions required!")
            return
        }

        eventTap = tap

        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        NSLog("[KeyMonitor] Event tap created successfully")
    }

    func stop() {
        holdTimer?.invalidate()
        holdTimer = nil

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

        guard type == .flagsChanged else {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags

        // Check if this is left shift (keycode 56)
        guard keyCode == leftShiftKeyCode else {
            return Unmanaged.passUnretained(event)
        }

        let shiftPressed = flags.contains(.maskShift)

        DispatchQueue.main.async { [weak self] in
            self?.processShiftState(isPressed: shiftPressed)
        }

        return Unmanaged.passUnretained(event)
    }

    private func processShiftState(isPressed: Bool) {
        if isPressed {
            keyDownTime = Date()
            isHolding = false

            // Start timer for hold detection
            holdTimer?.invalidate()
            holdTimer = Timer.scheduledTimer(withTimeInterval: holdThreshold, repeats: false) { [weak self] _ in
                self?.isHolding = true
                self?.delegate?.keyMonitorDidDetectHoldStart()
            }
        } else {
            holdTimer?.invalidate()
            holdTimer = nil

            if isHolding {
                isHolding = false
                delegate?.keyMonitorDidDetectHoldEnd()
            } else {
                delegate?.keyMonitorDidDetectTap()
            }

            keyDownTime = nil
        }
    }
}

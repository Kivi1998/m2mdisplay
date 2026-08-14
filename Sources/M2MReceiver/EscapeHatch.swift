import CoreGraphics
import Foundation
import AppKit

/// Triple-tap Escape to quit. This receiver's window sits at a level that
/// visually covers everything else on screen (that's the whole point — it's
/// supposed to look like a real monitor, not an app window) — which means
/// there is otherwise no way back to whatever else was on this Mac's screen
/// short of SSHing in and killing the process. Three presses within 2s is
/// deliberately not a single Escape tap, so it doesn't fire from normal use
/// of whatever's running underneath (a dialog being dismissed, etc.).
final class EscapeHatch {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var pressTimestamps: [CFAbsoluteTime] = []
    private let requiredPresses = 3
    private let windowSeconds: CFAbsoluteTime = 2.0
    private let escapeKeyCode: Int64 = 53

    func start() -> Bool {
        let mask: CGEventMask = 1 << CGEventType.keyDown.rawValue
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, _, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let hatch = Unmanaged<EscapeHatch>.fromOpaque(refcon).takeUnretainedValue()
                hatch.handle(event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: refcon
        ) else {
            return false
        }
        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func handle(_ event: CGEvent) {
        guard event.getIntegerValueField(.keyboardEventKeycode) == escapeKeyCode else { return }
        let now = CFAbsoluteTimeGetCurrent()
        pressTimestamps.append(now)
        pressTimestamps.removeAll { now - $0 > windowSeconds }
        if pressTimestamps.count >= requiredPresses {
            print("[EscapeHatch] triple-Escape detected, quitting")
            NSApp.terminate(nil)
        }
    }
}

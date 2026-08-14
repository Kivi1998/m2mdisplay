import CoreGraphics
import Foundation
import ApplicationServices

/// Watches the real mouse cursor globally and reports its position whenever it's
/// over the virtual display — this is the piece that makes the cursor feel
/// instant on the iMac side (see Protocol.swift's CursorPacket doc comment):
/// position updates ride their own channel instead of being baked into encoded
/// video frames.
///
/// Needs Accessibility (Input Monitoring) permission — macOS won't deliver
/// global mouse events to an unprivileged process. If tap creation fails, we
/// tell the user exactly what to grant rather than silently doing nothing.
final class MouseTap {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let virtualDisplayID: CGDirectDisplayID
    private let width: Int
    private let height: Int
    /// isVisible is false exactly once per exit — the receiver hides its cursor
    /// overlay on that signal instead of leaving it stuck at the last position
    /// it saw before the cursor moved back onto this Mac's own screen.
    var onPosition: ((Float, Float, Bool) -> Void)?
    private var eventCount = 0
    private var isInsideBounds = false

    init(virtualDisplayID: CGDirectDisplayID, width: Int, height: Int) {
        self.virtualDisplayID = virtualDisplayID
        self.width = width
        self.height = height
    }

    func start() -> Bool {
        let mask: CGEventMask = (1 << CGEventType.mouseMoved.rawValue)
            | (1 << CGEventType.leftMouseDragged.rawValue)
            | (1 << CGEventType.rightMouseDragged.rawValue)

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, _, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let mouseTap = Unmanaged<MouseTap>.fromOpaque(refcon).takeUnretainedValue()
                mouseTap.handle(event)
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
        let displayBounds = CGDisplayBounds(virtualDisplayID)
        let location = event.location // global coords, origin top-left of the primary display, points
        eventCount += 1
        if eventCount <= 10 {
            fputs("[MouseTap] event #\(eventCount) at \(location), displayBounds=\(displayBounds)\n", stderr)
        }
        guard displayBounds.contains(location) else {
            if isInsideBounds {
                isInsideBounds = false
                fputs("[MouseTap] LEFT virtual display bounds at \(location)\n", stderr)
                onPosition?(0, 0, false)
            }
            return
        }
        if !isInsideBounds {
            isInsideBounds = true
            fputs("[MouseTap] ENTERED virtual display bounds at \(location)\n", stderr)
        }
        let relX = Float(location.x - displayBounds.origin.x)
        let relY = Float(location.y - displayBounds.origin.y)
        onPosition?(relX, relY, true)
    }

    func stop() {
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        eventTap = nil
        runLoopSource = nil
    }
}

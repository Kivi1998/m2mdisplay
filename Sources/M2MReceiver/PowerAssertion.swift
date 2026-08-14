import IOKit.pwr_mgt
import Foundation

/// Holds this Mac awake and its display on for as long as it's alive. Without
/// this, macOS has no idea anything is "using" the screen — we're pushing
/// pixels over the network, not touching this Mac's own keyboard/mouse, so its
/// idle timers see no activity and the display sleeps/locks on schedule, right
/// on top of whatever we're rendering.
final class PowerAssertion {
    private var displayAssertionID: IOPMAssertionID = 0
    private var systemAssertionID: IOPMAssertionID = 0
    private var isActive = false

    func start() -> Bool {
        let reason = "M2MReceiver is displaying a live stream from another Mac" as CFString
        let displayStatus = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason,
            &displayAssertionID
        )
        let systemStatus = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason,
            &systemAssertionID
        )
        isActive = displayStatus == kIOReturnSuccess && systemStatus == kIOReturnSuccess
        return isActive
    }

    func stop() {
        guard isActive else { return }
        IOPMAssertionRelease(displayAssertionID)
        IOPMAssertionRelease(systemAssertionID)
        isActive = false
    }

    deinit {
        stop()
    }
}

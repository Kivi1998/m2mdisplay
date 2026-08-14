import CGVirtualDisplayShim
import Foundation

final class VirtualDisplay {
    let displayID: CGDirectDisplayID
    let width: Int
    let height: Int
    private let ref: M2MVirtualDisplayRef

    init?(name: String, width: Int, height: Int, refreshRate: Double, widthMM: Int, heightMM: Int) {
        var displayID: UInt32 = 0
        guard let ref = name.withCString({ namePtr in
            M2MCreateVirtualDisplay(namePtr, UInt32(width), UInt32(height), refreshRate, UInt32(widthMM), UInt32(heightMM), &displayID)
        }) else {
            return nil
        }
        self.ref = ref
        self.displayID = displayID
        self.width = width
        self.height = height

        var config: CGDisplayConfigRef?
        if CGBeginDisplayConfiguration(&config) == .success, let config {
            if let mode = Self.findMode(displayID: displayID, pixelWidth: width, pixelHeight: height) {
                CGConfigureDisplayWithDisplayMode(config, displayID, mode, nil)
            } else {
                fputs("[VirtualDisplay] WARNING: couldn't find a \(width)x\(height) mode to activate among available modes\n", stderr)
            }
            // At 1920x1080 specifically, macOS deterministically defaults this
            // freshly-created virtual display into a mirror set with the
            // built-in screen (confirmed 5/5 in testing) — not flaky, just
            // the OS's default arrangement for a display it's never seen
            // before landing on mirror instead of extend. Explicitly
            // overriding it every launch replaces that default outright
            // instead of hoping the OS remembers a saved preference for an
            // identity (serialNum) that's regenerated fresh every run.
            CGConfigureDisplayMirrorOfDisplay(config, displayID, kCGNullDirectDisplay)
            let result = CGCompleteDisplayConfiguration(config, .forSession)
            if result != .success {
                fputs("[VirtualDisplay] WARNING: display configuration failed (CGCompleteDisplayConfiguration: \(result.rawValue))\n", stderr)
            }
        }
    }

    private static func findMode(displayID: CGDirectDisplayID, pixelWidth: Int, pixelHeight: Int) -> CGDisplayMode? {
        guard let modes = CGDisplayCopyAllDisplayModes(displayID, nil) as? [CGDisplayMode] else { return nil }
        return modes.first { $0.pixelWidth == pixelWidth && $0.pixelHeight == pixelHeight }
    }

    deinit {
        M2MDestroyVirtualDisplay(ref)
    }
}

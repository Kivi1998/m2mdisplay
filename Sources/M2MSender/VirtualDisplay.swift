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
    }

    deinit {
        M2MDestroyVirtualDisplay(ref)
    }
}

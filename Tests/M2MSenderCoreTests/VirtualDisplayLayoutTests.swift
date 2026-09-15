import XCTest
@testable import M2MSenderCore

final class VirtualDisplayLayoutTests: XCTestCase {
    func test发送端为主屏时接收端位于右侧() {
        let origins = VirtualDisplay.displayOrigins(builtInWidth: 1728, receiverIsMain: false)
        XCTAssertEqual(origins.builtInX, 0)
        XCTAssertEqual(origins.virtualX, 1728)
    }

    func test接收端为主屏时MacBook仍位于左侧() {
        let origins = VirtualDisplay.displayOrigins(builtInWidth: 1728, receiverIsMain: true)
        XCTAssertEqual(origins.builtInX, -1728)
        XCTAssertEqual(origins.virtualX, 0)
    }
}

import XCTest
@testable import M2MReceiverCore

final class NativeVolumeHUDTests: XCTestCase {
    func test原生HUD窗口中心会对准声音图标中心() {
        let anchorRect = CGRect(x: 1_613, y: 0, width: 44, height: 30)
        let hudBounds = CGRect(x: 1_572, y: 0, width: 352, height: 149)

        XCTAssertEqual(
            ControlCenterHUDPositioner.centeredOriginX(
                anchorRect: anchorRect,
                hudBounds: hudBounds
            ),
            1_459
        )
    }

    func test音量值会限制在原生HUD范围内() {
        XCTAssertEqual(
            NativeVolumeHUD.presentation(volume: -1, muted: false),
            .init(imageID: 3, filledChiclets: 0)
        )
        XCTAssertEqual(
            NativeVolumeHUD.presentation(volume: 0.375, muted: false),
            .init(imageID: 3, filledChiclets: 38)
        )
        XCTAssertEqual(
            NativeVolumeHUD.presentation(volume: 2, muted: false),
            .init(imageID: 3, filledChiclets: 100)
        )
    }

    func test静音使用系统静音图形并清空音量格() {
        XCTAssertEqual(
            NativeVolumeHUD.presentation(volume: 0.75, muted: true),
            .init(imageID: 4, filledChiclets: 0)
        )
    }
}

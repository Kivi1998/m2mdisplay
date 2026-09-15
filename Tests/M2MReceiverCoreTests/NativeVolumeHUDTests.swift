import XCTest
@testable import M2MReceiverCore

final class NativeVolumeHUDTests: XCTestCase {
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

    func test系统版本决定是否使用私有原生HUD() {
        XCTAssertTrue(
            NativeVolumeHUD.supportsSystemVersion(
                .init(majorVersion: 26, minorVersion: 6, patchVersion: 0)
            )
        )
        XCTAssertFalse(
            NativeVolumeHUD.supportsSystemVersion(
                .init(majorVersion: 27, minorVersion: 0, patchVersion: 0)
            )
        )
    }
}

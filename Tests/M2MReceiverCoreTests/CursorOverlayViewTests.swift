import AppKit
import XCTest
@testable import M2MReceiverCore

final class CursorOverlayViewTests: XCTestCase {
    func test光标覆盖窗口始终高于视频窗口() {
        XCTAssertGreaterThan(
            ReceiverEngine.cursorWindowLevel.rawValue,
            NSWindow.Level.screenSaver.rawValue
        )
    }

    func test收到可见坐标后箭头图层被显示() {
        let view = CursorOverlayView(frame: NSRect(x: 0, y: 0, width: 1920, height: 1080))
        view.updateCursor(normalizedX: 0.5, normalizedY: 0.5)
        XCTAssertTrue(view.isCursorVisibleForTesting)
    }
}

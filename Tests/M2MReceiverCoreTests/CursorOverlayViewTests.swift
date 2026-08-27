import AppKit
import XCTest
import M2MShared
@testable import M2MReceiverCore

final class CursorOverlayViewTests: XCTestCase {
    func test光标覆盖窗口始终高于视频窗口() {
        XCTAssertEqual(
            ReceiverEngine.castingWindowLevel.rawValue,
            NSWindow.Level.screenSaver.rawValue
        )
        XCTAssertGreaterThan(
            ReceiverEngine.cursorWindowLevel.rawValue,
            ReceiverEngine.castingWindowLevel.rawValue
        )
    }

    func test收到可见坐标后箭头图层被显示() {
        let view = CursorOverlayView(frame: NSRect(x: 0, y: 0, width: 1920, height: 1080))
        view.updateCursor(normalizedX: 0.5, normalizedY: 0.5, cursorType: .arrow)
        XCTAssertTrue(view.isCursorVisibleForTesting)
        XCTAssertEqual(view.currentTypeForTesting, .arrow)
    }

    func test光标类型切换会实际改变渲染的图形() {
        let view = CursorOverlayView(frame: NSRect(x: 0, y: 0, width: 1920, height: 1080))
        view.updateCursor(normalizedX: 0.5, normalizedY: 0.5, cursorType: .arrow)
        XCTAssertEqual(view.currentTypeForTesting, .arrow)

        view.updateCursor(normalizedX: 0.5, normalizedY: 0.5, cursorType: .pointingHand)
        XCTAssertEqual(view.currentTypeForTesting, .pointingHand)

        view.updateCursor(normalizedX: 0.5, normalizedY: 0.5, cursorType: .iBeam)
        XCTAssertEqual(view.currentTypeForTesting, .iBeam)
    }

    func test未手绘的类型安全退化成箭头不会崩溃() {
        let view = CursorOverlayView(frame: NSRect(x: 0, y: 0, width: 1920, height: 1080))
        view.updateCursor(normalizedX: 0.5, normalizedY: 0.5, cursorType: .resizeLeftRight)
        XCTAssertTrue(view.isCursorVisibleForTesting)
    }

    func test隐藏后光标层不再可见() {
        let view = CursorOverlayView(frame: NSRect(x: 0, y: 0, width: 1920, height: 1080))
        view.updateCursor(normalizedX: 0.5, normalizedY: 0.5, cursorType: .arrow)
        view.hideCursor()
        XCTAssertFalse(view.isCursorVisibleForTesting)
    }
}

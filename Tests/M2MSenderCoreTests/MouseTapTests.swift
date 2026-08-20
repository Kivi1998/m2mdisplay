import CoreGraphics
import XCTest
@testable import M2MSenderCore

final class MouseTapTests: XCTestCase {
    func test左键发生后轮询坐标仍能继续上报() {
        let bounds = CGRect(x: 1728, y: 0, width: 1920, height: 1080)
        let tracker = MouseTap(
            virtualDisplayID: 99,
            displayBoundsProvider: { bounds }
        )
        var packets: [(Float, Float, Bool)] = []
        tracker.onPosition = { packets.append(($0, $1, $2)) }

        tracker.process(location: CGPoint(x: 1900, y: 400))
        // 左键本身不参与坐标追踪。点击后下一次轮询仍应正常报告新位置。
        tracker.process(location: CGPoint(x: 2020, y: 520))

        XCTAssertEqual(packets.count, 2)
        XCTAssertEqual(packets[0].0, 172)
        XCTAssertEqual(packets[0].1, 400)
        XCTAssertTrue(packets[0].2)
        XCTAssertEqual(packets[1].0, 292)
        XCTAssertEqual(packets[1].1, 520)
        XCTAssertTrue(packets[1].2)
    }

    func test光标离开虚拟屏时只发送一次隐藏状态() {
        let bounds = CGRect(x: 1728, y: 0, width: 1920, height: 1080)
        let tracker = MouseTap(
            virtualDisplayID: 99,
            displayBoundsProvider: { bounds }
        )
        var visibility: [Bool] = []
        tracker.onPosition = { _, _, visible in visibility.append(visible) }

        tracker.process(location: CGPoint(x: 1900, y: 400))
        tracker.process(location: CGPoint(x: 500, y: 400))
        tracker.process(location: CGPoint(x: 400, y: 400))

        XCTAssertEqual(visibility, [true, false])
    }
}

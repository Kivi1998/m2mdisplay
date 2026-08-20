import CoreGraphics
import XCTest
import M2MShared
@testable import M2MSenderCore

final class MouseTapTests: XCTestCase {
    func test抓屏配置不携带系统光标() {
        // 光标改回独立低延迟通道传输，不能再让 ScreenCaptureKit 把光标烤进视频帧——
        // 那样光标就会跟着视频编解码/网络一起卡顿，见 Capturer.swift 里的说明。
        let configuration = FrameCapturer.makeConfiguration(width: 3840, height: 2160, frameRate: 60)
        XCTAssertFalse(configuration.showsCursor)
    }

    func test左键发生后轮询坐标仍能继续上报() {
        let bounds = CGRect(x: 1728, y: 0, width: 1920, height: 1080)
        let tracker = MouseTap(
            virtualDisplayID: 99,
            displayBoundsProvider: { bounds },
            cursorTypeProvider: { .arrow }
        )
        var packets: [(Float, Float, CursorType, Bool)] = []
        tracker.onPosition = { packets.append(($0, $1, $2, $3)) }

        tracker.process(location: CGPoint(x: 1900, y: 400))
        // 左键本身不参与坐标追踪。点击后下一次轮询仍应正常报告新位置。
        tracker.process(location: CGPoint(x: 2020, y: 520))

        XCTAssertEqual(packets.count, 2)
        XCTAssertEqual(packets[0].0, 172)
        XCTAssertEqual(packets[0].1, 400)
        XCTAssertTrue(packets[0].3)
        XCTAssertEqual(packets[1].0, 292)
        XCTAssertEqual(packets[1].1, 520)
        XCTAssertTrue(packets[1].3)
    }

    func test光标离开虚拟屏时只发送一次隐藏状态() {
        let bounds = CGRect(x: 1728, y: 0, width: 1920, height: 1080)
        let tracker = MouseTap(
            virtualDisplayID: 99,
            displayBoundsProvider: { bounds },
            cursorTypeProvider: { .arrow }
        )
        var visibility: [Bool] = []
        tracker.onPosition = { _, _, _, visible in visibility.append(visible) }

        tracker.process(location: CGPoint(x: 1900, y: 400))
        tracker.process(location: CGPoint(x: 500, y: 400))
        tracker.process(location: CGPoint(x: 400, y: 400))

        XCTAssertEqual(visibility, [true, false])
    }

    func test光标类型变化时即使位置不变也会重新上报() {
        let bounds = CGRect(x: 1728, y: 0, width: 1920, height: 1080)
        var currentType: CursorType = .arrow
        let tracker = MouseTap(
            virtualDisplayID: 99,
            displayBoundsProvider: { bounds },
            cursorTypeProvider: { currentType }
        )
        var types: [CursorType] = []
        tracker.onPosition = { _, _, type, _ in types.append(type) }

        let point = CGPoint(x: 1900, y: 400)
        tracker.process(location: point) // 进入虚拟屏，箭头
        tracker.process(location: point) // 同坐标同类型，应被去重，不产生新事件
        currentType = .pointingHand
        tracker.process(location: point) // 坐标没变，但类型变了，仍要上报

        XCTAssertEqual(types, [.arrow, .pointingHand])
    }

    func test分类器能区分箭头手形工字光标的位图指纹() {
        // 三个尺寸/热点来自真机实测：见 CursorClassifier.swift 顶部注释。
        XCTAssertEqual(CursorClassifier.classify(nil), .arrow)
    }
}

import XCTest
@testable import M2MApp

final class DeviceModelReaderTests: XCTestCase {
    func test常见硬件标识会转换为设备名称() {
        XCTAssertEqual(DeviceModelReader.displayName(for: "MacBookPro18,1", fallback: "未知"), "MacBook Pro")
        XCTAssertEqual(DeviceModelReader.displayName(for: "iMac21,1", fallback: "未知"), "iMac")
        XCTAssertEqual(DeviceModelReader.displayName(for: nil, fallback: "接收端"), "接收端")
    }

    func test自动停止选项会转换为正确秒数() {
        XCTAssertNil(IdleStopPreference.never.thresholdSeconds)
        XCTAssertEqual(IdleStopPreference.fiveMinutes.thresholdSeconds, 300)
        XCTAssertEqual(IdleStopPreference.tenMinutes.thresholdSeconds, 600)
        XCTAssertEqual(IdleStopPreference.sixtyMinutes.thresholdSeconds, 3_600)
    }
}

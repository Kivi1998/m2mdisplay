import XCTest
import M2MShared
@testable import M2MSenderCore

final class MediaKeyTapTests: XCTestCase {
    func test识别三个音量键的按下事件() {
        XCTAssertEqual(MediaKeyDecoder.command(data1: (0 << 16) | (0x0A << 8)), .volumeUp)
        XCTAssertEqual(MediaKeyDecoder.command(data1: (1 << 16) | (0x0A << 8)), .volumeDown)
        XCTAssertEqual(MediaKeyDecoder.command(data1: (7 << 16) | (0x0A << 8)), .toggleMute)
    }

    func test忽略按键抬起和非音量键() {
        XCTAssertNil(MediaKeyDecoder.command(data1: (0 << 16) | (0x0B << 8)))
        XCTAssertNil(MediaKeyDecoder.command(data1: (16 << 16) | (0x0A << 8)))
    }
}

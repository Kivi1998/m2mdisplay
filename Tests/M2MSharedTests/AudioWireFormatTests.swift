import XCTest
@testable import M2MShared

final class AudioWireFormatTests: XCTestCase {
    func test线上音频格式是交错Float32双声道48kHz() {
        let format = AudioWireFormat.format
        XCTAssertEqual(format.sampleRate, 48000)
        XCTAssertEqual(format.channelCount, 2)
        XCTAssertTrue(format.isInterleaved)
        XCTAssertEqual(format.commonFormat, .pcmFormatFloat32)
    }
}

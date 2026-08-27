import XCTest
@testable import M2MShared

final class AudioProtocolTests: XCTestCase {
    func test音频包往返编解码() {
        let frames = 120
        let payload = Data(repeating: 0x5A, count: frames * AudioWireFormat.bytesPerFrame)
        let original = AudioPacket(sequence: 42, frameCount: UInt16(frames), payload: payload)

        let encoded = try! XCTUnwrap(original.encoded())
        let decoded = try! XCTUnwrap(AudioPacket.decode(encoded))

        XCTAssertEqual(decoded.sequence, 42)
        XCTAssertEqual(decoded.frameCount, UInt16(frames))
        XCTAssertEqual(decoded.payload, payload)
        XCTAssertLessThan(encoded.count, 1_500)
    }

    func test音频包拒绝长度不一致的数据() {
        let invalid = AudioPacket(sequence: 1, frameCount: 120, payload: Data(repeating: 0, count: 16))
        XCTAssertNil(invalid.encoded())
    }

    func test音量控制包往返编解码() {
        for command in [AudioControlCommand.volumeUp, .volumeDown, .toggleMute] {
            let original = AudioControlPacket(sequence: 7, command: command)
            let decoded = try! XCTUnwrap(AudioControlPacket.decode(original.encoded()))
            XCTAssertEqual(decoded.sequence, 7)
            XCTAssertEqual(decoded.command, command)
        }
    }
}

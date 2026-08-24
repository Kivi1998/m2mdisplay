import XCTest
import Network
import M2MShared
@testable import M2MReceiverCore

final class AudioReceiverTests: XCTestCase {
    func testAudioFrameHeader编解码往返一致() {
        let header = AudioFrameHeader(payloadLength: 4096, presentationTimeNanos: 123_456_789_012)
        let decoded = AudioFrameHeader.decode(header.encoded())
        XCTAssertEqual(decoded?.payloadLength, header.payloadLength)
        XCTAssertEqual(decoded?.presentationTimeNanos, header.presentationTimeNanos)
    }

    func test收到完整的一包音频数据后触发回调() async throws {
        let receiver = AudioReceiver()
        let received = expectation(description: "收到一帧音频")
        var receivedFrame: ReceivedAudioFrame?
        receiver.onFrame = { frame in
            receivedFrame = frame
            received.fulfill()
        }

        let port: UInt16 = 54240
        try receiver.start(port: port)

        let client = NWConnection(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        client.start(queue: .main)

        let payload = Data(repeating: 0x5A, count: 512)
        let header = AudioFrameHeader(payloadLength: UInt32(payload.count), presentationTimeNanos: 42)
        var wire = header.encoded()
        wire.append(payload)
        client.send(content: wire, completion: .contentProcessed { _ in })

        await fulfillment(of: [received], timeout: 3)
        XCTAssertEqual(receivedFrame?.payload, payload)
        XCTAssertEqual(receivedFrame?.header.presentationTimeNanos, 42)

        client.cancel()
        receiver.stop()
    }

    /// 验证半包场景：把一帧数据拆成两次网络写入发出去，drainBuffer() 必须等
    /// 两段都到齐才触发回调，不能在数据不全时提前误报。
    func test拆成两次发送仍能正确拼包() async throws {
        let receiver = AudioReceiver()
        let received = expectation(description: "收到拼接后的完整一帧")
        var receivedFrame: ReceivedAudioFrame?
        receiver.onFrame = { frame in
            receivedFrame = frame
            received.fulfill()
        }

        let port: UInt16 = 54241
        try receiver.start(port: port)

        let client = NWConnection(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        client.start(queue: .main)

        let payload = Data((0..<800).map { UInt8($0 % 256) })
        let header = AudioFrameHeader(payloadLength: UInt32(payload.count), presentationTimeNanos: 7)
        var wire = header.encoded()
        wire.append(payload)

        let splitPoint = wire.count / 2
        let firstHalf = wire.prefix(splitPoint)
        let secondHalf = wire.suffix(from: splitPoint)

        client.send(content: firstHalf, completion: .contentProcessed { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                client.send(content: secondHalf, completion: .contentProcessed { _ in })
            }
        })

        await fulfillment(of: [received], timeout: 3)
        XCTAssertEqual(receivedFrame?.payload, payload)

        client.cancel()
        receiver.stop()
    }
}

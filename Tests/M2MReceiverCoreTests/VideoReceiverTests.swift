import XCTest
import Network
@testable import M2MReceiverCore

final class VideoReceiverTests: XCTestCase {
    func test发送端断开后触发接收端断开回调() async throws {
        let receiver = VideoReceiver()
        let connected = expectation(description: "发送端已连接")
        let disconnected = expectation(description: "发送端已断开")
        var disconnectCount = 0

        receiver.onConnected = {
            connected.fulfill()
        }
        receiver.onDisconnected = {
            disconnectCount += 1
            disconnected.fulfill()
        }

        let port: UInt16 = 54239
        try receiver.start(port: port)

        let client = NWConnection(
            host: .ipv4(.loopback),
            port: NWEndpoint.Port(rawValue: port)!,
            using: .tcp
        )
        client.start(queue: .main)

        await fulfillment(of: [connected], timeout: 3)
        client.cancel()
        await fulfillment(of: [disconnected], timeout: 3)

        XCTAssertEqual(disconnectCount, 1)
        receiver.stop()
    }
}

import CoreGraphics
import XCTest
import Network
import M2MShared
@testable import M2MReceiverCore

final class CursorReceiverTests: XCTestCase {
    func test原生光标隐藏与恢复严格配对() {
        var hiddenDisplayIDs: [CGDirectDisplayID] = []
        var shownDisplayIDs: [CGDirectDisplayID] = []
        let controller = NativeCursorController(
            displayID: 42,
            hideCursor: { displayID in
                hiddenDisplayIDs.append(displayID)
                return .success
            },
            showCursor: { displayID in
                shownDisplayIDs.append(displayID)
                return .success
            }
        )

        controller.hideIfNeeded()
        controller.hideIfNeeded()
        controller.restoreIfNeeded()
        controller.restoreIfNeeded()

        XCTAssertEqual(hiddenDisplayIDs, [42])
        XCTAssertEqual(shownDisplayIDs, [42])
        XCTAssertFalse(controller.didHideCursor)
    }

    func test新的发送会话可以从较小序号重新开始() async throws {
        let receiver = CursorReceiver()
        let firstPacketReceived = expectation(description: "收到第一个会话的光标包")
        let secondPacketReceived = expectation(description: "收到第二个会话的光标包")

        receiver.onCursor = { packet in
            if packet.sequence == 100 {
                firstPacketReceived.fulfill()
            } else if packet.sequence == 1 {
                secondPacketReceived.fulfill()
            }
        }

        let port: UInt16 = 54240
        try receiver.start(port: port)
        receiver.beginSession()

        let firstClient = NWConnection(
            host: .ipv4(.loopback),
            port: NWEndpoint.Port(rawValue: port)!,
            using: .udp
        )
        firstClient.start(queue: .main)
        firstClient.send(
            content: CursorPacket(x: 100, y: 100, cursorType: CursorType.arrow.rawValue, sequence: 100, isVisible: true).encoded(),
            completion: .contentProcessed { _ in }
        )
        await fulfillment(of: [firstPacketReceived], timeout: 3)
        firstClient.cancel()
        receiver.endSession()
        receiver.beginSession()

        let secondClient = NWConnection(
            host: .ipv4(.loopback),
            port: NWEndpoint.Port(rawValue: port)!,
            using: .udp
        )
        secondClient.start(queue: .main)
        secondClient.send(
            content: CursorPacket(x: 200, y: 200, cursorType: CursorType.arrow.rawValue, sequence: 1, isVisible: true).encoded(),
            completion: .contentProcessed { _ in }
        )
        await fulfillment(of: [secondPacketReceived], timeout: 3)

        secondClient.cancel()
        receiver.stop()
    }
}

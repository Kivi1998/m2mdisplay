import Network
import Foundation
import M2MShared

final class VideoSender {
    private let connection: NWConnection
    private var ready = false
    private var pendingReadyContinuations: [CheckedContinuation<Void, Error>] = []

    init(host: String, port: UInt16) {
        let endpoint = NWEndpoint.Host(host)
        let nwPort = NWEndpoint.Port(rawValue: port)!
        // Deliberately not pinning requiredInterfaceType here — we already pin the
        // route by connecting to the fixed 10.10.10.x Thunderbolt Bridge IP directly
        // (see NetworkConfig), which the routing table already sends via bridge0.
        // Forcing an NWInterface.InterfaceType would need to be verified against how
        // Network.framework actually classifies that bridge, and would break the
        // 127.0.0.1 loopback path used for local testing before iMac deployment.
        connection = NWConnection(host: endpoint, port: nwPort, using: .tcp)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            print("[VideoSender] state: \(state)")
            switch state {
            case .ready:
                self.ready = true
                self.pendingReadyContinuations.forEach { $0.resume() }
                self.pendingReadyContinuations.removeAll()
            case .failed(let error):
                self.pendingReadyContinuations.forEach { $0.resume(throwing: error) }
                self.pendingReadyContinuations.removeAll()
            case .waiting:
                // NWConnection does NOT auto-retry the handshake on its own here —
                // .waiting just parks the connection (confirmed: sat there
                // indefinitely after a "Connection refused" until restart() was
                // called). Matters for real daily use: the receiver on the iMac
                // might not be up yet, or a Thunderbolt hiccup drops the link
                // briefly — either should self-heal instead of hanging forever.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                    self?.connection.restart()
                }
            default:
                break
            }
        }
        connection.start(queue: .main)
    }

    func waitUntilReady() async throws {
        if ready { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pendingReadyContinuations.append(continuation)
        }
    }

    func send(_ frame: EncodedFrame) {
        guard ready else { return }
        let header = FrameHeader(
            payloadLength: UInt32(frame.payload.count),
            avcCLength: UInt16(frame.avcC?.count ?? 0),
            presentationTimeNanos: frame.presentationTimeNanos,
            isKeyframe: frame.isKeyframe
        )
        var wire = header.encoded()
        if let avcC = frame.avcC { wire.append(avcC) }
        wire.append(frame.payload)
        sendWithRetry(wire, attemptsLeft: 5)
    }

    // TCP guarantees ordered delivery once bytes are actually accepted onto the
    // socket, but connection.send() itself can transiently fail (observed: ENOTCONN
    // on a handful of the first sends right after a loopback connection reports
    // .ready — some path/setup race, not yet root-caused). A dropped video frame
    // is not acceptable for a tool whose whole point is beating AirPlay's latency
    // with a *more* reliable pipeline, so failures are retried rather than logged
    // and discarded.
    private func sendWithRetry(_ content: Data, attemptsLeft: Int) {
        connection.send(content: content, completion: .contentProcessed { [weak self] error in
            guard let error else { return }
            guard attemptsLeft > 1 else {
                fputs("VideoSender: dropping frame after retries exhausted: \(error)\n", stderr)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.005) {
                self?.sendWithRetry(content, attemptsLeft: attemptsLeft - 1)
            }
        })
    }

    func stop() {
        connection.cancel()
    }
}

final class CursorSender {
    private let connection: NWConnection

    init(host: String, port: UInt16) {
        let endpoint = NWEndpoint.Host(host)
        let nwPort = NWEndpoint.Port(rawValue: port)!
        connection = NWConnection(host: endpoint, port: nwPort, using: .udp)
        connection.start(queue: .main)
    }

    func send(_ packet: CursorPacket) {
        connection.send(content: packet.encoded(), completion: .contentProcessed { _ in })
    }

    func stop() {
        connection.cancel()
    }
}

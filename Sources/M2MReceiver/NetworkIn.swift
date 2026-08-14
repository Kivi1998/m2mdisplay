import Network
import Foundation
import M2MShared

struct ReceivedFrame {
    let header: FrameHeader
    let avcC: Data?
    let payload: Data
}

final class VideoReceiver {
    private var listener: NWListener?
    private var connection: NWConnection?
    private var buffer = Data()
    var onFrame: ((ReceivedFrame) -> Void)?
    var onConnected: (() -> Void)?

    func start(port: UInt16) throws {
        let params = NWParameters.tcp
        let nwPort = NWEndpoint.Port(rawValue: port)!
        let listener = try NWListener(using: params, on: nwPort)
        listener.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            self.connection?.cancel()
            self.buffer.removeAll()
            self.connection = conn
            conn.stateUpdateHandler = { state in
                if state == .ready { self.onConnected?() }
            }
            conn.start(queue: .main)
            self.receiveMore()
        }
        listener.start(queue: .main)
        self.listener = listener
    }

    private func receiveMore() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 262_144) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.drainBuffer()
            }
            if let error {
                fputs("VideoReceiver receive error: \(error)\n", stderr)
                return
            }
            if isComplete { return }
            self.receiveMore()
        }
    }

    private func drainBuffer() {
        while true {
            guard buffer.count >= FrameHeader.byteSize else { return }
            guard let header = FrameHeader.decode(buffer) else { return }
            let needed = FrameHeader.byteSize + Int(header.avcCLength) + Int(header.payloadLength)
            guard buffer.count >= needed else { return }

            var offset = FrameHeader.byteSize
            let avcC: Data? = header.avcCLength > 0 ? buffer.subdata(in: offset..<(offset + Int(header.avcCLength))) : nil
            offset += Int(header.avcCLength)
            let payload = buffer.subdata(in: offset..<(offset + Int(header.payloadLength)))

            onFrame?(ReceivedFrame(header: header, avcC: avcC, payload: payload))
            buffer.removeSubrange(0..<needed)
        }
    }

    func stop() {
        connection?.cancel()
        listener?.cancel()
    }
}

final class CursorReceiver {
    private var listener: NWListener?
    private var lastSequence: UInt32?
    var onCursor: ((CursorPacket) -> Void)?

    func start(port: UInt16) throws {
        let params = NWParameters.udp
        let nwPort = NWEndpoint.Port(rawValue: port)!
        let listener = try NWListener(using: params, on: nwPort)
        listener.newConnectionHandler = { [weak self] conn in
            conn.start(queue: .main)
            self?.receiveDatagram(on: conn)
        }
        listener.start(queue: .main)
        self.listener = listener
    }

    private func receiveDatagram(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, let packet = CursorPacket.decode(data) {
                // Drop stale/out-of-order packets — only the newest position matters.
                // Wraparound-safe comparison: treat sequence numbers as a ring, like TCP does.
                let isNewer = self.lastSequence.map { Int32(bitPattern: packet.sequence &- $0) > 0 } ?? true
                if isNewer {
                    self.lastSequence = packet.sequence
                    self.onCursor?(packet)
                }
            }
            if error == nil {
                self.receiveDatagram(on: connection)
            }
        }
    }

    func stop() {
        listener?.cancel()
    }
}

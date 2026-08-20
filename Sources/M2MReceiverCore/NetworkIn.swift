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
    var onDisconnected: (() -> Void)?

    func start(port: UInt16) throws {
        let params = NWParameters.tcp
        let nwPort = NWEndpoint.Port(rawValue: port)!
        let listener = try NWListener(using: params, on: nwPort)
        listener.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            let previousConnection = self.connection
            self.connection = conn
            self.buffer.removeAll()
            previousConnection?.stateUpdateHandler = nil
            previousConnection?.cancel()
            conn.stateUpdateHandler = { [weak self, weak conn] state in
                guard let self, let conn, self.connection === conn else { return }
                switch state {
                case .ready:
                    self.onConnected?()
                case .failed, .cancelled:
                    self.finishConnection(conn)
                default:
                    break
                }
            }
            conn.start(queue: .main)
            self.receiveMore(on: conn)
        }
        listener.start(queue: .main)
        self.listener = listener
    }

    private func receiveMore(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 262_144) { [weak self, weak connection] data, _, isComplete, error in
            guard let connection else { return }
            guard let self else { return }
            guard self.connection === connection else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.drainBuffer()
            }
            if let error {
                fputs("VideoReceiver receive error: \(error)\n", stderr)
                self.finishConnection(connection)
                return
            }
            if isComplete {
                self.finishConnection(connection)
                return
            }
            self.receiveMore(on: connection)
        }
    }

    private func finishConnection(_ finishedConnection: NWConnection) {
        guard connection === finishedConnection else { return }
        finishedConnection.stateUpdateHandler = nil
        connection = nil
        buffer.removeAll()
        onDisconnected?()
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
        let activeConnection = connection
        connection = nil
        activeConnection?.stateUpdateHandler = nil
        activeConnection?.cancel()
        listener?.cancel()
        listener = nil
        buffer.removeAll()
    }
}

final class CursorReceiver {
    private var listener: NWListener?
    private var connection: NWConnection?
    private var lastSequence: UInt32?
    var onCursor: ((CursorPacket) -> Void)?

    func start(port: UInt16) throws {
        let params = NWParameters.udp
        let nwPort = NWEndpoint.Port(rawValue: port)!
        let listener = try NWListener(using: params, on: nwPort)
        listener.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            let previousConnection = self.connection
            self.connection = conn
            self.lastSequence = nil
            previousConnection?.stateUpdateHandler = nil
            previousConnection?.cancel()
            conn.start(queue: .main)
            self.receiveDatagram(on: conn)
        }
        listener.start(queue: .main)
        self.listener = listener
    }

    private func receiveDatagram(on connection: NWConnection) {
        connection.receiveMessage { [weak self, weak connection] data, _, _, error in
            guard let connection else { return }
            guard let self else { return }
            guard self.connection === connection else { return }
            if let data, let packet = CursorPacket.decode(data) {
                // 丢弃过期或乱序数据包，因为只有最新位置有意义。
                // 使用可安全处理回绕的比较方式，像 TCP 一样把序列号视为环形空间。
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
        let activeConnection = connection
        connection = nil
        activeConnection?.stateUpdateHandler = nil
        activeConnection?.cancel()
        listener?.cancel()
        listener = nil
        lastSequence = nil
    }
}

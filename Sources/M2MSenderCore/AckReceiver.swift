import Network
import Foundation
import M2MShared

final class AckReceiver {
    private var listener: NWListener?
    var onAck: ((UInt32) -> Void)?

    func start(port: UInt16) throws {
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true // 跟 VideoReceiver 一样统一允许端口复用，避免同一类坑
        if let ipOptions = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ipOptions.version = .v4 // 跟 VideoReceiver 一样强制只走 IPv4，避开 IPv6 双栈绑定冲突
        }
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
            if let data, let packet = AckPacket.decode(data) {
                self.onAck?(packet.sequence)
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

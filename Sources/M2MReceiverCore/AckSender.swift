import Network
import Foundation
import M2MShared

final class AckSender {
    private let connection: NWConnection

    init(host: String, port: UInt16) {
        let endpoint = NWEndpoint.Host(host)
        let nwPort = NWEndpoint.Port(rawValue: port)!
        connection = NWConnection(host: endpoint, port: nwPort, using: .udp)
        connection.start(queue: .main)
    }

    func send(_ packet: AckPacket) {
        connection.send(content: packet.encoded(), completion: .contentProcessed { _ in })
    }

    func stop() {
        connection.cancel()
    }
}

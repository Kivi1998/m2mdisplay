import Foundation
import M2MShared
import Network

/// 接收另一台 Mac 发来的正常退出请求。这里使用 TCP 并在确认响应发送完成后才
/// 触发退出，保证发起端能够区分“对端已收到”与“端口根本没有监听”。
final class PeerControlServer {
    private let log = EventLog(role: "control")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var onQuitRequested: (() -> Void)?

    func start(onQuitRequested: @escaping () -> Void) throws {
        guard listener == nil else { return }
        self.onQuitRequested = onQuitRequested

        let port = NWEndpoint.Port(rawValue: NetworkConfig.controlPort)!
        let listener = try NWListener(using: .tcp, on: port)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            let identifier = ObjectIdentifier(connection)
            self.connections[identifier] = connection
            connection.stateUpdateHandler = { [weak self, weak connection] state in
                guard let self, let connection else { return }
                if case .failed = state { self.remove(connection) }
                if case .cancelled = state { self.remove(connection) }
            }
            connection.start(queue: .main)
            self.receiveCommand(on: connection, accumulated: Data())
        }
        listener.start(queue: .main)
        self.listener = listener
        log.write(.info, "双机退出控制正在监听端口 \(NetworkConfig.controlPort)")
    }

    func stop() {
        listener?.cancel()
        listener = nil
        for connection in connections.values {
            connection.stateUpdateHandler = nil
            connection.cancel()
        }
        connections.removeAll()
        onQuitRequested = nil
    }

    private func receiveCommand(on connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256) { [weak self, weak connection] data, _, isComplete, error in
            guard let self, let connection else { return }
            var commandData = accumulated
            if let data { commandData.append(data) }

            if commandData.count > 256 {
                self.remove(connection)
                connection.cancel()
                return
            }

            if commandData.contains(0x0A) || isComplete || error != nil {
                self.handle(commandData, from: connection)
            } else {
                self.receiveCommand(on: connection, accumulated: commandData)
            }
        }
    }

    private func handle(_ data: Data, from connection: NWConnection) {
        guard data == Data(PeerControlProtocol.quitCommand.utf8) else {
            remove(connection)
            connection.cancel()
            return
        }

        connection.send(content: Data(PeerControlProtocol.acknowledgement.utf8), completion: .contentProcessed { [weak self, weak connection] _ in
            guard let self else { return }
            if let connection {
                self.remove(connection)
                connection.cancel()
            }
            self.log.write(.info, "已确认另一台 Mac 的退出请求")
            self.onQuitRequested?()
        })
    }

    private func remove(_ connection: NWConnection) {
        connections.removeValue(forKey: ObjectIdentifier(connection))
    }
}

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
    /// 监听器自己（不是某一条具体连接）异步失败时触发，比如端口没能真正绑定
    /// 成功。之前这里完全没人监听，绑定失败了也不会报错，日志照样打印"监听
    /// 中"——调用方必须把这个接上日志，不能让它继续静默失效。
    var onListenerFailed: ((Error) -> Void)?

    func start(port: UInt16) throws {
        let params = NWParameters.tcp
        // 不指定端口以外的信息时，NWListener 默认双栈绑定（IPv4 + IPv6）。这个
        // 项目从头到尾只用固定的 IPv4 地址（10.10.10.1/10.10.10.2），根本不需要
        // IPv6；已经实测踩过一次真实故障：iMac 的雷雳桥接网卡上有个 IPv6
        // 链路本地地址（fe80::…）的连接卡在 ESTABLISHED 状态（`netstat -an`
        // 能看到，但 `lsof` 找不到对应进程——是内核里的孤儿连接，不是我们的
        // 进程持有的），这会让双栈绑定在异步阶段直接报 "Address already in
        // use"（POSIXErrorCode 48）。而且失败不会报错给调用方，因为下面原来
        // 没有监听"监听器本身"的状态（只监听了每条连接的状态），日志照样打印
        // "监听中"，实际上根本没有真正监听成功——排查时先怀疑过 TIME_WAIT
        // （所以顺手把 allowLocalEndpointReuse 也开了，等价于 SO_REUSEADDR），
        // 但那个连接是 ESTABLISHED 不是 TIME_WAIT，SO_REUSEADDR 语义上就不该
        // 管用，实测也确实没用；真正管用的是把协议栈强制成只走 IPv4，从根上
        // 避开那个 IPv6 冲突。
        params.allowLocalEndpointReuse = true
        if let ipOptions = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ipOptions.version = .v4
        }
        let nwPort = NWEndpoint.Port(rawValue: port)!
        let listener = try NWListener(using: params, on: nwPort)
        listener.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state {
                self?.onListenerFailed?(error)
            }
        }
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
        finishedConnection.cancel()
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

struct ReceivedAudioFrame {
    let header: AudioFrameHeader
    let payload: Data
}

/// 跟 VideoReceiver 同一套 TCP 长度前缀分帧读取的做法（自己维护 buffer 拼包，
/// 同时处理半包和粘包），包头更简单——没有 avcC 那部分。
final class AudioReceiver {
    private var listener: NWListener?
    private var connection: NWConnection?
    private var buffer = Data()
    var onFrame: ((ReceivedAudioFrame) -> Void)?

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
                if case .failed = state { self.finishConnection(conn) }
                if case .cancelled = state { self.finishConnection(conn) }
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
                fputs("AudioReceiver receive error: \(error)\n", stderr)
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
        finishedConnection.cancel()
        connection = nil
        buffer.removeAll()
    }

    private func drainBuffer() {
        while true {
            guard buffer.count >= AudioFrameHeader.byteSize else { return }
            guard let header = AudioFrameHeader.decode(buffer) else { return }
            let needed = AudioFrameHeader.byteSize + Int(header.payloadLength)
            guard buffer.count >= needed else { return }

            let payload = buffer.subdata(in: AudioFrameHeader.byteSize..<needed)
            onFrame?(ReceivedAudioFrame(header: header, payload: payload))
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
    private var acceptingSession = false
    var onCursor: ((CursorPacket) -> Void)?

    func start(port: UInt16) throws {
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true // 跟 VideoReceiver 一样统一允许端口复用，避免同一类坑
        if let ipOptions = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ipOptions.version = .v4 // 跟 VideoReceiver 一样强制只走 IPv4，避开 IPv6 双栈绑定冲突
        }
        let nwPort = NWEndpoint.Port(rawValue: port)!
        let listener = try NWListener(using: params, on: nwPort)
        listener.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            guard self.acceptingSession else {
                conn.cancel()
                return
            }
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

    /// 视频连接建立后才接受该会话的光标包，避免停止投屏后的迟到 UDP 包重新留下
    /// 一个无效对端。每次新会话同时清空序列号，允许发送端从较小序号重新开始。
    func beginSession() {
        endSession()
        acceptingSession = true
    }

    /// 只结束当前光标会话，保留 UDP 监听器等待下一次投屏。
    func endSession() {
        acceptingSession = false
        let activeConnection = connection
        connection = nil
        activeConnection?.stateUpdateHandler = nil
        activeConnection?.cancel()
        lastSequence = nil
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
        endSession()
        listener?.cancel()
        listener = nil
    }
}

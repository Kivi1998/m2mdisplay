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
        // 此处有意不固定 requiredInterfaceType。连接固定的 10.10.10.x 雷雳桥接地址
        // 已经锁定路由，详见 NetworkConfig；路由表会自动通过 bridge0 发送。
        // 若强制指定 NWInterface.InterfaceType，还需要确认 Network.framework 如何归类
        // 该桥接接口，并且会破坏部署到 iMac 前使用的 127.0.0.1 本地回环测试路径。
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
                // NWConnection 不会在这里自动重试握手。.waiting 只会让连接停住；
                // 实测在出现“连接被拒绝”后会无限等待，直到调用 restart()。
                // 日常使用中 iMac 接收端可能尚未启动，雷雳链路也可能短暂中断，
                // 这两种情况都应自动恢复，而不能永久挂起。
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

    // 字节被套接字接收后，TCP 能保证有序交付，但 connection.send() 本身可能短暂失败。
    // 实测本地回环连接刚报告 .ready 后，最初几次发送偶尔会出现 ENOTCONN，
    // 可能存在尚未定位根因的路径或初始化竞争。本工具要用更可靠的流水线降低
    // AirPlay 延迟，因此不能接受直接丢弃视频帧；发送失败时必须重试，而不是只记录日志。
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

/// 跟 VideoSender 同一套 TCP + 定长包头分帧的做法，只是包头更简单（没有
/// avcC/关键帧的概念）。音频是非关键通道：连接失败/一直没就绪时 send() 会
/// 静默丢弃，不影响投屏的视频和光标——听不到声音好过因为音频卡住整个投屏。
final class AudioSender {
    private let connection: NWConnection
    private var ready = false
    private var pendingReadyContinuations: [CheckedContinuation<Void, Error>] = []

    init(host: String, port: UInt16) {
        let endpoint = NWEndpoint.Host(host)
        let nwPort = NWEndpoint.Port(rawValue: port)!
        connection = NWConnection(host: endpoint, port: nwPort, using: .tcp)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            print("[AudioSender] state: \(state)")
            switch state {
            case .ready:
                self.ready = true
                self.pendingReadyContinuations.forEach { $0.resume() }
                self.pendingReadyContinuations.removeAll()
            case .failed(let error):
                self.pendingReadyContinuations.forEach { $0.resume(throwing: error) }
                self.pendingReadyContinuations.removeAll()
            case .waiting:
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

    func send(payload: Data, presentationTimeNanos: UInt64) {
        guard ready else { return }
        let header = AudioFrameHeader(payloadLength: UInt32(payload.count), presentationTimeNanos: presentationTimeNanos)
        var wire = header.encoded()
        wire.append(payload)
        sendWithRetry(wire, attemptsLeft: 3)
    }

    private func sendWithRetry(_ content: Data, attemptsLeft: Int) {
        connection.send(content: content, completion: .contentProcessed { [weak self] error in
            guard let error else { return }
            guard attemptsLeft > 1 else {
                fputs("AudioSender: dropping audio chunk after retries exhausted: \(error)\n", stderr)
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

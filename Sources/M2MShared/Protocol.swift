import Foundation

/// 光标通道：通过 UDP 发送固定长度的二进制数据包。
/// 此处有意不保证可靠传输，因为只有最新位置有意义，不能让新位置排在旧位置之后等待。
public struct CursorPacket {
    public var x: Float32
    public var y: Float32
    public var cursorType: UInt8
    public var sequence: UInt32
    public var isVisible: Bool // false 表示光标已离开虚拟显示器，接收端应隐藏叠加光标

    public init(x: Float32, y: Float32, cursorType: UInt8, sequence: UInt32, isVisible: Bool = true) {
        self.x = x
        self.y = y
        self.cursorType = cursorType
        self.sequence = sequence
        self.isVisible = isVisible
    }

    public static let byteSize = MemoryLayout<Float32>.size * 2 + MemoryLayout<UInt8>.size + MemoryLayout<UInt32>.size + MemoryLayout<UInt8>.size

    public func encoded() -> Data {
        // 必须逐字节手工打包，不能直接复制结构体内存。Swift 会在 `cursorType`
        //（UInt8）与 `sequence`（UInt32）之间插入 3 字节对齐填充；若使用
        // `Data(bytes: &self, count:)`，真实序列号字节会被静默截断，decode()
        // 读到的反而是填充零。这个问题曾导致解码后的序列号总是 2^24 的整数倍，
        // 正是把填充字节当作小端 UInt32 高位读取的典型表现。显式打包可确保
        // 编码和解码共享唯一、明确的字节布局。
        var data = Data(capacity: Self.byteSize)
        var xv = x
        var yv = y
        var ct = cursorType
        var seq = sequence
        var vis: UInt8 = isVisible ? 1 : 0
        data.append(Data(bytes: &xv, count: MemoryLayout<Float32>.size))
        data.append(Data(bytes: &yv, count: MemoryLayout<Float32>.size))
        data.append(Data(bytes: &ct, count: MemoryLayout<UInt8>.size))
        data.append(Data(bytes: &seq, count: MemoryLayout<UInt32>.size))
        data.append(Data(bytes: &vis, count: MemoryLayout<UInt8>.size))
        return data
    }

    public static func decode(_ data: Data) -> CursorPacket? {
        guard data.count >= byteSize else { return nil }
        return data.withUnsafeBytes { raw -> CursorPacket in
            let x = raw.loadUnaligned(fromByteOffset: 0, as: Float32.self)
            let y = raw.loadUnaligned(fromByteOffset: 4, as: Float32.self)
            let cursorType = raw.loadUnaligned(fromByteOffset: 8, as: UInt8.self)
            let sequence = raw.loadUnaligned(fromByteOffset: 9, as: UInt32.self)
            let isVisible = raw.loadUnaligned(fromByteOffset: 13, as: UInt8.self) == 1
            return CursorPacket(x: x, y: y, cursorType: cursorType, sequence: sequence, isVisible: isVisible)
        }
    }
}

public enum CursorType: UInt8 {
    case arrow = 0
    case iBeam = 1
    case pointingHand = 2
    case resizeLeftRight = 3
    case resizeUpDown = 4
    case other = 255
}

/// 视频通道：通过 TCP 发送带长度前缀的视频帧。这里适合使用可靠、有序传输。
/// 雷雳桥接链路实际上几乎不会丢包，因此不需要像 AirPlay 那样为无线网络丢包恢复
/// 配置较大的抖动缓冲区。
public struct FrameHeader {
    public var payloadLength: UInt32
    public var avcCLength: UInt16   // 关键帧携带 VPS、SPS 和 PPS 配置时大于零
    public var presentationTimeNanos: UInt64
    public var isKeyframe: Bool

    public init(payloadLength: UInt32, avcCLength: UInt16, presentationTimeNanos: UInt64, isKeyframe: Bool) {
        self.payloadLength = payloadLength
        self.avcCLength = avcCLength
        self.presentationTimeNanos = presentationTimeNanos
        self.isKeyframe = isKeyframe
    }

    public static let byteSize = MemoryLayout<UInt32>.size + MemoryLayout<UInt16>.size + MemoryLayout<UInt64>.size + MemoryLayout<UInt8>.size

    public func encoded() -> Data {
        var data = Data(capacity: Self.byteSize)
        var len = payloadLength
        var avcCLen = avcCLength
        var ts = presentationTimeNanos
        var kf: UInt8 = isKeyframe ? 1 : 0
        data.append(Data(bytes: &len, count: MemoryLayout<UInt32>.size))
        data.append(Data(bytes: &avcCLen, count: MemoryLayout<UInt16>.size))
        data.append(Data(bytes: &ts, count: MemoryLayout<UInt64>.size))
        data.append(Data(bytes: &kf, count: MemoryLayout<UInt8>.size))
        return data
    }

    public static func decode(_ data: Data) -> FrameHeader? {
        guard data.count >= byteSize else { return nil }
        return data.withUnsafeBytes { raw -> FrameHeader in
            let len = raw.loadUnaligned(fromByteOffset: 0, as: UInt32.self)
            let avcCLen = raw.loadUnaligned(fromByteOffset: 4, as: UInt16.self)
            let ts = raw.loadUnaligned(fromByteOffset: 6, as: UInt64.self)
            let kf = raw.loadUnaligned(fromByteOffset: 14, as: UInt8.self)
            return FrameHeader(payloadLength: len, avcCLength: avcCLen, presentationTimeNanos: ts, isKeyframe: kf == 1)
        }
    }
}

/// 接收端在主线程提交光标图层位置更新后发回发送端，而不是刚收到网络数据时发送。
/// 发送端可使用自己的单机时钟测量“鼠标移动 → 屏幕像素变化”的真实端到端延迟。
/// 因为测量的是往返时间，所以无需同步两台机器的时钟。
public struct AckPacket {
    public var sequence: UInt32

    public init(sequence: UInt32) {
        self.sequence = sequence
    }

    public static let byteSize = MemoryLayout<UInt32>.size

    public func encoded() -> Data {
        var seq = sequence
        return Data(bytes: &seq, count: Self.byteSize)
    }

    public static func decode(_ data: Data) -> AckPacket? {
        guard data.count >= byteSize else { return nil }
        return data.withUnsafeBytes { raw -> AckPacket in
            AckPacket(sequence: raw.loadUnaligned(fromByteOffset: 0, as: UInt32.self))
        }
    }
}

/// 双机之间固定使用的音频格式。两台目标机器的 Core Audio Tap 真机输出均为
/// 48 kHz 双声道 Float32；不做有损压缩，避免编码器额外增加延迟。
public enum AudioWireFormat {
    public static let sampleRate: Double = 48_000
    public static let channelCount = 2
    public static let bytesPerSample = MemoryLayout<Float32>.size
    public static let bytesPerFrame = channelCount * bytesPerSample

    /// 120 帧等于 2.5 ms，连同 12 字节包头仍小于雷雳桥 IPv4 的常规 MTU，
    /// 不会因为一个音频包被拆成多个 IP 分片而平白增加抖动和丢包风险。
    public static let framesPerPacket = 120
    public static let payloadBytesPerPacket = framesPerPacket * bytesPerFrame
}

/// 音频实时数据走 UDP。旧音频即使重传也已经失去意义，所以每个包带序列号，
/// 接收端只接受更新的数据并使用有界缓冲吸收极小的调度抖动。
public struct AudioPacket {
    private static let magic: UInt32 = 0x3141_324D // 内存中的 ASCII：M2A1

    public let sequence: UInt32
    public let frameCount: UInt16
    public let payload: Data

    public init(sequence: UInt32, frameCount: UInt16, payload: Data) {
        self.sequence = sequence
        self.frameCount = frameCount
        self.payload = payload
    }

    public static let headerByteSize = MemoryLayout<UInt32>.size * 2 + MemoryLayout<UInt16>.size * 2

    public func encoded() -> Data? {
        guard frameCount > 0,
              Int(frameCount) <= AudioWireFormat.framesPerPacket,
              payload.count == Int(frameCount) * AudioWireFormat.bytesPerFrame
        else { return nil }

        var magic = Self.magic
        var sequence = sequence
        var frameCount = frameCount
        var reserved: UInt16 = 0
        var data = Data(capacity: Self.headerByteSize + payload.count)
        data.append(Data(bytes: &magic, count: MemoryLayout<UInt32>.size))
        data.append(Data(bytes: &sequence, count: MemoryLayout<UInt32>.size))
        data.append(Data(bytes: &frameCount, count: MemoryLayout<UInt16>.size))
        data.append(Data(bytes: &reserved, count: MemoryLayout<UInt16>.size))
        data.append(payload)
        return data
    }

    public static func decode(_ data: Data) -> AudioPacket? {
        guard data.count >= headerByteSize else { return nil }
        return data.withUnsafeBytes { raw -> AudioPacket? in
            guard raw.loadUnaligned(fromByteOffset: 0, as: UInt32.self) == magic else { return nil }
            let sequence = raw.loadUnaligned(fromByteOffset: 4, as: UInt32.self)
            let frameCount = raw.loadUnaligned(fromByteOffset: 8, as: UInt16.self)
            guard frameCount > 0, Int(frameCount) <= AudioWireFormat.framesPerPacket else { return nil }
            let payloadLength = Int(frameCount) * AudioWireFormat.bytesPerFrame
            guard data.count == headerByteSize + payloadLength else { return nil }
            return AudioPacket(
                sequence: sequence,
                frameCount: frameCount,
                payload: data.subdata(in: headerByteSize..<data.count)
            )
        }
    }
}

public enum AudioControlCommand: UInt8 {
    case volumeUp = 1
    case volumeDown = 2
    case toggleMute = 3
}

/// 音量键是离散操作，不能像实时音频一样容忍丢包，因此使用独立 TCP 通道。
/// 固定长度包同时带序列号，接收端可安全忽略重复命令。
public struct AudioControlPacket {
    private static let magic: UInt32 = 0x3143_324D // 内存中的 ASCII：M2C1

    public let sequence: UInt32
    public let command: AudioControlCommand

    public init(sequence: UInt32, command: AudioControlCommand) {
        self.sequence = sequence
        self.command = command
    }

    public static let byteSize = MemoryLayout<UInt32>.size * 2 + MemoryLayout<UInt8>.size

    public func encoded() -> Data {
        var magic = Self.magic
        var sequence = sequence
        var command = command.rawValue
        var data = Data(capacity: Self.byteSize)
        data.append(Data(bytes: &magic, count: MemoryLayout<UInt32>.size))
        data.append(Data(bytes: &sequence, count: MemoryLayout<UInt32>.size))
        data.append(Data(bytes: &command, count: MemoryLayout<UInt8>.size))
        return data
    }

    public static func decode(_ data: Data) -> AudioControlPacket? {
        guard data.count >= byteSize else { return nil }
        return data.withUnsafeBytes { raw -> AudioControlPacket? in
            guard raw.loadUnaligned(fromByteOffset: 0, as: UInt32.self) == magic,
                  let command = AudioControlCommand(rawValue: raw.loadUnaligned(fromByteOffset: 8, as: UInt8.self))
            else { return nil }
            return AudioControlPacket(
                sequence: raw.loadUnaligned(fromByteOffset: 4, as: UInt32.self),
                command: command
            )
        }
    }
}

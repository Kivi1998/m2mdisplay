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

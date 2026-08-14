import Foundation

/// Cursor channel: fixed-size binary packet over UDP. Deliberately unreliable —
/// only the latest position matters, so we never want to queue behind an old one.
public struct CursorPacket {
    public var x: Float32
    public var y: Float32
    public var cursorType: UInt8
    public var sequence: UInt32
    public var isVisible: Bool // false = cursor left the virtual display, receiver should hide its overlay

    public init(x: Float32, y: Float32, cursorType: UInt8, sequence: UInt32, isVisible: Bool = true) {
        self.x = x
        self.y = y
        self.cursorType = cursorType
        self.sequence = sequence
        self.isVisible = isVisible
    }

    public static let byteSize = MemoryLayout<Float32>.size * 2 + MemoryLayout<UInt8>.size + MemoryLayout<UInt32>.size + MemoryLayout<UInt8>.size

    public func encoded() -> Data {
        // Manual byte-by-byte packing — NOT a raw struct memory copy. Swift inserts
        // 3 bytes of alignment padding between `cursorType` (UInt8) and `sequence`
        // (UInt32), so `Data(bytes: &self, count:)` silently truncates the real
        // sequence bytes and decode() reads padding zeros instead. Bit us once
        // (decoded sequence numbers came out as exact multiples of 2^24 — the
        // signature of reading padding bytes as the high bytes of a little-endian
        // UInt32). Pack explicitly so encode/decode share one unambiguous layout.
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

/// Video channel: length-prefixed frames over TCP. Reliable/ordered is fine here —
/// the Thunderbolt Bridge link is effectively lossless, so we don't pay AirPlay's
/// price of a jitter buffer sized for Wi-Fi loss recovery.
public struct FrameHeader {
    public var payloadLength: UInt32
    public var avcCLength: UInt16   // > 0 only on keyframes carrying fresh SPS/PPS
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

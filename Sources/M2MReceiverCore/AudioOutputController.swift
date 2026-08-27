import CoreAudio
import Foundation
import M2MShared

enum AudioOutputError: LocalizedError {
    case builtInSpeakerNotFound
    case propertyUnavailable(String)
    case coreAudio(String, OSStatus)

    var errorDescription: String? {
        switch self {
        case .builtInSpeakerNotFound:
            return "找不到 iMac 内建扬声器"
        case .propertyUnavailable(let name):
            return "iMac 内建扬声器不支持 \(name) 属性"
        case .coreAudio(let operation, let status):
            return "\(operation)失败（Core Audio 状态码：\(status)）"
        }
    }
}

/// 直接控制 iMac 内建扬声器，不修改系统默认输出设备，也不依赖容易变化的
/// AirPlay 设备 UID。音量步长使用 macOS 常见的 16 级刻度。
final class AudioOutputController {
    let deviceID: AudioDeviceID
    private let step: Float32 = 1.0 / 16.0

    init() throws {
        deviceID = try Self.findBuiltInSpeaker()
    }

    func apply(_ command: AudioControlCommand) throws {
        switch command {
        case .volumeUp:
            let current = try readVolume()
            try setVolume(min(1, current + step))
            try? setMuted(false)
        case .volumeDown:
            let current = try readVolume()
            try setVolume(max(0, current - step))
            try? setMuted(false)
        case .toggleMute:
            try setMuted(!(try readMuted()))
        }
    }

    func readVolume() throws -> Float32 {
        if let value = try readFloat(selector: kAudioDevicePropertyVolumeScalar, element: kAudioObjectPropertyElementMain) {
            return value
        }
        let channelValues = try [1, 2].compactMap {
            try readFloat(selector: kAudioDevicePropertyVolumeScalar, element: AudioObjectPropertyElement($0))
        }
        guard !channelValues.isEmpty else { throw AudioOutputError.propertyUnavailable("音量") }
        return channelValues.reduce(0, +) / Float32(channelValues.count)
    }

    func readMuted() throws -> Bool {
        if let value = try readUInt32(selector: kAudioDevicePropertyMute, element: kAudioObjectPropertyElementMain) {
            return value != 0
        }
        let channelValues = try [1, 2].compactMap {
            try readUInt32(selector: kAudioDevicePropertyMute, element: AudioObjectPropertyElement($0))
        }
        guard !channelValues.isEmpty else { throw AudioOutputError.propertyUnavailable("静音") }
        return channelValues.allSatisfy { $0 != 0 }
    }

    private func setVolume(_ value: Float32) throws {
        if try setFloat(value, selector: kAudioDevicePropertyVolumeScalar, element: kAudioObjectPropertyElementMain) {
            return
        }
        var didSet = false
        for channel in [1, 2] {
            didSet = try setFloat(value, selector: kAudioDevicePropertyVolumeScalar, element: AudioObjectPropertyElement(channel)) || didSet
        }
        if !didSet { throw AudioOutputError.propertyUnavailable("音量") }
    }

    private func setMuted(_ muted: Bool) throws {
        let value: UInt32 = muted ? 1 : 0
        if try setUInt32(value, selector: kAudioDevicePropertyMute, element: kAudioObjectPropertyElementMain) {
            return
        }
        var didSet = false
        for channel in [1, 2] {
            didSet = try setUInt32(value, selector: kAudioDevicePropertyMute, element: AudioObjectPropertyElement(channel)) || didSet
        }
        if !didSet { throw AudioOutputError.propertyUnavailable("静音") }
    }

    private func readFloat(selector: AudioObjectPropertySelector, element: AudioObjectPropertyElement) throws -> Float32? {
        var address = Self.address(selector: selector, element: element)
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
        guard status == noErr else { throw AudioOutputError.coreAudio("读取音量", status) }
        return value
    }

    private func readUInt32(selector: AudioObjectPropertySelector, element: AudioObjectPropertyElement) throws -> UInt32? {
        var address = Self.address(selector: selector, element: element)
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
        guard status == noErr else { throw AudioOutputError.coreAudio("读取静音状态", status) }
        return value
    }

    private func setFloat(_ value: Float32, selector: AudioObjectPropertySelector, element: AudioObjectPropertyElement) throws -> Bool {
        var address = Self.address(selector: selector, element: element)
        guard AudioObjectHasProperty(deviceID, &address) else { return false }
        var settable = DarwinBoolean(false)
        let queryStatus = AudioObjectIsPropertySettable(deviceID, &address, &settable)
        guard queryStatus == noErr else { throw AudioOutputError.coreAudio("检查音量是否可写", queryStatus) }
        guard settable.boolValue else { return false }
        var value = value
        let status = AudioObjectSetPropertyData(deviceID, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
        guard status == noErr else { throw AudioOutputError.coreAudio("设置音量", status) }
        return true
    }

    private func setUInt32(_ value: UInt32, selector: AudioObjectPropertySelector, element: AudioObjectPropertyElement) throws -> Bool {
        var address = Self.address(selector: selector, element: element)
        guard AudioObjectHasProperty(deviceID, &address) else { return false }
        var settable = DarwinBoolean(false)
        let queryStatus = AudioObjectIsPropertySettable(deviceID, &address, &settable)
        guard queryStatus == noErr else { throw AudioOutputError.coreAudio("检查静音是否可写", queryStatus) }
        guard settable.boolValue else { return false }
        var value = value
        let status = AudioObjectSetPropertyData(deviceID, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
        guard status == noErr else { throw AudioOutputError.coreAudio("设置静音", status) }
        return true
    }

    private static func address(
        selector: AudioObjectPropertySelector,
        element: AudioObjectPropertyElement
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element
        )
    }

    private static func findBuiltInSpeaker() throws -> AudioDeviceID {
        var devicesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &devicesAddress, 0, nil, &size
        )
        guard status == noErr else { throw AudioOutputError.coreAudio("读取音频设备列表大小", status) }
        var devices = [AudioDeviceID](
            repeating: AudioDeviceID(kAudioObjectUnknown),
            count: Int(size) / MemoryLayout<AudioDeviceID>.size
        )
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &devicesAddress, 0, nil, &size, &devices
        )
        guard status == noErr else { throw AudioOutputError.coreAudio("读取音频设备列表", status) }

        for device in devices {
            guard try transportType(of: device) == kAudioDeviceTransportTypeBuiltIn,
                  try hasOutputStreams(device)
            else { continue }
            if try uid(of: device) == "BuiltInSpeakerDevice" { return device }
        }
        for device in devices {
            guard try transportType(of: device) == kAudioDeviceTransportTypeBuiltIn,
                  try hasOutputStreams(device)
            else { continue }
            return device
        }
        throw AudioOutputError.builtInSpeakerNotFound
    }

    private static func transportType(of device: AudioDeviceID) throws -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        guard status == noErr else { throw AudioOutputError.coreAudio("读取音频设备类型", status) }
        return value
    }

    private static func hasOutputStreams(_ device: AudioDeviceID) throws -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size)
        guard status == noErr else { throw AudioOutputError.coreAudio("读取输出流", status) }
        return size >= UInt32(MemoryLayout<AudioStreamID>.size)
    }

    private static func uid(of device: AudioDeviceID) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0)
        }
        guard status == noErr else { throw AudioOutputError.coreAudio("读取音频设备标识", status) }
        return value as String
    }
}

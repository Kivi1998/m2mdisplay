import AppKit
import CoreGraphics
import M2MShared

/// 解析 macOS `NX_SUBTYPE_AUX_CONTROL_BUTTONS` 的 data1 字段。把解析拆成纯函数，
/// 可以在没有辅助功能权限的单元测试进程中验证按键映射。
enum MediaKeyDecoder {
    private static let keyDownState = 0x0A
    private static let soundUpKey = 0
    private static let soundDownKey = 1
    private static let muteKey = 7

    static func command(data1: Int) -> AudioControlCommand? {
        let keyCode = (data1 & 0xFFFF_0000) >> 16
        let keyState = (data1 & 0x0000_FF00) >> 8
        guard keyState == keyDownState else { return nil }
        switch keyCode {
        case soundUpKey: return .volumeUp
        case soundDownKey: return .volumeDown
        case muteKey: return .toggleMute
        default: return nil
        }
    }

    static func isVolumeKey(data1: Int) -> Bool {
        let keyCode = (data1 & 0xFFFF_0000) >> 16
        return keyCode == soundUpKey || keyCode == soundDownKey || keyCode == muteKey
    }
}

/// 投屏期间接管 MacBook 的音量加、音量减和静音键。识别到这些键后不再把事件
/// 交给 MacBook 本机，而是通过可靠控制通道修改 iMac 内建扬声器。
final class MediaKeyTap {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    var onCommand: ((AudioControlCommand) -> Void)?

    private static let systemDefinedType = CGEventType(rawValue: 14)!
    private static let auxiliaryControlButtonSubtype: Int16 = 8
    private static let mask: CGEventMask = 1 << systemDefinedType.rawValue

    @discardableResult
    func start() -> Bool {
        guard eventTap == nil else { return true }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: Self.mask,
            callback: Self.callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }
        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        eventTap = nil
        runLoopSource = nil
    }

    private static let callback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let owner = Unmanaged<MediaKeyTap>.fromOpaque(userInfo).takeUnretainedValue()

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = owner.eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        guard type == systemDefinedType,
              let nsEvent = NSEvent(cgEvent: event),
              nsEvent.subtype.rawValue == auxiliaryControlButtonSubtype,
              MediaKeyDecoder.isVolumeKey(data1: nsEvent.data1)
        else {
            return Unmanaged.passUnretained(event)
        }

        if let command = MediaKeyDecoder.command(data1: nsEvent.data1) {
            owner.onCommand?(command)
        }
        // 按下和抬起都吞掉，避免 MacBook 本机音量 HUD 和音量状态跟着变化。
        return nil
    }

    deinit { stop() }
}

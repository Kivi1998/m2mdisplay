import AppKit
import M2MShared

/// 在 iMac 本机合成一次真正的硬件媒体键事件——跟物理按下 F10/F11/F12 时系统
/// 收到的是同一种 NX_SYSDEFINED 系统事件，而不是自己用 CoreAudio 改音量属性。
/// 交给 macOS 自己的音量键处理逻辑去做，音量变化和原生音量条会自动一起出现
/// 在系统真正的位置、真正的样式上，不用我们自己画一份仿制的 UI；也没有公开
/// API 能直接"弹出"那个原生 HUD——它只在收到真实硬件按键事件时才会出现，
/// 这也是为什么必须合成一次看起来一模一样的系统事件，而不是找个接口调它。
///
/// data1 的编码方式是 MediaKeyTap.swift 里 MediaKeyDecoder 解析逻辑的镜像：
/// 高 16 位是键码，接下来一字节是按键状态（0x0A 按下 / 0x0B 抬起）。必须按下
/// 和抬起各发一次，只发按下事件系统不会识别成一次完整的按键。
enum MediaKeySynthesizer {
    private static let soundUpKey: Int32 = 0
    private static let soundDownKey: Int32 = 1
    private static let muteKey: Int32 = 7
    private static let keyDownState = 0x0A
    private static let keyUpState = 0x0B

    static func post(_ command: AudioControlCommand) {
        let keyCode: Int32
        switch command {
        case .volumeUp: keyCode = soundUpKey
        case .volumeDown: keyCode = soundDownKey
        case .toggleMute: keyCode = muteKey
        }
        postKey(keyCode, state: keyDownState, flags: 0xa00)
        postKey(keyCode, state: keyUpState, flags: 0xb00)
    }

    private static func postKey(_ keyCode: Int32, state: Int, flags: UInt) {
        let data1 = (Int(keyCode) << 16) | (state << 8)
        guard let event = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: NSEvent.ModifierFlags(rawValue: flags),
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: data1,
            data2: -1
        ), let cgEvent = event.cgEvent else { return }
        cgEvent.post(tap: .cghidEventTap)
    }
}

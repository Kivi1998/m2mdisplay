import Foundation

enum AudioOutputPreference: String, CaseIterable, Identifiable {
    case sender
    case receiver

    var id: String { rawValue }
    var displayName: String { self == .sender ? "发送端" : "接收端" }
}

/// 记住"投屏时系统声音留在发送端本机、还是转发到接收端播放"这个选择。跟
/// `RoleStore` 一样存 UserDefaults，只在发送端（MacBook）的菜单栏里可见和
/// 生效——接收端不需要知道这个设置，音频转发与否完全由发送端决定。
final class AudioOutputPreferenceStore {
    private let key = "com.m2mdisplay.audioOutputPreference"

    var saved: AudioOutputPreference {
        get { UserDefaults.standard.string(forKey: key).flatMap(AudioOutputPreference.init(rawValue:)) ?? .receiver }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }
}

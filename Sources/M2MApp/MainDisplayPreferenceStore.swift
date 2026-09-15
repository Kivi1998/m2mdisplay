import Foundation

enum MainDisplayPreference: String, CaseIterable, Identifiable {
    case sender
    case receiver

    var id: String { rawValue }
}

/// 记住投屏时由哪台 Mac 承担主显示器。这里只保存角色，不保存临时的
/// CGDirectDisplayID，因为虚拟显示器每次创建都会获得不同 ID。
final class MainDisplayPreferenceStore {
    private let key = "com.m2mdisplay.mainDisplayPreference"

    var saved: MainDisplayPreference {
        get {
            UserDefaults.standard.string(forKey: key)
                .flatMap(MainDisplayPreference.init(rawValue:)) ?? .sender
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }
}

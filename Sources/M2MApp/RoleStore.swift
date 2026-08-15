import Foundation

enum AppRole: String, CaseIterable, Identifiable {
    case sender
    case receiver

    var id: String { rawValue }
    var displayName: String { self == .sender ? "发送端" : "接收端" }
}

/// 记住这台机器在不同启动之间扮演的角色——每台机器有自己独立的
/// UserDefaults，所以 MacBook Pro 和 iMac 天然会分别保存各自的选择。
final class RoleStore {
    private let roleKey = "com.m2mdisplay.role"

    var savedRole: AppRole? {
        get { UserDefaults.standard.string(forKey: roleKey).flatMap(AppRole.init(rawValue:)) }
        set { UserDefaults.standard.set(newValue?.rawValue, forKey: roleKey) }
    }
}

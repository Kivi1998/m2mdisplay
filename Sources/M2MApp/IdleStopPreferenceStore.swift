import Foundation

enum IdleStopPreference: Int, CaseIterable, Identifiable {
    case never = 0
    case fiveMinutes = 5
    case tenMinutes = 10
    case fifteenMinutes = 15
    case thirtyMinutes = 30
    case sixtyMinutes = 60

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .never: "永不"
        case .fiveMinutes: "5 分钟"
        case .tenMinutes: "10 分钟"
        case .fifteenMinutes: "15 分钟"
        case .thirtyMinutes: "30 分钟"
        case .sixtyMinutes: "1 小时"
        }
    }

    var thresholdSeconds: TimeInterval? {
        self == .never ? nil : TimeInterval(rawValue * 60)
    }
}

final class IdleStopPreferenceStore {
    private let key = "com.m2mdisplay.idleStopMinutes"

    var saved: IdleStopPreference {
        get {
            guard UserDefaults.standard.object(forKey: key) != nil else { return .tenMinutes }
            return IdleStopPreference(rawValue: UserDefaults.standard.integer(forKey: key)) ?? .tenMinutes
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }
}

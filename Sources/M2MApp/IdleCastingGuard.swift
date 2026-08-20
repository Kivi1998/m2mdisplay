import CoreGraphics
import Foundation

/// 投屏期间监控系统级空闲时长（鼠标 + 键盘都没有任何输入的累计时间，用的是
/// 屏幕保护程序判断"用户是否空闲"的同一套系统机制 `CGEventSourceSecondsSince
/// LastEventType`），超过阈值就自动停止投屏。
///
/// 不加这个的话，只要还在投屏，接收端为了不让画面被打断会一直申请电源断言
/// 挡住 iMac 休眠（见 `PowerAssertion.swift`）；用户如果忘记手动点"停止投屏"
/// 就去睡觉了，两台 Mac 的屏幕会一直亮着过一整晚。自动停止投屏后，接收端会
/// 走正常的断开流程释放断言，两台机器就能各自按平时设置的时间正常息屏/
/// 进入屏幕保护程序。
///
/// 空闲时长只在发送端（MacBook）这边测——那才是真实用户操作发生的地方；
/// 接收端（iMac）本机输入已经被 `LocalInputGuard` 吞掉，不能反映用户是否
/// 还在场。
final class IdleCastingGuard {
    private var timer: DispatchSourceTimer?
    private let idleThresholdSeconds: TimeInterval
    private let checkIntervalSeconds: TimeInterval
    private let onIdleTimeout: () -> Void

    /// `kCGAnyInputEventType` 是一个涉及类型转换的 C 宏，Swift 不会自动导入，
    /// 用等价的 rawValue 直接构造。
    private static let anyInputEventType = CGEventType(rawValue: UInt32.max)!
    /// 同理用 rawValue 直接构造 `kCGEventSourceStateCombinedSessionState`
    /// （值为 0），避免依赖 Swift 那边具体怎么给这个 C 枚举去前缀命名。
    private static let combinedSessionState = CGEventSourceStateID(rawValue: 0)!

    init(
        idleThresholdSeconds: TimeInterval = 600,
        checkIntervalSeconds: TimeInterval = 30,
        onIdleTimeout: @escaping () -> Void
    ) {
        self.idleThresholdSeconds = idleThresholdSeconds
        self.checkIntervalSeconds = checkIntervalSeconds
        self.onIdleTimeout = onIdleTimeout
    }

    func start() {
        guard timer == nil else { return }
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now() + checkIntervalSeconds, repeating: checkIntervalSeconds)
        source.setEventHandler { [weak self] in self?.checkIdle() }
        timer = source
        source.resume()
    }

    func stop() {
        timer?.setEventHandler {}
        timer?.cancel()
        timer = nil
    }

    private func checkIdle() {
        let idleSeconds = CGEventSource.secondsSinceLastEventType(Self.combinedSessionState, eventType: Self.anyInputEventType)
        if idleSeconds >= idleThresholdSeconds {
            onIdleTimeout()
        }
    }
}

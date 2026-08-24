import IOKit.pwr_mgt
import Foundation

/// 在进程存活期间保持这台 Mac 和显示器唤醒。若没有该断言，macOS 不会知道
/// 屏幕正在被使用，因为画面来自网络，并未操作本机键盘或鼠标。空闲计时器会
/// 因检测不到活动而按计划休眠或锁屏，直接覆盖正在渲染的画面。
final class PowerAssertion {
    private var displayAssertionID: IOPMAssertionID = 0
    private var systemAssertionID: IOPMAssertionID = 0
    private var isActive = false

    func start() -> Bool {
        let reason = "M2MReceiver is displaying a live stream from another Mac" as CFString
        let displayStatus = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason,
            &displayAssertionID
        )
        let systemStatus = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason,
            &systemAssertionID
        )
        isActive = displayStatus == kIOReturnSuccess && systemStatus == kIOReturnSuccess
        return isActive
    }

    func stop() {
        guard isActive else { return }
        IOPMAssertionRelease(displayAssertionID)
        IOPMAssertionRelease(systemAssertionID)
        isActive = false
    }

    deinit {
        stop()
    }

    /// 主动唤醒可能已经因为空闲计时器而黑屏的显示器（公开 IOKit API，不需要任何
    /// 额外权限）。跟上面 start() 里创建的两个断言不是一回事——那两个只能防止
    /// "以后"休眠，对"已经睡着的显示器"完全没有效果，画面照样是黑的；这个才是
    /// 真正能让已经黑屏的显示器重新亮起来的调用，效果等价于物理碰一下鼠标。
    static func wakeDisplay() {
        var assertionID: IOPMAssertionID = 0
        IOPMAssertionDeclareUserActivity(
            "M2MReceiver is about to display an incoming cast" as CFString,
            kIOPMUserActiveLocal,
            &assertionID
        )
    }
}

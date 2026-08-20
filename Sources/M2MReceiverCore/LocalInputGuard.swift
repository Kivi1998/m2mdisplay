import AppKit
import CoreGraphics

/// 投屏期间彻底吞掉 iMac 本机的鼠标事件，而不只是隐藏光标图案。
///
/// 光有 `NativeCursorController` 的 `CGDisplayHideCursor` 不够：iMac 覆盖窗口
/// 是 `ignoresMouseEvents = true`，点击会穿透到下面的桌面/Finder；那些下层
/// 内容处理点击时经常会自己触发系统级的"显示光标"，把已经隐藏的原生箭头重新
/// 弹出来——这是 macOS 的固有行为，不是这个项目的 bug，`CGDisplayHideCursor`
/// 的隐藏状态本来就不保证在点击后继续生效。
///
/// 这里用 `CGEventTap` 在事件真正被派发给任何 App 之前直接吞掉（`.defaultTap`，
/// 不是只能旁听的 `.listenOnly`），点击就不会传到桌面，也就没有谁会去调用那个
/// 显示光标的逻辑，从根上解决"点一下又冒出来"的问题；副作用是投屏期间 iMac
/// 本机的鼠标/触控板对桌面完全不起作用了——这正是这个项目的预期：iMac 只是
/// 显示器，操作应该始终来自 MacBook Pro。
///
/// 只吞鼠标事件，不碰键盘：EscapeHatch 的连按三次 Escape 退出要继续能用。
///
/// 需要"辅助功能"权限（比 MouseTap 当年用的"输入监控"更高一级，因为要能拦截/
/// 吞掉事件，不只是旁听）。创建失败要明确提示用户去哪里加权限，不能静默失效——
/// 失败时投屏本身仍然继续，只是退化回"点一下光标可能短暂重新出现"这个旧行为。
final class LocalInputGuard {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private static let mask: CGEventMask =
        (1 << CGEventType.mouseMoved.rawValue) |
        (1 << CGEventType.leftMouseDown.rawValue) |
        (1 << CGEventType.leftMouseUp.rawValue) |
        (1 << CGEventType.leftMouseDragged.rawValue) |
        (1 << CGEventType.rightMouseDown.rawValue) |
        (1 << CGEventType.rightMouseUp.rawValue) |
        (1 << CGEventType.rightMouseDragged.rawValue) |
        (1 << CGEventType.otherMouseDown.rawValue) |
        (1 << CGEventType.otherMouseUp.rawValue) |
        (1 << CGEventType.otherMouseDragged.rawValue) |
        (1 << CGEventType.scrollWheel.rawValue)

    @discardableResult
    func start() -> Bool {
        guard eventTap == nil else { return true }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: Self.mask,
            callback: { _, _, _, _ in nil }, // 返回 nil：事件到此为止，不再往下游任何 App 派发
            userInfo: nil
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

    deinit { stop() }
}

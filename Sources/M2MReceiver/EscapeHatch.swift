import Foundation
import AppKit

/// 连按三次 Escape 退出。接收端窗口的层级会在视觉上覆盖屏幕中的其他内容，
/// 这是为了让它看起来像真实显示器，而不是普通应用窗口。若没有该出口，
/// 就只能通过 SSH 登录并终止进程，才能返回这台 Mac 原来的画面。
/// 设计为 2 秒内连按三次，而不是按一次 Escape，避免在关闭对话框等正常操作中误触。
final class EscapeHatch {
    private var localMonitor: Any?
    private var pressTimestamps: [CFAbsoluteTime] = []
    private let requiredPresses = 3
    private let windowSeconds: CFAbsoluteTime = 2.0
    private let escapeKeyCode: UInt16 = 53

    func start() -> Bool {
        guard localMonitor == nil else { return true }
        // 接收端会主动成为前台应用，因此使用应用内事件监听即可，不需要辅助功能权限。
        // 忽略按键自动重复，必须由用户真正按下三次 Escape 才会退出。
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if !event.isARepeat {
                self?.handle(keyCode: event.keyCode)
            }
            return event
        }
        return localMonitor != nil
    }

    deinit {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
    }

    private func handle(keyCode: UInt16) {
        guard keyCode == escapeKeyCode else { return }
        let now = CFAbsoluteTimeGetCurrent()
        pressTimestamps.append(now)
        pressTimestamps.removeAll { now - $0 > windowSeconds }
        if pressTimestamps.count >= requiredPresses {
            print("[EscapeHatch] triple-Escape detected, quitting")
            NSApp.terminate(nil)
        }
    }
}

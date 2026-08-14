import CoreGraphics
import Foundation
import AppKit

/// 连按三次 Escape 退出。接收端窗口的层级会在视觉上覆盖屏幕中的其他内容，
/// 这是为了让它看起来像真实显示器，而不是普通应用窗口。若没有该出口，
/// 就只能通过 SSH 登录并终止进程，才能返回这台 Mac 原来的画面。
/// 设计为 2 秒内连按三次，而不是按一次 Escape，避免在关闭对话框等正常操作中误触。
final class EscapeHatch {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var pressTimestamps: [CFAbsoluteTime] = []
    private let requiredPresses = 3
    private let windowSeconds: CFAbsoluteTime = 2.0
    private let escapeKeyCode: Int64 = 53

    func start() -> Bool {
        let mask: CGEventMask = 1 << CGEventType.keyDown.rawValue
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, _, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let hatch = Unmanaged<EscapeHatch>.fromOpaque(refcon).takeUnretainedValue()
                hatch.handle(event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: refcon
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

    private func handle(_ event: CGEvent) {
        guard event.getIntegerValueField(.keyboardEventKeycode) == escapeKeyCode else { return }
        let now = CFAbsoluteTimeGetCurrent()
        pressTimestamps.append(now)
        pressTimestamps.removeAll { now - $0 > windowSeconds }
        if pressTimestamps.count >= requiredPresses {
            print("[EscapeHatch] triple-Escape detected, quitting")
            NSApp.terminate(nil)
        }
    }
}

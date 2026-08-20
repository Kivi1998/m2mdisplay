import CoreGraphics
import Foundation
import ApplicationServices

/// 全局监听真实鼠标光标，并在光标位于虚拟显示器上时上报位置。
/// 这是 iMac 端光标能够即时响应的关键，详见 Protocol.swift 中 CursorPacket 的说明：
/// 位置更新使用独立通道传输，而不是烤进编码后的视频帧。
///
/// 需要“辅助功能”或“输入监控”权限；macOS 不会向无权限进程发送全局鼠标事件。
/// 若监听器创建失败，必须明确提示用户授予哪项权限，不能静默失效。
final class MouseTap {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let virtualDisplayID: CGDirectDisplayID
    private let width: Int
    private let height: Int
    /// 每次光标离开虚拟显示器时，isVisible 只会发送一次 false。
    /// 接收端据此隐藏叠加光标，避免光标移回本机屏幕后仍停留在离开前的位置。
    var onPosition: ((Float, Float, Bool) -> Void)?
    var onSystemInterruption: ((String) -> Void)?
    private var eventCount = 0
    private var isInsideBounds = false

    init(virtualDisplayID: CGDirectDisplayID, width: Int, height: Int) {
        self.virtualDisplayID = virtualDisplayID
        self.width = width
        self.height = height
    }

    func start() -> Bool {
        let mask: CGEventMask = (1 << CGEventType.mouseMoved.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.leftMouseUp.rawValue)
            | (1 << CGEventType.leftMouseDragged.rawValue)
            | (1 << CGEventType.rightMouseDragged.rawValue)

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let mouseTap = Unmanaged<MouseTap>.fromOpaque(refcon).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    mouseTap.reenableAfterSystemInterruption(type)
                    return Unmanaged.passUnretained(event)
                }
                mouseTap.handle(event)
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

    /// macOS 可能因回调超时或一次用户输入临时关闭事件监听。系统会把关闭原因
    /// 作为特殊事件送进同一个回调；若忽略事件类型，后续移动就永远不会再上报，
    /// iMac 只能停留在最后一个箭头位置。
    private func reenableAfterSystemInterruption(_ type: CGEventType) {
        guard let eventTap else { return }
        let reason = type == .tapDisabledByTimeout ? "回调超时" : "用户输入"
        fputs("[MouseTap] 鼠标事件监听被系统关闭（\(reason)），正在重新启用\n", stderr)
        onSystemInterruption?(reason)
        CGEvent.tapEnable(tap: eventTap, enable: true)
    }

    private func handle(_ event: CGEvent) {
        let displayBounds = CGDisplayBounds(virtualDisplayID)
        let location = event.location // 全局点坐标，原点位于主显示器左上角
        eventCount += 1
        if eventCount <= 10 {
            fputs("[MouseTap] event #\(eventCount) at \(location), displayBounds=\(displayBounds)\n", stderr)
        }
        guard displayBounds.contains(location) else {
            if isInsideBounds {
                isInsideBounds = false
                fputs("[MouseTap] LEFT virtual display bounds at \(location)\n", stderr)
                onPosition?(0, 0, false)
            }
            return
        }
        if !isInsideBounds {
            isInsideBounds = true
            fputs("[MouseTap] ENTERED virtual display bounds at \(location)\n", stderr)
        }
        let relX = Float(location.x - displayBounds.origin.x)
        let relY = Float(location.y - displayBounds.origin.y)
        onPosition?(relX, relY, true)
    }

    func stop() {
        if isInsideBounds {
            isInsideBounds = false
            onPosition?(0, 0, false)
        }
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        eventTap = nil
        runLoopSource = nil
    }
}

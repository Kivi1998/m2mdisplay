import AppKit
import CoreGraphics
import Foundation
import M2MShared

/// 定时读取真实鼠标光标，并在光标位于虚拟显示器上时上报位置。
/// 这是 iMac 端光标能够即时响应的关键，详见 Protocol.swift 中 CursorPacket 的说明：
/// 位置更新使用独立通道传输，而不是烤进编码后的视频帧。
///
/// 这里不能使用 CGEventTap。系统可能在左键输入后关闭全局事件监听，导致视频仍在
/// 运行、桌面也能响应鼠标，但 iMac 的叠加箭头永久停在最后位置。直接读取当前位置
/// 不依赖事件监听，也不需要“辅助功能”或“输入监控”权限。
final class MouseTap {
    private var pollingTimer: DispatchSourceTimer?
    private let virtualDisplayID: CGDirectDisplayID
    private let displayBoundsProvider: () -> CGRect
    private let cursorTypeProvider: () -> CursorType
    /// 每次光标离开虚拟显示器时，isVisible 只会发送一次 false。
    /// 接收端据此隐藏叠加光标，避免光标移回本机屏幕后仍停留在离开前的位置。
    var onPosition: ((Float, Float, CursorType, Bool) -> Void)?
    private var isInsideBounds = false
    private var lastReportedLocation: CGPoint?
    private var lastReportedCursorType: CursorType?

    init(
        virtualDisplayID: CGDirectDisplayID,
        displayBoundsProvider: (() -> CGRect)? = nil,
        cursorTypeProvider: (() -> CursorType)? = nil
    ) {
        self.virtualDisplayID = virtualDisplayID
        self.displayBoundsProvider = displayBoundsProvider ?? { CGDisplayBounds(virtualDisplayID) }
        self.cursorTypeProvider = cursorTypeProvider ?? CursorClassifier.currentType
    }

    func start() -> Bool {
        guard pollingTimer == nil else { return true }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(8), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            guard let self, let event = CGEvent(source: nil) else { return }
            self.process(location: event.location)
        }
        pollingTimer = timer
        timer.resume()
        return true
    }

    /// 供轮询器和单元测试共用。相同坐标、相同光标类型不会重复发包；进入、移动、
    /// 光标类型变化（比如原地悬停在链接上时才出现的手形）和离开虚拟屏时才产生
    /// 状态变化，避免 120Hz 定时器制造无意义的网络流量。
    func process(location: CGPoint) {
        let displayBounds = displayBoundsProvider()
        guard displayBounds.contains(location) else {
            if isInsideBounds {
                isInsideBounds = false
                lastReportedLocation = nil
                lastReportedCursorType = nil
                onPosition?(0, 0, .arrow, false)
            }
            return
        }
        let cursorType = cursorTypeProvider()
        guard !isInsideBounds || lastReportedLocation != location || lastReportedCursorType != cursorType else { return }
        isInsideBounds = true
        lastReportedLocation = location
        lastReportedCursorType = cursorType
        let relX = Float(location.x - displayBounds.origin.x)
        let relY = Float(location.y - displayBounds.origin.y)
        onPosition?(relX, relY, cursorType, true)
    }

    func stop() {
        if isInsideBounds {
            isInsideBounds = false
            onPosition?(0, 0, .arrow, false)
        }
        pollingTimer?.setEventHandler {}
        pollingTimer?.cancel()
        pollingTimer = nil
        lastReportedLocation = nil
        lastReportedCursorType = nil
    }
}

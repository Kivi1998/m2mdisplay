// Sources/M2MReceiverCore/ReceiverEngine.swift
import AppKit
import CoreGraphics
import CoreMedia
import M2MShared

public enum ReceiverState: Equatable {
    case idle
    case listening
    case casting
    case error(String)
}

private final class ReceiverWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// 只管理 iMac 本机光标的隐藏计数。实际光标由发送端 ScreenCaptureKit 合成到
/// 视频帧中；这里必须避免 iMac 自己的箭头叠在远端光标上形成“双光标”。
final class NativeCursorController {
    private let displayID: CGDirectDisplayID
    private let hideCursor: (CGDirectDisplayID) -> CGError
    private let showCursor: (CGDirectDisplayID) -> CGError
    private(set) var didHideCursor = false

    init(
        displayID: CGDirectDisplayID,
        hideCursor: @escaping (CGDirectDisplayID) -> CGError = { CGDisplayHideCursor($0) },
        showCursor: @escaping (CGDirectDisplayID) -> CGError = { CGDisplayShowCursor($0) }
    ) {
        self.displayID = displayID
        self.hideCursor = hideCursor
        self.showCursor = showCursor
    }

    @discardableResult
    func hideIfNeeded() -> CGError {
        guard !didHideCursor else { return .success }
        let result = hideCursor(displayID)
        if result == .success { didHideCursor = true }
        return result
    }

    @discardableResult
    func restoreIfNeeded() -> CGError {
        guard didHideCursor else { return .success }
        let result = showCursor(displayID)
        if result == .success { didHideCursor = false }
        return result
    }
}

/// 掌管接收端的覆盖窗口和网络监听。是否投屏是独立的开关（showCast()/hideCast()），
/// 跟窗口/监听器本身（prepareWindow()）分开——窗口只创建一次，默认隐藏，网络监听器
/// 在隐藏/显示之间切换时始终保持存活，这样重新打开投屏不需要发送端重新连接。
public final class ReceiverEngine {
    static let cursorWindowLevel = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)

    public private(set) var state: ReceiverState = .idle {
        didSet { onStateChange?(state) }
    }
    public var onStateChange: ((ReceiverState) -> Void)?

    private let log = EventLog(role: "receiver")
    private var window: NSWindow!
    private var displayView: DisplayView!
    private var cursorWindow: NSWindow!
    private var cursorOverlayView: CursorOverlayView!
    private var nativeCursorController: NativeCursorController!
    private let videoReceiver = VideoReceiver()
    private let cursorReceiver = CursorReceiver()
    private var formatDescription: CMFormatDescription?
    private let cursorSpaceWidth = 1920
    private let cursorSpaceHeight = 1080
    private let videoPixelWidth = 3840
    private let videoPixelHeight = 2160
    private let escapeHatch = EscapeHatch()
    private let powerAssertion = PowerAssertion()
    private let localInputGuard = LocalInputGuard()
    private var immersiveModeEnabled = false
    private var isCasting = false
    private var waitingForFirstFrame = false
    private var ackSender: AckSender?

    public init() {}

    private func physicalScreen() -> NSScreen {
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
            if CGDisplayIsBuiltin(CGDirectDisplayID(number.uint32Value)) != 0 { return screen }
        }
        return NSScreen.main ?? NSScreen.screens[0]
    }

    private func displayID(for screen: NSScreen) -> CGDirectDisplayID {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return CGMainDisplayID()
        }
        return CGDirectDisplayID(number.uint32Value)
    }

    /// 锁屏时 `CGShieldingWindowLevel()` 会返回锁屏遮罩窗口的层级（一个很高的
    /// 数值），没锁屏时返回值很低（不能直接拿来用）；每次显示投屏前都重新查
    /// 一次，跟原来的 .screenSaver 取较大值，这样锁屏状态下窗口能盖在锁屏遮罩
    /// 之上，没锁屏时行为跟之前完全一样。这是苹果公开文档记录的 API，不是私有
    /// 调用。真机验证过一半：一旦触发了真正的登录窗口认证界面（比如用户
    /// 手动执行"锁定屏幕"，或者"锁定屏幕"设置里密码延时不是"永不"），那是
    /// 完全独立的高权限子系统，任何第三方窗口层级都盖不过去，这是苹果刻意
    /// 做的安全边界（防止第三方 App 伪造假密码框钓鱼），不是这里能绕开的。
    /// 这个技巧对"自动空闲触发、且系统设置里密码延时已经改成永不"的场景是否
    /// 真能生效，还没有真机验证过，等测试结果确认。
    private func castingWindowLevel() -> NSWindow.Level {
        let shieldLevel = Int(CGShieldingWindowLevel())
        let baseLevel = NSWindow.Level.screenSaver.rawValue
        return NSWindow.Level(rawValue: max(baseLevel, shieldLevel + 1))
    }

    /// 创建（初始隐藏的）覆盖窗口，并开始监听发送端的连接。App 启动时调用一次即可。
    public func prepareWindow() {
        let screen = physicalScreen()
        let screenFrame = screen.frame
        nativeCursorController = NativeCursorController(displayID: displayID(for: screen))
        window = ReceiverWindow(contentRect: screenFrame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.backgroundColor = .black
        window.isOpaque = true
        window.ignoresMouseEvents = true // 当前部署方式未连接本机输入设备，详见项目说明
        window.collectionBehavior = [.stationary, .ignoresCycle]
        displayView = DisplayView(frame: window.contentView?.bounds ?? screenFrame)
        displayView.autoresizingMask = [.width, .height]
        window.contentView = displayView
        window.setFrame(screenFrame, display: true)
        window.level = .floating
        window.orderOut(nil)

        cursorWindow = ReceiverWindow(contentRect: screenFrame, styleMask: [.borderless], backing: .buffered, defer: false)
        cursorWindow.backgroundColor = .clear
        cursorWindow.isOpaque = false
        cursorWindow.hasShadow = false
        cursorWindow.ignoresMouseEvents = true
        cursorWindow.collectionBehavior = [.stationary, .ignoresCycle]
        cursorOverlayView = CursorOverlayView(frame: cursorWindow.contentView?.bounds ?? screenFrame)
        cursorOverlayView.autoresizingMask = [.width, .height]
        cursorWindow.contentView = cursorOverlayView
        cursorWindow.setFrame(screenFrame, display: true)
        cursorWindow.level = Self.cursorWindowLevel
        cursorWindow.orderOut(nil)

        if escapeHatch.start() {
            log.write(.info, "退出开关已就绪——连按三次 Escape 可隐藏投屏")
        } else {
            log.write(.warning, "退出开关启动失败——只能通过界面按钮或 SSH 隐藏投屏")
        }

        videoReceiver.onConnected = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                // 尽早发起唤醒——留出显示器面板真正亮起来的硬件延迟时间，
                // 等首帧解码完调用 showCast() 时屏幕大概率已经醒了。
                PowerAssertion.wakeDisplay()
                self.formatDescription = nil
                self.displayView.resetVideo()
                self.cursorOverlayView.hideCursor()
                self.waitingForFirstFrame = true
                self.cursorReceiver.beginSession()
                self.ackSender?.stop()
                self.ackSender = AckSender(host: Endpoints.senderHost, port: NetworkConfig.ackPort)
                self.log.write(.info, "发送端已连接，正在等待真实首帧")
            }
        }
        videoReceiver.onDisconnected = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.waitingForFirstFrame = false
                self.cursorReceiver.endSession()
                self.ackSender?.stop()
                self.ackSender = nil
                self.log.write(.info, "发送端已断开，自动恢复 iMac 原生桌面")
                self.hideCast()
            }
        }
        videoReceiver.onFrame = { [weak self] frame in self?.handle(frame) }
        videoReceiver.onListenerFailed = { [weak self] error in
            self?.log.write(.error, "视频监听器异步绑定失败（端口可能被占用/处于 TIME_WAIT）：\(error)")
        }
        cursorReceiver.onCursor = { [weak self] packet in self?.handleCursor(packet) }

        do {
            try videoReceiver.start(port: NetworkConfig.videoPort)
            try cursorReceiver.start(port: NetworkConfig.cursorPort)
            state = .listening
            log.write(.info, "监听中 — 视频端口:\(NetworkConfig.videoPort) 光标端口:\(NetworkConfig.cursorPort)")
        } catch {
            state = .error("监听器启动失败：\(error)")
            log.write(.error, "监听器启动失败：\(error)")
        }
    }

    /// 显示全屏覆盖窗口并进入沉浸模式（隐藏 Dock、菜单栏和 iMac 自己的光标）。
    /// 可重复调用，不会产生副作用。
    public func showCast() {
        guard window != nil else {
            log.write(.error, "showCast() 在 prepareWindow() 之前被调用了")
            return
        }
        guard !isCasting else { return }
        isCasting = true
        immersiveModeEnabled = true
        let level = castingWindowLevel()
        window.level = level
        // 光标覆盖窗口必须始终盖在主投屏窗口之上，否则锁屏遮罩层级一旦超过
        // 原来写死的 .screenSaver + 1，光标就会被投屏画面挡住变得不可见。
        cursorWindow.level = NSWindow.Level(rawValue: level.rawValue + 1)
        NSApp.setActivationPolicy(.accessory)
        window.makeKeyAndOrderFront(nil)
        NSApp.presentationOptions = [.hideDock, .hideMenuBar, .disableCursorLocationAssistance]
        NSApp.activate(ignoringOtherApps: true)
        window.orderFrontRegardless()
        cursorWindow.orderFrontRegardless()
        hideNativeCursorIfNeeded()
        if localInputGuard.start() {
            log.write(.info, "已接管本机鼠标事件，投屏期间 iMac 鼠标不会再穿透到桌面")
        } else {
            log.write(.warning, "接管本机鼠标事件失败——请到系统设置 > 隐私与安全性 > 辅助功能，" +
                      "给 M2M Display 加一次权限；加之前点击 iMac 鼠标可能会让隐藏的原生光标重新出现")
        }
        if powerAssertion.start() {
            log.write(.info, "电源断言已生效")
        } else {
            log.write(.warning, "电源断言启动失败——投屏过程中这台 Mac 可能会休眠/锁屏")
        }
        state = .casting
        log.write(.info, "投屏已显示")
    }

    /// 隐藏覆盖窗口，恢复 iMac 自己的桌面。网络监听器继续保持存活，
    /// 这样重新打开投屏不需要发送端重新连接。可重复调用，不会产生副作用。
    public func hideCast() {
        guard window != nil else {
            log.write(.error, "hideCast() 在 prepareWindow() 之前被调用了")
            return
        }
        displayView.resetVideo()
        cursorOverlayView.hideCursor()
        formatDescription = nil
        guard isCasting else { return }
        isCasting = false
        immersiveModeEnabled = false
        NSApp.presentationOptions = []
        window.orderOut(nil)
        cursorWindow.orderOut(nil)
        localInputGuard.stop()
        showNativeCursorIfNeeded()
        powerAssertion.stop()
        state = .listening
        log.write(.info, "投屏已隐藏")
    }

    public func handleDidBecomeActive() {
        guard window != nil, immersiveModeEnabled else { return }
        let level = castingWindowLevel()
        window.level = level
        cursorWindow.level = NSWindow.Level(rawValue: level.rawValue + 1)
        window.orderFrontRegardless()
        cursorWindow.orderFrontRegardless()
        hideNativeCursorIfNeeded()
    }

    public func handleWillResignActive() {
        guard window != nil, immersiveModeEnabled else { return }
        // 投屏仍在运行时失去激活状态不能恢复 iMac 光标；真正恢复只允许发生在
        // hideCast() 或 shutdown()，否则系统界面切换会产生第二个箭头。
        hideNativeCursorIfNeeded()
    }

    public func shutdown() {
        videoReceiver.stop()
        cursorReceiver.stop()
        ackSender?.stop()
        ackSender = nil
        localInputGuard.stop()
        showNativeCursorIfNeeded()
        NSApp.presentationOptions = []
        powerAssertion.stop()
        cursorWindow?.orderOut(nil)
        log.write(.info, "正在关闭")
    }

    private func handle(_ frame: ReceivedFrame) {
        if let avcC = frame.avcC {
            formatDescription = SampleBufferBuilder.formatDescription(width: videoPixelWidth, height: videoPixelHeight, avcC: avcC)
        }
        guard let formatDescription,
              let sampleBuffer = SampleBufferBuilder.sampleBuffer(payload: frame.payload, formatDescription: formatDescription) else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.displayView.enqueue(sampleBuffer)
            if self.waitingForFirstFrame {
                self.waitingForFirstFrame = false
                self.log.write(.info, "已收到真实首帧，开始显示投屏")
                self.showCast()
            }
        }
    }

    private func handleCursor(_ packet: CursorPacket) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if packet.isVisible {
                let cursorType = CursorType(rawValue: packet.cursorType) ?? .arrow
                self.cursorOverlayView.updateCursor(normalizedX: CGFloat(packet.x) / CGFloat(self.cursorSpaceWidth),
                                                     normalizedY: CGFloat(packet.y) / CGFloat(self.cursorSpaceHeight),
                                                     cursorType: cursorType)
            } else {
                self.cursorOverlayView.hideCursor()
            }
            if self.immersiveModeEnabled { self.hideNativeCursorIfNeeded() }
            self.ackSender?.send(AckPacket(sequence: packet.sequence))
        }
    }

    private func hideNativeCursorIfNeeded() {
        guard immersiveModeEnabled else { return }
        let result = nativeCursorController.hideIfNeeded()
        if result != .success {
            log.write(.warning, "隐藏原生光标失败（结果码：\(result.rawValue)）")
        }
    }

    private func showNativeCursorIfNeeded() {
        guard nativeCursorController != nil else { return }
        let result = nativeCursorController.restoreIfNeeded()
        if result != .success {
            log.write(.warning, "恢复原生光标失败（结果码：\(result.rawValue)）")
        }
    }
}

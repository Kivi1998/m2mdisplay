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

/// 掌管接收端的覆盖窗口和网络监听。是否投屏是独立的开关（showCast()/hideCast()），
/// 跟窗口/监听器本身（prepareWindow()）分开——窗口只创建一次，默认隐藏，网络监听器
/// 在隐藏/显示之间切换时始终保持存活，这样重新打开投屏不需要发送端重新连接。
public final class ReceiverEngine {
    public private(set) var state: ReceiverState = .idle {
        didSet { onStateChange?(state) }
    }
    public var onStateChange: ((ReceiverState) -> Void)?

    private let log = EventLog(role: "receiver")
    private var window: NSWindow!
    private var displayView: DisplayView!
    private let videoReceiver = VideoReceiver()
    private let cursorReceiver = CursorReceiver()
    private var formatDescription: CMFormatDescription?
    private let cursorSpaceWidth = 1920
    private let cursorSpaceHeight = 1080
    private let videoPixelWidth = 3840
    private let videoPixelHeight = 2160
    private let escapeHatch = EscapeHatch()
    private let powerAssertion = PowerAssertion()
    private var immersiveModeEnabled = false
    private var nativeCursorHidden = false
    private var isCasting = false
    private lazy var ackSender = AckSender(host: Endpoints.senderHost, port: NetworkConfig.ackPort)

    public init() {}

    private func physicalScreen() -> NSScreen {
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
            if CGDisplayIsBuiltin(CGDirectDisplayID(number.uint32Value)) != 0 { return screen }
        }
        return NSScreen.main ?? NSScreen.screens[0]
    }

    /// 创建（初始隐藏的）覆盖窗口，并开始监听发送端的连接。App 启动时调用一次即可。
    public func prepareWindow() {
        let screenFrame = physicalScreen().frame
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

        if escapeHatch.start() {
            log.write(.info, "退出开关已就绪——连按三次 Escape 可隐藏投屏")
        } else {
            log.write(.warning, "退出开关启动失败——只能通过界面按钮或 SSH 隐藏投屏")
        }

        videoReceiver.onConnected = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.log.write(.info, "发送端已连接，自动显示投屏")
                self.showCast()
            }
        }
        videoReceiver.onDisconnected = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.log.write(.info, "发送端已断开，自动恢复 iMac 原生桌面")
                self.hideCast()
            }
        }
        videoReceiver.onFrame = { [weak self] frame in self?.handle(frame) }
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
        window.level = .screenSaver
        NSApp.setActivationPolicy(.accessory)
        window.makeKeyAndOrderFront(nil)
        NSApp.presentationOptions = [.hideDock, .hideMenuBar, .disableCursorLocationAssistance]
        NSApp.activate(ignoringOtherApps: true)
        window.orderFrontRegardless()
        hideNativeCursorIfNeeded()
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
        guard isCasting else { return }
        isCasting = false
        immersiveModeEnabled = false
        NSApp.presentationOptions = []
        window.orderOut(nil)
        showNativeCursorIfNeeded()
        powerAssertion.stop()
        state = .listening
        log.write(.info, "投屏已隐藏")
    }

    public func handleDidBecomeActive() {
        guard window != nil, immersiveModeEnabled else { return }
        window.level = .screenSaver
        window.orderFrontRegardless()
        hideNativeCursorIfNeeded()
    }

    public func handleWillResignActive() {
        guard window != nil, immersiveModeEnabled else { return }
        showNativeCursorIfNeeded()
        window.level = .floating
    }

    public func shutdown() {
        showNativeCursorIfNeeded()
        NSApp.presentationOptions = []
        powerAssertion.stop()
        log.write(.info, "正在关闭")
    }

    private func handle(_ frame: ReceivedFrame) {
        if let avcC = frame.avcC {
            formatDescription = SampleBufferBuilder.formatDescription(width: videoPixelWidth, height: videoPixelHeight, avcC: avcC)
        }
        guard let formatDescription,
              let sampleBuffer = SampleBufferBuilder.sampleBuffer(payload: frame.payload, formatDescription: formatDescription) else { return }
        DispatchQueue.main.async { [weak self] in self?.displayView.enqueue(sampleBuffer) }
    }

    private func handleCursor(_ packet: CursorPacket) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if packet.isVisible {
                self.displayView.updateCursor(normalizedX: CGFloat(packet.x) / CGFloat(self.cursorSpaceWidth),
                                               normalizedY: CGFloat(packet.y) / CGFloat(self.cursorSpaceHeight))
            } else {
                self.displayView.hideCursor()
            }
            self.ackSender.send(AckPacket(sequence: packet.sequence))
        }
    }

    private func hideNativeCursorIfNeeded() {
        guard immersiveModeEnabled, !nativeCursorHidden, NSApp.isActive else { return }
        let result = CGDisplayHideCursor(CGMainDisplayID())
        if result == .success {
            nativeCursorHidden = true
        } else {
            log.write(.warning, "隐藏原生光标失败（结果码：\(result.rawValue)）")
        }
    }

    private func showNativeCursorIfNeeded() {
        guard nativeCursorHidden else { return }
        CGDisplayShowCursor(CGMainDisplayID())
        nativeCursorHidden = false
    }
}

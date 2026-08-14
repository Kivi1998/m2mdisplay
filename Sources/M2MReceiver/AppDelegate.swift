import AppKit
import CoreGraphics
import CoreMedia
import M2MShared

private final class ReceiverWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var displayView: DisplayView!
    private let videoReceiver = VideoReceiver()
    private let cursorReceiver = CursorReceiver()
    private var formatDescription: CMFormatDescription?
    // 以下是两个不同概念，很容易误合并为一个变量。曾经因为解码器按 1920×1080
    // 解释实际为 3840×2160 的视频码流，导致画面只显示左上角四分之一并放大铺满屏幕：
    //  - 光标位置计算需要使用“点”。CGDisplayBounds 的单位是点；即使虚拟显示器
    //    的像素模式为 3840×2160，其逻辑尺寸仍为 1920×1080。系统为这些像素选择
    //    2 倍 Retina 点缩放，与 iMac 实际显示方式一致，这也是清晰度提升的关键。
    //  - 视频格式描述必须使用编码后码流的真实像素尺寸。
    private var cursorSpaceWidth = 1920
    private var cursorSpaceHeight = 1080
    private var videoPixelWidth = 3840
    private var videoPixelHeight = 2160
    private let escapeHatch = EscapeHatch()
    private let powerAssertion = PowerAssertion()
    private var immersiveModeEnabled = false
    private var nativeCursorHidden = false
    private let ackSender = AckSender(host: Endpoints.senderHost, port: NetworkConfig.ackPort)

    /// NSScreen.main 返回系统当前认定的主显示器，它可能是虚拟屏幕，例如 Sidecar、
    /// AirPlay 或本应用的另一个实例，而不一定是用户眼前的物理面板。接收端的职责是
    /// 把画面绘制到真实屏幕，因此必须明确选择内建或物理连接的显示器，不能相信
    /// “主显示器”标记。本机回环测试曾遇到已有 AirPlay 会话占用主显示器位置的问题。
    private func physicalScreen() -> NSScreen {
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
            let displayID = CGDirectDisplayID(number.uint32Value)
            if CGDisplayIsBuiltin(displayID) != 0 {
                return screen
            }
        }
        return NSScreen.main ?? NSScreen.screens[0]
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let screenFrame = physicalScreen().frame
        window = ReceiverWindow(contentRect: screenFrame, styleMask: [.borderless], backing: .buffered, defer: false)
        // 先建立不依赖窗口可见性的退出通道，再进入覆盖菜单栏的展示模式。
        // 如果应用内键盘监听意外创建失败，就保留普通浮动窗口，避免用户被锁在
        // 无法退出的全屏画面中。
        let escapeHatchReady = escapeHatch.start()
        if escapeHatchReady {
            immersiveModeEnabled = true
            window.level = .screenSaver
        } else {
            window.level = .floating
        }
        window.backgroundColor = .black
        window.isOpaque = true
        window.ignoresMouseEvents = true // 当前部署方式未连接本机输入设备，详见项目说明
        window.collectionBehavior = [.stationary, .ignoresCycle]
        displayView = DisplayView(frame: window.contentView?.bounds ?? screenFrame)
        displayView.autoresizingMask = [.width, .height]
        window.contentView = displayView
        window.setFrame(screenFrame, display: true)
        NSApp.setActivationPolicy(.accessory)
        window.makeKeyAndOrderFront(nil)

        if escapeHatchReady {
            print("[M2MReceiver] escape hatch armed — triple-tap Escape to quit")
            // hideMenuBar 必须与 hideDock 同时使用。保留进程切换与强制退出能力，
            // 只隐藏接收画面不需要的系统界面，并关闭摇动鼠标放大光标的辅助行为。
            NSApp.presentationOptions = [.hideDock, .hideMenuBar, .disableCursorLocationAssistance]
            NSApp.activate(ignoringOtherApps: true)
            window.orderFrontRegardless()
            hideNativeCursorIfNeeded()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                print("[M2MReceiver] immersive mode active=\(NSApp.isActive) keyWindow=\(self.window.isKeyWindow) windowLevel=\(self.window.level.rawValue) presentationOptions=\(NSApp.currentSystemPresentationOptions.rawValue)")
            }
        } else {
            fputs("[M2MReceiver] WARNING: escape hatch failed to start — menu bar and native cursor will remain available so the receiver can still be exited safely\n", stderr)
        }

        if powerAssertion.start() {
            print("[M2MReceiver] power assertion active — this Mac won't sleep/lock while running")
        } else {
            fputs("[M2MReceiver] WARNING: failed to create power assertion — this Mac may lock/sleep on its normal idle timer\n", stderr)
        }

        videoReceiver.onConnected = {
            print("[M2MReceiver] sender connected")
        }
        videoReceiver.onFrame = { [weak self] frame in
            self?.handle(frame)
        }
        var cursorLogCount = 0
        cursorReceiver.onCursor = { [weak self] packet in
            guard let self else { return }
            cursorLogCount += 1
            if cursorLogCount <= 5 {
                print("[M2MReceiver] cursor #\(cursorLogCount): (\(packet.x), \(packet.y)) seq=\(packet.sequence)")
            }
            DispatchQueue.main.async {
                if packet.isVisible {
                    self.displayView.updateCursor(normalizedX: CGFloat(packet.x) / CGFloat(self.cursorSpaceWidth),
                                                   normalizedY: CGFloat(packet.y) / CGFloat(self.cursorSpaceHeight))
                } else {
                    self.displayView.hideCursor()
                }
                // 主线程提交图层位置更新后发送确认，而不是刚收到网络数据时发送。
                // 该时间点可衡量事件处理与网络往返，但不包含合成器排队和面板扫描。
                self.ackSender.send(AckPacket(sequence: packet.sequence))
            }
        }

        do {
            try videoReceiver.start(port: NetworkConfig.videoPort)
            try cursorReceiver.start(port: NetworkConfig.cursorPort)
            print("[M2MReceiver] listening — video:\(NetworkConfig.videoPort) cursor:\(NetworkConfig.cursorPort)")
        } catch {
            fputs("[M2MReceiver] failed to start listeners: \(error)\n", stderr)
        }
    }

    private var handledCount = 0

    private func handle(_ frame: ReceivedFrame) {
        if let avcC = frame.avcC {
            formatDescription = SampleBufferBuilder.formatDescription(width: videoPixelWidth, height: videoPixelHeight, avcC: avcC)
            print("[M2MReceiver] rebuilt formatDescription from avcC(\(avcC.count) bytes): \(formatDescription != nil ? "ok" : "FAILED")")
        }
        guard let formatDescription else {
            print("[M2MReceiver] dropping frame — no formatDescription yet")
            return
        }
        guard let sampleBuffer = SampleBufferBuilder.sampleBuffer(payload: frame.payload, formatDescription: formatDescription) else {
            print("[M2MReceiver] sampleBuffer() returned nil for a \(frame.payload.count)-byte payload")
            return
        }
        handledCount += 1
        if handledCount <= 3 {
            print("[M2MReceiver] enqueuing frame #\(handledCount), \(frame.payload.count) bytes, keyframe=\(frame.header.isKeyframe)")
        }
        DispatchQueue.main.async { [weak self] in
            self?.displayView.enqueue(sampleBuffer)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationDidBecomeActive(_ notification: Notification) {
        if immersiveModeEnabled {
            window.level = .screenSaver
            window.orderFrontRegardless()
        }
        hideNativeCursorIfNeeded()
    }

    func applicationWillResignActive(_ notification: Notification) {
        showNativeCursorIfNeeded()
        window.level = .floating
    }

    func applicationWillTerminate(_ notification: Notification) {
        showNativeCursorIfNeeded()
        NSApp.presentationOptions = []
        powerAssertion.stop()
    }

    private func hideNativeCursorIfNeeded() {
        guard immersiveModeEnabled, !nativeCursorHidden, NSApp.isActive else { return }
        // Apple 文档说明 display 参数当前不起作用，但调用方通常必须是前台应用。
        // 因此先激活接收端，再保持一次严格配对的隐藏计数，不能定时 Show/Hide 闪烁。
        let result = CGDisplayHideCursor(CGMainDisplayID())
        if result == .success {
            nativeCursorHidden = true
        }
        print("[M2MReceiver] native cursor hidden: \(nativeCursorHidden) (result: \(result.rawValue))")
    }

    private func showNativeCursorIfNeeded() {
        guard nativeCursorHidden else { return }
        CGDisplayShowCursor(CGMainDisplayID())
        nativeCursorHidden = false
    }
}

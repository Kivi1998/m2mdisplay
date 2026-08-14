import AppKit
import CoreGraphics
import CoreMedia
import M2MShared

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
    private var cursorHideTimer: DispatchSourceTimer?
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

    private func physicalDisplayID() -> CGDirectDisplayID {
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
            let displayID = CGDirectDisplayID(number.uint32Value)
            if CGDisplayIsBuiltin(displayID) != 0 {
                return displayID
            }
        }
        return CGMainDisplayID()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let screenFrame = physicalScreen().frame
        window = NSWindow(contentRect: screenFrame, styleMask: [.borderless], backing: .buffered, defer: false)
        // 窗口不再置于真实菜单栏之上。高于 .mainMenu 的层级虽然能遮住菜单栏，
        // 避免出现双菜单栏，但也会使 Mission Control 和 Cmd+Tab 无法切出。
        // 这曾造成真实事故：窗口完全覆盖正在使用的屏幕，除强制重启外没有可见返回方式。
        // 使用 .floating 会保留双菜单栏这一外观问题，但 Mission Control、Cmd+Tab、
        // Cmd+` 等 macOS 常规退出路径仍然有效。除非提供可靠的非视觉终止开关，
        // 否则不得重新提高窗口层级；仅依赖用户看不到说明的快捷键并不可靠。
        window.level = .floating
        window.backgroundColor = .black
        window.isOpaque = true
        window.ignoresMouseEvents = true // 当前部署方式未连接本机输入设备，详见项目说明
        window.collectionBehavior = [.stationary, .ignoresCycle]
        displayView = DisplayView(frame: window.contentView?.bounds ?? screenFrame)
        displayView.autoresizingMask = [.width, .height]
        window.contentView = displayView
        window.setFrame(screenFrame, display: true)
        window.makeKeyAndOrderFront(nil)
        NSApp.setActivationPolicy(.accessory)

        // 当前环境没有连接本地输入设备，因此这台 Mac 的真实光标会停留在上次位置，
        // 并叠在应用渲染的光标之上，形成两个箭头。这里进行全局隐藏，不受焦点应用影响；
        // 退出时必须显式调用 CGDisplayShowCursor，避免本地用户以后使用这台 Mac 时
        // 发现真实指针仍处于隐藏状态。
        //
        // 启动时只隐藏一次并不稳定。显示器重配置或窗口服务器短暂异常后，macOS 可能
        // 自动重新显示真实光标，这是其他全屏或自助终端应用使用 CGDisplayHideCursor 时
        // 也会遇到的系统特性。定时重新确认隐藏状态是常见解决办法，但 Apple 文档说明
        // Hide/Show 使用引用计数；若每次定时器触发都盲目调用 Hide，退出时就需要同样次数
        // 的 Show 才能恢复，单次 Show 会让光标永久不可见。因此每次触发都成对执行
        // Show+Hide，引用计数净变化为零，只用于强制刷新，隐藏深度始终保持为初次 Hide。
        let hideResult = CGDisplayHideCursor(physicalDisplayID())
        print("[M2MReceiver] hid this Mac's own cursor (result: \(hideResult.rawValue))")
        let cursorHideTimer = DispatchSource.makeTimerSource(queue: .main)
        cursorHideTimer.schedule(deadline: .now() + 2, repeating: 2)
        cursorHideTimer.setEventHandler { [weak self] in
            guard let self else { return }
            let id = self.physicalDisplayID()
            CGDisplayShowCursor(id)
            CGDisplayHideCursor(id)
        }
        cursorHideTimer.resume()
        self.cursorHideTimer = cursorHideTimer

        if escapeHatch.start() {
            print("[M2MReceiver] escape hatch armed — triple-tap Escape to quit")
        } else {
            fputs("[M2MReceiver] WARNING: escape hatch failed to start (needs Accessibility permission) — this window will cover the whole screen with no keyboard way out until that's granted\n", stderr)
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

    func applicationWillTerminate(_ notification: Notification) {
        CGDisplayShowCursor(physicalDisplayID()) // 退出后必须恢复真实光标，避免影响本机用户
        powerAssertion.stop()
    }
}

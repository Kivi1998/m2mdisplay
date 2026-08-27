// Sources/M2MSenderCore/SenderEngine.swift
import CoreGraphics
import Foundation
import M2MShared

public enum SenderState: Equatable {
    case idle
    case starting
    case running
    case reconnecting
    case error(String)
    case stopping
}

/// 掌管发送端整条流水线（虚拟显示器、抓屏、编码、网络、鼠标监听）。每次投屏前
/// 创建虚拟显示器，停止投屏时必须销毁它；否则 macOS 仍把第二块屏幕视为在线，
/// 放在那里的 App 窗口就会留在一个看不见也点不到的桌面上。
public final class SenderEngine {
    public private(set) var state: SenderState = .idle {
        didSet { onStateChange?(state) }
    }
    public var onStateChange: ((SenderState) -> Void)?

    private let log = EventLog(role: "sender")
    private var virtualDisplay: VirtualDisplay?
    private var capturer: FrameCapturer?
    private var encoder: VideoEncoder?
    private var videoSender: VideoSender?
    private var cursorSender: CursorSender?
    private var audioSender: AudioSender?
    private var audioControlSender: AudioControlSender?
    private var mouseTap: MouseTap?
    private var mediaKeyTap: MediaKeyTap?
    private var systemAudioCapture: SystemAudioCapture?
    private var ackReceiver: AckReceiver?
    private var cursorSeq: UInt32 = 0
    private var audioSeq: UInt32 = 0
    private var audioControlSeq: UInt32 = 0

    public init() {}

    /// 把真正创建 VirtualDisplay 的过程放到一个独立的后台 Task 里，而不是在调用方
    /// 所在的线程上直接跑。VirtualDisplay.init 内部在 WindowServer 还没注册好自定义
    /// 模式时，会用 Thread.sleep 重试；如果在 @MainActor 上同步调用它（界面就是这么
    /// 调的），sleep 期间会堵住主运行循环，而 WindowServer 那边异步的模式注册看起来
    /// 恰恰需要这个运行循环转起来才能完成：实测在主线程被堵住的情况下连续 5 次全部
    /// 失败，不管重试多少次都不会成功；同样的代码在没有运行循环、纯命令行进程里调用
    /// 却能立刻成功。
    @discardableResult
    public func prepareVirtualDisplay(width: Int, height: Int, backingScale: Int) async -> Bool {
        guard virtualDisplay == nil else { return true }
        log.write(.info, "正在准备虚拟显示器")
        let display = await Task.detached(priority: .userInitiated) {
            VirtualDisplay(
                name: "M2M Display",
                logicalWidth: width,
                logicalHeight: height,
                backingScale: backingScale,
                refreshRate: 60,
                widthMM: 508,
                heightMM: 285
            )
        }.value
        guard let display else {
            state = .error("创建虚拟显示器失败——详见 ~/Library/Logs/M2MDisplay/sender.log")
            log.write(.error, "创建虚拟显示器失败")
            return false
        }
        virtualDisplay = display
        if isErrorState { state = .idle }
        log.write(.info, "虚拟显示器已就绪：看起来像 \(display.logicalWidth)x\(display.logicalHeight)，后备像素 \(display.pixelWidth)x\(display.pixelHeight)")
        return true
    }

    public func start(receiverHost: String) async {
        guard let virtualDisplay else {
            state = .error("虚拟显示器还没准备好——请先调用 prepareVirtualDisplay")
            return
        }
        guard state == .idle else { return }
        state = .starting
        log.write(.info, "正在向 \(receiverHost) 发起投屏")

        let videoSender = VideoSender(host: receiverHost, port: NetworkConfig.videoPort)
        self.videoSender = videoSender
        let cursorSender = CursorSender(host: receiverHost, port: NetworkConfig.cursorPort)
        self.cursorSender = cursorSender

        let mouseTap = MouseTap(virtualDisplayID: virtualDisplay.displayID)
        self.mouseTap = mouseTap
        mouseTap.onPosition = { [weak self] x, y, cursorType, isVisible in
            guard let self else { return }
            self.cursorSeq += 1
            self.cursorSender?.send(CursorPacket(x: x, y: y, cursorType: cursorType.rawValue, sequence: self.cursorSeq, isVisible: isVisible))
        }
        let ackReceiver = AckReceiver()
        self.ackReceiver = ackReceiver
        do {
            try ackReceiver.start(port: NetworkConfig.ackPort)
        } catch {
            log.write(.warning, "确认包接收器启动失败：\(error)")
        }

        _ = mouseTap.start()

        do {
            try await videoSender.waitUntilReady()
        } catch {
            state = .error("视频连接失败：\(error)")
            log.write(.error, "视频连接失败：\(error)")
            teardownTransport()
            await releaseVirtualDisplay()
            return
        }

        // 视频握手成功后，接收端已经打开本次音频会话；这时再建立音频和音量
        // 控制连接，可避免它们抢在视频连接之前到达而被接收端当作迟到包拒绝。
        let audioSender = AudioSender(host: receiverHost, port: NetworkConfig.audioPort)
        self.audioSender = audioSender
        let audioControlSender = AudioControlSender(host: receiverHost, port: NetworkConfig.audioControlPort)
        self.audioControlSender = audioControlSender
        do {
            try await audioSender.waitUntilReady()
            try await audioControlSender.waitUntilReady()
        } catch {
            state = .error("音频连接失败：\(error)")
            log.write(.error, "音频连接失败：\(error)")
            teardownTransport()
            await releaseVirtualDisplay()
            return
        }

        guard await startCapturePipeline(retryCount: 0) else {
            await teardownCapturePipeline()
            teardownTransport()
            await releaseVirtualDisplay()
            return
        }

        guard await startAudioPipeline() else {
            await teardownCapturePipeline()
            await teardownAudioPipeline()
            teardownTransport()
            await releaseVirtualDisplay()
            return
        }
        state = .running
        log.write(.info, "运行中——系统声音由 iMac 内建扬声器播放")
    }

    /// 停止不仅关闭视频和鼠标通道，还要销毁虚拟显示器。WindowServer 会在显示器
    /// 离线时把其上的窗口迁回仍在线的内置屏幕，因此停止后不会留下“幽灵桌面”。
    public func stop() async {
        guard virtualDisplay != nil || state == .running || state == .reconnecting || state == .starting || isErrorState else { return }
        state = .stopping
        log.write(.info, "正在停止（用户操作）")
        await teardownAudioPipeline()
        await teardownCapturePipeline()
        teardownTransport()
        await releaseVirtualDisplay()
        state = .idle
        log.write(.info, "已停止")
    }

    /// 先让光标监听器发送一次“不可见”，再关闭 UDP 和视频连接。反过来关闭会让
    /// 最后的隐藏包来不及发出，接收端只能保留断联前的箭头。
    private func teardownTransport() {
        mouseTap?.stop()
        mediaKeyTap?.stop()
        videoSender?.stop()
        cursorSender?.stop()
        audioSender?.stop()
        audioControlSender?.stop()
        ackReceiver?.stop()
        videoSender = nil
        cursorSender = nil
        audioSender = nil
        audioControlSender = nil
        mouseTap = nil
        mediaKeyTap = nil
        ackReceiver = nil
    }

    /// 销毁接口返回后，WindowServer 仍可能需要几秒才把显示器从活动列表中移除。
    /// `CGDisplayIsOnline` 对已经销毁的虚拟显示器仍可能长期返回真，不能用来判断
    /// 迁移是否完成；这里以活动显示器列表为准，再向界面报告“已停止”。
    private func releaseVirtualDisplay() async {
        guard let displayID = virtualDisplay?.displayID else { return }
        virtualDisplay = nil

        for _ in 0..<300 {
            if !Self.isActiveDisplay(displayID) {
                log.write(.info, "虚拟显示器已销毁，窗口将回到内置屏幕")
                return
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        log.write(.warning, "虚拟显示器销毁后仍在 WindowServer 活动列表中")
    }

    private static func isActiveDisplay(_ displayID: CGDirectDisplayID) -> Bool {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success else { return true }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return true }
        return displays.prefix(Int(count)).contains(displayID)
    }

    private var isErrorState: Bool {
        if case .error = state { return true }
        return false
    }

    /// （重新）创建 ScreenCaptureKit 抓屏流和编码器。投屏运行期间的一次抓屏中断
    /// 只重建这两项；若连续恢复失败，外层会断开网络并销毁虚拟显示器。
    private func startCapturePipeline(retryCount: Int) async -> Bool {
        guard let virtualDisplay else { return false }
        guard let encoder = try? VideoEncoder(width: virtualDisplay.pixelWidth, height: virtualDisplay.pixelHeight, frameRate: 60, averageBitrateBps: 60_000_000) else {
            state = .error("创建编码器失败")
            log.write(.error, "创建编码器失败")
            return false
        }
        self.encoder = encoder
        let capturer = FrameCapturer(displayID: virtualDisplay.displayID, width: virtualDisplay.pixelWidth, height: virtualDisplay.pixelHeight)
        self.capturer = capturer

        encoder.onEncodedFrame = { [weak self] frame in
            self?.videoSender?.send(frame)
        }
        capturer.onFrame = { [weak encoder] sampleBuffer in
            encoder?.encode(sampleBuffer)
        }
        capturer.onStreamStopped = { [weak self] error in
            self?.log.write(.warning, "抓屏流意外中断：\(String(describing: error))")
            self?.recoverFromCaptureStop()
        }

        do {
            try await capturer.start()
            return true
        } catch {
            if retryCount < 3 {
                log.write(.warning, "第 \(retryCount + 1) 次尝试启动抓屏失败：\(error)，正在重试")
                try? await Task.sleep(nanoseconds: 300_000_000)
                return await startCapturePipeline(retryCount: retryCount + 1)
            }
            state = .error("抓屏启动失败：\(error)")
            log.write(.error, "重试 \(retryCount + 1) 次后抓屏仍然启动失败：\(error)")
            return false
        }
    }

    private func teardownCapturePipeline() async {
        await capturer?.stop()
        encoder?.invalidate()
        capturer = nil
        encoder = nil
    }

    /// 先启动音量键转发，再启动带静音策略的系统音频 Tap。Tap 的创建与首次权限
    /// 检查可能阻塞，放到后台任务中，不能冻住菜单栏界面。
    private func startAudioPipeline() async -> Bool {
        let mediaKeyTap = MediaKeyTap()
        mediaKeyTap.onCommand = { [weak self] command in
            guard let self else { return }
            self.audioControlSeq &+= 1
            self.audioControlSender?.send(AudioControlPacket(sequence: self.audioControlSeq, command: command))
        }
        guard mediaKeyTap.start() else {
            state = .error("接管音量键失败——请在系统设置的辅助功能中允许 M2M Display")
            log.write(.error, "接管音量键失败，缺少辅助功能权限")
            return false
        }
        self.mediaKeyTap = mediaKeyTap

        let capture = SystemAudioCapture()
        capture.onFrames = { [weak self] payload, frameCount in
            guard let self else { return }
            self.audioSeq &+= 1
            self.audioSender?.send(AudioPacket(sequence: self.audioSeq, frameCount: frameCount, payload: payload))
        }
        systemAudioCapture = capture
        do {
            try await Task.detached(priority: .userInitiated) {
                try capture.start()
            }.value
            log.write(.info, "系统音频 Tap 已启动，MacBook 本机输出已静音")
            return true
        } catch {
            state = .error("系统音频捕获启动失败：\(error.localizedDescription)")
            log.write(.error, "系统音频捕获启动失败：\(error)")
            return false
        }
    }

    private func teardownAudioPipeline() async {
        mediaKeyTap?.stop()
        mediaKeyTap = nil
        let capture = systemAudioCapture
        systemAudioCapture = nil
        await Task.detached(priority: .userInitiated) {
            capture?.stop()
        }.value
        log.write(.info, "系统音频 Tap 已销毁，MacBook 本机声音已恢复")
    }

    private func recoverFromCaptureStop() {
        guard state == .running else { return } // 如果是用户主动停止的，这时已经收拾过了
        Task {
            state = .reconnecting
            log.write(.info, "正在尝试自动恢复")
            await teardownCapturePipeline()
            if await startCapturePipeline(retryCount: 0) {
                state = .running
                log.write(.info, "已恢复")
            } else {
                await teardownAudioPipeline()
                await teardownCapturePipeline()
                teardownTransport()
                await releaseVirtualDisplay()
                log.write(.error, "抓屏恢复失败，已断开投屏并通知 iMac 恢复原生桌面")
            }
        }
    }
}

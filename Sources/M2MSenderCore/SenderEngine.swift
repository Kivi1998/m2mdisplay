// Sources/M2MSenderCore/SenderEngine.swift
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

/// 掌管发送端整条流水线（虚拟显示器、抓屏、编码、网络、鼠标监听），对外只暴露
/// start()/stop()。虚拟显示器由 prepareVirtualDisplay() 只创建一次并在整个
/// 引擎生命周期内保持存活——为什么每次开始/停止都重新创建是不安全的，见设计文档
/// 里"虚拟显示器生命周期"那一节。
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
    private var mouseTap: MouseTap?
    private var ackReceiver: AckReceiver?
    private var cursorSeq: UInt32 = 0

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

        let mouseTap = MouseTap(virtualDisplayID: virtualDisplay.displayID, width: virtualDisplay.logicalWidth, height: virtualDisplay.logicalHeight)
        self.mouseTap = mouseTap
        mouseTap.onPosition = { [weak self] x, y, isVisible in
            guard let self else { return }
            self.cursorSeq += 1
            self.cursorSender?.send(CursorPacket(x: x, y: y, cursorType: CursorType.arrow.rawValue, sequence: self.cursorSeq, isVisible: isVisible))
        }

        let ackReceiver = AckReceiver()
        self.ackReceiver = ackReceiver
        do {
            try ackReceiver.start(port: NetworkConfig.ackPort)
        } catch {
            log.write(.warning, "确认包接收器启动失败：\(error)")
        }

        if !mouseTap.start() {
            log.write(.warning, "鼠标监听启动失败——缺少输入监控权限")
        }

        do {
            try await videoSender.waitUntilReady()
        } catch {
            state = .error("视频连接失败：\(error)")
            log.write(.error, "视频连接失败：\(error)")
            return
        }

        guard await startCapturePipeline(retryCount: 0) else { return }
        state = .running
        log.write(.info, "运行中")
    }

    /// 把 guard 条件放宽到也接受 `.starting`，意味着在开始过程中调用 stop() 会把
    /// 已经分配好的资源收拾掉，而不是静默空跑——但它并不会取消正在进行中的异步工作
    /// （比如一次尚未完成的 videoSender.waitUntilReady()），那部分之后仍可能返回、
    /// 短暂地把状态又设回去。这在本计划实际用到的调用方式下不是问题：命令行版本
    /// 从不调用 stop()，图形界面在调用点上把开始/停止串行化了，不会同时触发。要真正
    /// 修好需要给 start() 包一个可取消的 Task 句柄——如果以后有调用方真的需要，再补。
    public func stop() async {
        guard state == .running || state == .reconnecting || state == .starting || isErrorState else { return }
        state = .stopping
        log.write(.info, "正在停止（用户操作）")
        await teardownCapturePipeline()
        videoSender?.stop()
        cursorSender?.stop()
        mouseTap?.stop()
        ackReceiver?.stop()
        videoSender = nil
        cursorSender = nil
        mouseTap = nil
        ackReceiver = nil
        state = .idle
        log.write(.info, "已停止")
    }

    private var isErrorState: Bool {
        if case .error = state { return true }
        return false
    }

    /// （重新）创建 ScreenCaptureKit 抓屏流和编码器。start() 和下面的意外中断恢复
    /// 逻辑都会调用它——这两处是抓屏失败之后唯一需要重建的部分，虚拟显示器和网络
    /// 连接都不受影响、原样保留。
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

    private func recoverFromCaptureStop() {
        guard state == .running else { return } // 如果是用户主动停止的，这时已经收拾过了
        Task {
            state = .reconnecting
            log.write(.info, "正在尝试自动恢复")
            await teardownCapturePipeline()
            if await startCapturePipeline(retryCount: 0) {
                state = .running
                log.write(.info, "已恢复")
            }
        }
    }
}

import CGVirtualDisplayShim
import Foundation
import ScreenCaptureKit
import M2MShared
import AppKit
import CoreImage

setvbuf(stdout, nil, _IOLBF, 0)

signal(SIGINT) { _ in
    print("\nCaught SIGINT, exiting")
    exit(0)
}

// 进程生命周期持有器。抓屏流、网络连接和事件监听器等需要持续运行的对象，
// 必须由生命周期长于下方 `Task` 闭包的对象持有。闭包内的局部 `let` 会在同步
// 初始化代码执行完毕后立即释放，曾导致 SCStream 在输出第一帧前被静默销毁；
// 控制台确认信息为“stopping a deallocated stream that is still running”。
// 全局 `var` 与进程同寿命，将对象保存到这里才能真正保持运行。
var keepAliveVirtualDisplay: VirtualDisplay?
var keepAliveCapturer: FrameCapturer?
var keepAliveEncoder: VideoEncoder?
var keepAliveVideoSender: VideoSender?
var keepAliveCursorSender: CursorSender?
var keepAliveMouseTap: MouseTap?
var keepAliveAckReceiver: AckReceiver?

// 所有异步逻辑都放在这个 Task 中。若在 main.swift 顶层使用 `await`，整个文件会成为
// 隐式异步入口；在该上下文中调用“永久运行”的阻塞原语，会触发 libdispatch 自检崩溃：
// “dispatch_main called from a block on the main queue”。跨设备测试曾在运行一段时间后
// 因此退出。将初始化保留在普通 Task 中，并让永久运行调用成为唯一真正同步的顶层语句，
// 才符合运行时要求。
Task {
    do {
        let receiverHost = Endpoints.receiverHost
        print("Target receiver: \(receiverHost) (video:\(NetworkConfig.videoPort) cursor:\(NetworkConfig.cursorPort))")

        // 桌面布局和文字尺寸保持为 1920×1080。backingScale=2 只让每个逻辑点
        // 使用 2×2 Retina 像素网格，不会缩小窗口或文字。
        guard let virtualDisplay = VirtualDisplay(
            name: "M2M Display",
            logicalWidth: 1920,
            logicalHeight: 1080,
            backingScale: 2,
            refreshRate: 60,
            widthMM: 508,
            heightMM: 285
        ) else {
            fputs("Failed to create virtual display\n", stderr)
            exit(1)
        }
        keepAliveVirtualDisplay = virtualDisplay
        print("Created virtual display, CGDirectDisplayID = \(virtualDisplay.displayID), looks like \(virtualDisplay.logicalWidth)x\(virtualDisplay.logicalHeight), backing pixels \(virtualDisplay.pixelWidth)x\(virtualDisplay.pixelHeight)")

        let capturer = FrameCapturer(displayID: virtualDisplay.displayID, width: virtualDisplay.pixelWidth, height: virtualDisplay.pixelHeight)
        keepAliveCapturer = capturer
        // 10 Mbps 编码 1080p60 桌面内容时明显模糊。密集文字和锐利界面边缘
        // 比自然视频更难压缩，因此大幅提高码率。雷雳桥接链路拥有数十 Gbps 余量，
        // 从未接近网络瓶颈。
        let encoder = try VideoEncoder(width: virtualDisplay.pixelWidth, height: virtualDisplay.pixelHeight, frameRate: 60, averageBitrateBps: 60_000_000)
        keepAliveEncoder = encoder
        let videoSender = VideoSender(host: receiverHost, port: NetworkConfig.videoPort)
        keepAliveVideoSender = videoSender
        let cursorSender = CursorSender(host: receiverHost, port: NetworkConfig.cursorPort)
        keepAliveCursorSender = cursorSender

        var rawFrames = 0
        var encodedFrames = 0
        encoder.onEncodedFrame = { frame in
            encodedFrames += 1
            if encodedFrames <= 3 { print("encoded frame #\(encodedFrames), \(frame.payload.count) bytes") }
            videoSender.send(frame)
        }
        capturer.onFrame = { sampleBuffer in
            rawFrames += 1
            if rawFrames == 60, let pb = sampleBuffer.imageBuffer {
                // 一次性保存基准帧：内容与编码器收到的数据完全一致，且尚未经过视频压缩。
                // 该帧用于判断画质损失发生在编码、解码，还是接收端最终渲染与合成阶段。
                let ciImage = CIImage(cvPixelBuffer: pb)
                let ctx = CIContext()
                if let cgImage = ctx.createCGImage(ciImage, from: ciImage.extent) {
                    let rep = NSBitmapImageRep(cgImage: cgImage)
                    if let data = rep.representation(using: .png, properties: [:]) {
                        try? data.write(to: URL(fileURLWithPath: "/tmp/m2m_raw_capture.png"))
                        print("dumped raw pre-encode frame to /tmp/m2m_raw_capture.png")
                    }
                }
            }
            if rawFrames <= 3, let pb = sampleBuffer.imageBuffer {
                print("captured raw frame #\(rawFrames): \(CVPixelBufferGetWidth(pb))x\(CVPixelBufferGetHeight(pb)) pixels")
            }
            encoder.encode(sampleBuffer)
        }
        capturer.onStreamStopped = { error in
            print("Stream stopped: \(String(describing: error))")
        }

        // 鼠标跟踪不依赖视频通道，应独立启动，不能被视频握手阻塞。
        var cursorSeq: UInt32 = 0
        var sentAt: [UInt32: CFAbsoluteTime] = [:]
        var latenciesMs: [Double] = []
        let mouseTap = MouseTap(virtualDisplayID: virtualDisplay.displayID, width: virtualDisplay.logicalWidth, height: virtualDisplay.logicalHeight)
        keepAliveMouseTap = mouseTap
        mouseTap.onPosition = { x, y, isVisible in
            cursorSeq += 1
            sentAt[cursorSeq] = CFAbsoluteTimeGetCurrent()
            cursorSender.send(CursorPacket(x: x, y: y, cursorType: CursorType.arrow.rawValue, sequence: cursorSeq, isVisible: isVisible))
        }

        // 测量“鼠标移动 → iMac 完成渲染 → 确认返回”的往返时间。
        // 全程使用发送端单机时钟，无需跨设备时钟同步；该数值是真实端到端延迟，
        // 而不是单纯的网络延迟。
        let ackReceiver = AckReceiver()
        keepAliveAckReceiver = ackReceiver
        ackReceiver.onAck = { sequence in
            guard let t0 = sentAt.removeValue(forKey: sequence) else { return }
            let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            latenciesMs.append(ms)
            if latenciesMs.count <= 30 || latenciesMs.count % 25 == 0 {
                let sorted = latenciesMs.sorted()
                let avg = latenciesMs.reduce(0, +) / Double(latenciesMs.count)
                let p50 = sorted[sorted.count / 2]
                let p95 = sorted[Int(Double(sorted.count - 1) * 0.95)]
                print(String(format: "[Latency] n=%d  last=%.2fms  avg=%.2fms  p50=%.2fms  p95=%.2fms  min=%.2fms  max=%.2fms",
                              latenciesMs.count, ms, avg, p50, p95, sorted.first ?? 0, sorted.last ?? 0))
            }
            // 限制集合增长，避免长时间运行时泄漏内存。只有确认包丢失时 sentAt
            // 才会积累；光标通道采用“最新位置优先”语义，因此这种情况很少出现，
            // 直接清理也不会影响正确性。
            if sentAt.count > 200 { sentAt.removeAll() }
        }
        try? ackReceiver.start(port: NetworkConfig.ackPort)
        if mouseTap.start() {
            print("Mouse tap active — tracking cursor over the virtual display")
        } else {
            fputs("""
            Failed to start the global mouse tap — this process needs Accessibility permission.
            Grant it under System Settings > Privacy & Security > Accessibility (or Input Monitoring),
            then restart M2MSender. Continuing without cursor tracking for now.

            """, stderr)
        }

        print("Connecting video channel to \(receiverHost):\(NetworkConfig.videoPort)...")
        try await videoSender.waitUntilReady()
        print("Video channel connected")

        // 在 SCShareableContent 枚举前，给窗口服务器一点时间注册新显示器。
        for attempt in 1...10 {
            do {
                try await capturer.start()
                print("Capture started")
                break
            } catch {
                print("Capture start attempt \(attempt) failed: \(error). Retrying...")
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }

        print("Running. Move the mouse onto the virtual display; Ctrl+C to quit.")
    } catch {
        fputs("Fatal error during startup: \(error)\n", stderr)
        exit(1)
    }
}

// dispatchMain() 只驱动主 GCD 队列，无法处理 CGEventTap 的运行循环源。
// MouseTap 中通过 CFRunLoopAddSource(CFRunLoopGetMain(), ...) 添加的监听源因此得不到服务：
// 监听器可以正常创建，IOHIDCheckAccess 也显示已授予输入监控权限，但自从为解决早期
// libdispatch 崩溃而用 dispatchMain() 替换 RunLoop.main.run() 后，每次运行都收不到鼠标事件。
// CFRunLoopRun() 会直接驱动 CFRunLoopGetMain()；在主线程运行时，主 GCD 队列本身也通过
// CFRunLoop 获得服务，因此两者可以同时工作，且不会重新引入原崩溃。原问题来自在隐式异步
// 上下文中调用阻塞函数，而不是某个特定阻塞函数本身。
CFRunLoopRun()

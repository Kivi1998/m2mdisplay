import AppKit
import AVFoundation
import QuartzCore

final class DisplayView: NSView {
    let videoLayer = AVSampleBufferDisplayLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setupLayers()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        setupLayers()
    }

    private func setupLayers() {
        guard let rootLayer = layer else { return }
        rootLayer.backgroundColor = NSColor.black.cgColor

        // 手工添加的子图层即使位于 Retina 窗口中，也会默认使用 1 倍比例。
        // 视图使用 iMac 当前的逻辑屏幕尺寸，同时以窗口的 Retina 比例合成到后备缓冲区；
        // 否则解码后的 Retina 帧会在 macOS 输出到 iMac 面板前被降采样。
        let scale = window?.backingScaleFactor ?? 2.0
        videoLayer.contentsScale = scale

        videoLayer.videoGravity = .resize
        videoLayer.frame = rootLayer.bounds
        videoLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        rootLayer.addSublayer(videoLayer)

    }

    /// 每个新连接都必须清掉上一会话的最后一帧。否则发送端刚连上但尚未送来新
    /// 画面时，接收端可能短暂显示一张已经过期的桌面，看起来像投屏卡死。
    func resetVideo() {
        videoLayer.flushAndRemoveImage()
        enqueueCount = 0
    }

    private var enqueueCount = 0

    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        if videoLayer.status == .failed {
            print("[DisplayView] layer failed before enqueue: \(String(describing: videoLayer.error)) — flushing")
            videoLayer.flush()
        }
        videoLayer.enqueue(sampleBuffer)
        enqueueCount += 1
        if enqueueCount <= 5 {
            print("[DisplayView] enqueued #\(enqueueCount), layer.status=\(videoLayer.status.rawValue) isReadyForMoreMediaData=\(videoLayer.isReadyForMoreMediaData) frame=\(videoLayer.frame) bounds=\(bounds)")
        }
    }

    override func layout() {
        super.layout()
        videoLayer.frame = layer?.bounds ?? .zero
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let scale = window?.backingScaleFactor else { return }
        videoLayer.contentsScale = scale
    }

}

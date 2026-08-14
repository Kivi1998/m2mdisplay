import AppKit
import AVFoundation
import QuartzCore

final class DisplayView: NSView {
    let videoLayer = AVSampleBufferDisplayLayer()
    private let cursorLayer = CALayer()
    private var cursorVisible = false

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
        cursorLayer.contentsScale = scale

        videoLayer.videoGravity = .resize
        videoLayer.frame = rootLayer.bounds
        videoLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        rootLayer.addSublayer(videoLayer)

        // 使用真实的系统指针位图，而不是手绘近似图形。
        // NSCursor.arrow.image 是 AppKit 自带资源，与用户在其他位置看到的指针逐像素一致。
        let cursorImage = NSCursor.arrow.image
        let hotSpot = NSCursor.arrow.hotSpot
        var imageRect = CGRect(origin: .zero, size: cursorImage.size)
        if let cgImage = cursorImage.cgImage(forProposedRect: &imageRect, context: nil, hints: nil) {
            cursorLayer.contents = cgImage
        }
        cursorLayer.bounds = CGRect(origin: .zero, size: cursorImage.size)
        // NSCursor.hotSpot 使用左上角为原点、Y 轴向下的坐标系，这是经典 Mac OS
        // 光标资源遗留的约定；CALayer.anchorPoint 的 Y 轴则从左下角向上。
        // 两者转换时必须翻转 Y 轴。方向写反不会破坏光标跟踪，位置数据仍然正确，
        // 但渲染出的指针尖端会偏离真实点击点数个点，足以错过标签页关闭按钮等小目标。
        // 过去报告的“点击落点错误”实际由此引起，并不是跟踪逻辑的问题。
        cursorLayer.anchorPoint = CGPoint(x: hotSpot.x / cursorImage.size.width,
                                           y: 1 - hotSpot.y / cursorImage.size.height)
        cursorLayer.isHidden = true
        cursorLayer.zPosition = 10
        rootLayer.addSublayer(cursorLayer)
    }

    /// 使用归一化坐标更新光标位置。坐标范围为 0...1，原点位于左上角，
    /// 与发送端鼠标监听器上报的坐标系一致。整个操作关闭隐式动画；该路径不能继承
    /// 任何缓动或动画时长，因为这里的平滑处理会重新引入本项目要消除的延迟。
    func updateCursor(normalizedX: CGFloat, normalizedY: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let bounds = videoLayer.frame
        cursorLayer.position = CGPoint(x: bounds.minX + normalizedX * bounds.width,
                                        y: bounds.minY + (1 - normalizedY) * bounds.height)
        if !cursorVisible {
            cursorLayer.isHidden = false
            cursorVisible = true
        }
        CATransaction.commit()
    }

    /// 只有真实光标位于虚拟显示器上时，鼠标监听器才会上报位置。
    /// 当光标移回 MacBook 自带屏幕时隐藏叠加光标，避免它停留在离开前的边缘位置。
    func hideCursor() {
        guard cursorVisible else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cursorLayer.isHidden = true
        cursorVisible = false
        CATransaction.commit()
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
        cursorLayer.contentsScale = scale
    }

}

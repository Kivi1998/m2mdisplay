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

    /// 手绘一个经典 macOS 箭头形状（黑色填充、白色描边）到一张小 CGImage 上。
    /// 尖端在返回的点坐标空间里位于 (0,0)，跟真实系统箭头的 NSCursor.hotSpot
    /// 位置约定一致——为什么不直接用系统箭头，见 setupLayers() 里的说明。
    private static func makeArrowCursorImage() -> (image: CGImage, size: CGSize, hotSpot: CGPoint) {
        let size = CGSize(width: 16, height: 22)
        let scale: CGFloat = 2
        let pixelWidth = Int(size.width * scale)
        let pixelHeight = Int(size.height * scale)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        // 翻转成左上角为原点、Y 轴向下的点坐标空间（按给定倍率），
        // 这样下面的绘制坐标才能跟本文件其他地方用的 hotSpot 约定对上。
        context.translateBy(x: 0, y: CGFloat(pixelHeight))
        context.scaleBy(x: scale, y: -scale)

        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: 0, y: 16))
        path.addLine(to: CGPoint(x: 4, y: 12.5))
        path.addLine(to: CGPoint(x: 6.5, y: 18))
        path.addLine(to: CGPoint(x: 9, y: 17))
        path.addLine(to: CGPoint(x: 6.5, y: 11.5))
        path.addLine(to: CGPoint(x: 11, y: 11.5))
        path.closeSubpath()

        context.addPath(path)
        context.setFillColor(NSColor.black.cgColor)
        context.fillPath(using: .winding)
        context.addPath(path)
        context.setStrokeColor(NSColor.white.cgColor)
        context.setLineWidth(1.2)
        context.strokePath()

        return (context.makeImage()!, size, CGPoint(x: 0, y: 0))
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

        // 原本用 NSCursor.arrow.image 取真实系统指针位图，但在这个进程环境下
        // （命令行/菜单栏宿主进程，不是普通 GUI App 的常规启动路径）该属性读出来
        // 是空图像（size=(0,0)，cgImage(forProposedRect:) 返回 nil）——用脚本单独
        // 验证过，不是这次改动引入的问题，是该 API 在此环境下本身就不可靠。改成
        // 手绘一个经典箭头形状，不依赖这个不可靠的系统资源。
        let (cursorImage, cursorSize, hotSpot) = Self.makeArrowCursorImage()
        cursorLayer.contents = cursorImage
        cursorLayer.bounds = CGRect(origin: .zero, size: cursorSize)
        // hotSpot 使用左上角为原点、Y 轴向下的坐标系（箭头尖端在左上角）；
        // CALayer.anchorPoint 的 Y 轴则从左下角向上，两者转换时必须翻转 Y 轴。
        // 方向写反不会破坏光标跟踪，位置数据仍然正确，但渲染出的指针尖端会偏离
        // 真实点击点数个点，足以错过标签页关闭按钮等小目标。过去报告的“点击落点
        // 错误”实际由此引起，并不是跟踪逻辑的问题。
        cursorLayer.anchorPoint = CGPoint(x: hotSpot.x / cursorSize.width,
                                           y: 1 - hotSpot.y / cursorSize.height)
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

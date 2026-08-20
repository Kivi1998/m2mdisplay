import AppKit
import QuartzCore

/// 在独立透明窗口中绘制远端光标。不能把它作为 AVSampleBufferDisplayLayer 的
/// 普通兄弟图层，否则 macOS 的视频合成路径可能把箭头盖在视频平面下面。
final class CursorOverlayView: NSView {
    private let cursorLayer = CALayer()
    private var cursorVisible = false

    var isCursorVisibleForTesting: Bool {
        cursorVisible && !cursorLayer.isHidden && cursorLayer.contents != nil
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setupLayer()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        setupLayer()
    }

    private static func makeArrowCursorImage() -> (image: CGImage, size: CGSize) {
        let size = CGSize(width: 16, height: 22)
        let scale: CGFloat = 2
        let pixelWidth = Int(size.width * scale)
        let pixelHeight = Int(size.height * scale)
        let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
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
        context.fillPath()
        context.addPath(path)
        context.setStrokeColor(NSColor.white.cgColor)
        context.setLineWidth(1.2)
        context.strokePath()
        return (context.makeImage()!, size)
    }

    private func setupLayer() {
        guard let rootLayer = layer else { return }
        rootLayer.backgroundColor = NSColor.clear.cgColor
        let (image, size) = Self.makeArrowCursorImage()
        cursorLayer.contents = image
        cursorLayer.contentsScale = window?.backingScaleFactor ?? 2
        cursorLayer.bounds = CGRect(origin: .zero, size: size)
        cursorLayer.anchorPoint = CGPoint(x: 0, y: 1)
        cursorLayer.isHidden = true
        rootLayer.addSublayer(cursorLayer)
    }

    func updateCursor(normalizedX: CGFloat, normalizedY: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cursorLayer.position = CGPoint(
            x: bounds.minX + normalizedX * bounds.width,
            y: bounds.minY + (1 - normalizedY) * bounds.height
        )
        cursorLayer.isHidden = false
        cursorVisible = true
        CATransaction.commit()
    }

    func hideCursor() {
        guard cursorVisible else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cursorLayer.isHidden = true
        cursorVisible = false
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let scale = window?.backingScaleFactor {
            cursorLayer.contentsScale = scale
        }
    }
}

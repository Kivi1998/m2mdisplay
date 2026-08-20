import AppKit
import QuartzCore
import M2MShared

/// 在独立透明窗口中绘制远端光标，只依赖独立 UDP 通道传来的位置和类型，完全不
/// 经过视频解码管线——这是延迟能远低于 AirPlay 的关键，鼠标移动到画面更新之间
/// 不用等视频帧率。不能把这个视图的图层挂在 AVSampleBufferDisplayLayer 下面
/// 当普通兄弟图层，否则 macOS 的视频合成路径可能把光标盖在视频画面下面，必须
/// 用独立窗口叠在最上层。
///
/// 三种光标形状都是手绘的（黑色填充 + 白色描边，贴近原生 macOS 外观），而不是
/// 读取系统光标位图——发送端能用 `NSCursor.currentSystem` 的位图指纹分辨出当前
/// 是哪种光标（见 CursorClassifier.swift），但接收端这边直接用 `NSCursor.arrow`
/// 等内置单例的 `.image` 在这个进程环境下是空的（0 张 representation，已经在
/// CLAUDE.md 里记过这个坑），没有可靠的系统位图能直接拿来用，所以维持手绘。
final class CursorOverlayView: NSView {
    private struct Glyph {
        let image: CGImage
        let size: CGSize
        let hotSpot: CGPoint // 左上角为原点、Y 轴向下，与 CursorPacket 的坐标系一致
    }

    private let cursorLayer = CALayer()
    private var cursorVisible = false
    private var currentType: CursorType = .arrow
    private let glyphs: [CursorType: Glyph] = [
        .arrow: CursorOverlayView.makeArrowGlyph(),
        .pointingHand: CursorOverlayView.makePointingHandGlyph(),
        .iBeam: CursorOverlayView.makeIBeamGlyph(),
    ]

    var isCursorVisibleForTesting: Bool {
        cursorVisible && !cursorLayer.isHidden && cursorLayer.contents != nil
    }

    var currentTypeForTesting: CursorType { currentType }

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

    private func setupLayer() {
        guard let rootLayer = layer else { return }
        rootLayer.backgroundColor = NSColor.clear.cgColor
        cursorLayer.contentsScale = window?.backingScaleFactor ?? 2
        cursorLayer.isHidden = true
        applyGlyph(for: .arrow)
        rootLayer.addSublayer(cursorLayer)
    }

    private func applyGlyph(for type: CursorType) {
        // 收到 resize 等这版还没手绘的形态时，安全退化成箭头，不留空白光标。
        guard let glyph = glyphs[type] ?? glyphs[.arrow] else { return }
        cursorLayer.contents = glyph.image
        cursorLayer.bounds = CGRect(origin: .zero, size: glyph.size)
        cursorLayer.anchorPoint = CGPoint(x: glyph.hotSpot.x / glyph.size.width,
                                           y: 1 - glyph.hotSpot.y / glyph.size.height)
    }

    /// 使用归一化坐标 + 光标类型更新叠加光标。整个操作关闭隐式动画；这条路径不能
    /// 继承任何缓动或动画时长，否则会重新引入本项目要消除的延迟。
    func updateCursor(normalizedX: CGFloat, normalizedY: CGFloat, cursorType: CursorType) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if cursorType != currentType {
            currentType = cursorType
            applyGlyph(for: cursorType)
        }
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

    // MARK: - 手绘图形

    private static func makeArrowGlyph() -> Glyph {
        let size = CGSize(width: 16, height: 22)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: 0, y: 16))
        path.addLine(to: CGPoint(x: 4, y: 12.5))
        path.addLine(to: CGPoint(x: 6.5, y: 18))
        path.addLine(to: CGPoint(x: 9, y: 17))
        path.addLine(to: CGPoint(x: 6.5, y: 11.5))
        path.addLine(to: CGPoint(x: 11, y: 11.5))
        path.closeSubpath()
        return Glyph(image: render(path: path, canvasSize: size, lineWidth: 1.2),
                     size: size, hotSpot: CGPoint(x: 0, y: 0))
    }

    /// 简化成"指向的食指 + 收拢的拳心"两个圆角矩形的并集。两块形状在指根处
    /// 故意保留重叠但描边仍各画各的，会在指根留下一道白色分隔线——这其实跟真实
    /// macOS 手形光标里手指之间的分隔线效果类似，不是 bug，不用消除。
    private static func makePointingHandGlyph() -> Glyph {
        let size = CGSize(width: 18, height: 20)
        let path = CGMutablePath()
        path.addPath(CGPath(roundedRect: CGRect(x: 5, y: 0, width: 4, height: 11),
                             cornerWidth: 2, cornerHeight: 2, transform: nil))
        path.addPath(CGPath(roundedRect: CGRect(x: 2, y: 8, width: 14, height: 11),
                             cornerWidth: 3.5, cornerHeight: 3.5, transform: nil))
        return Glyph(image: render(path: path, canvasSize: size, lineWidth: 1.0),
                     size: size, hotSpot: CGPoint(x: 7, y: 1))
    }

    /// 经典文本工字光标：上下两道短横 + 中间一道细竖线，一笔画成单一闭合轮廓，
    /// 避免用三个独立矩形拼接在衔接处露出多余的白色描边缝隙。
    private static func makeIBeamGlyph() -> Glyph {
        let size = CGSize(width: 9, height: 16)
        let barHeight: CGFloat = 1.6
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 2, y: 0))
        path.addLine(to: CGPoint(x: 7, y: 0))
        path.addLine(to: CGPoint(x: 7, y: barHeight))
        path.addLine(to: CGPoint(x: 5.2, y: barHeight))
        path.addLine(to: CGPoint(x: 5.2, y: size.height - barHeight))
        path.addLine(to: CGPoint(x: 7, y: size.height - barHeight))
        path.addLine(to: CGPoint(x: 7, y: size.height))
        path.addLine(to: CGPoint(x: 2, y: size.height))
        path.addLine(to: CGPoint(x: 2, y: size.height - barHeight))
        path.addLine(to: CGPoint(x: 3.8, y: size.height - barHeight))
        path.addLine(to: CGPoint(x: 3.8, y: barHeight))
        path.addLine(to: CGPoint(x: 2, y: barHeight))
        path.closeSubpath()
        return Glyph(image: render(path: path, canvasSize: size, lineWidth: 0.8),
                     size: size, hotSpot: CGPoint(x: 4.5, y: 8))
    }

    private static func render(path: CGPath, canvasSize: CGSize, lineWidth: CGFloat) -> CGImage {
        let scale: CGFloat = 2
        let pixelWidth = Int(canvasSize.width * scale)
        let pixelHeight = Int(canvasSize.height * scale)
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

        context.addPath(path)
        context.setFillColor(NSColor.black.cgColor)
        context.fillPath(using: .winding)
        context.addPath(path)
        context.setStrokeColor(NSColor.white.cgColor)
        context.setLineWidth(lineWidth)
        context.strokePath()
        return context.makeImage()!
    }
}

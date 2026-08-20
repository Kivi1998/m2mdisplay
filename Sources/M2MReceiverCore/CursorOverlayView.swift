import AppKit
import QuartzCore
import M2MShared

/// 在独立透明窗口中绘制远端光标，只依赖独立 UDP 通道传来的位置和类型，完全不
/// 经过视频解码管线——这是延迟能远低于 AirPlay 的关键，鼠标移动到画面更新之间
/// 不用等视频帧率。不能把这个视图的图层挂在 AVSampleBufferDisplayLayer 下面
/// 当普通兄弟图层，否则 macOS 的视频合成路径可能把光标盖在视频画面下面，必须
/// 用独立窗口叠在最上层。
///
/// 三种光标形状优先直接用 macOS 自带的原生素材，而不是手绘近似图案：
/// - 手形、工字：直接从 HIServices.framework 里 AppKit 自己也在用的矢量 PDF
///   （`.../HIServices.framework/Versions/A/Resources/cursors/<name>/cursor.pdf`，
///   同目录 `info.plist` 里的 `hotx`/`hoty` 就是热点）现取现画，不经过
///   `NSCursor` 这层——`.image` 属性在某些启动方式下是空的（见 CLAUDE.md），
///   直接读文件反而不受这个坑影响。热点坐标系已经用真机渲染+标记点验证过，
///   是"左上角原点、Y 轴向下"，直接用不用翻转；渲染这个 PDF 时也不能套用
///   下面手绘图形那套"先翻转 Y 轴再画"的变换——PDF 页面自己就是标准的左下角
///   原点、Y 向上，套那套变换会把图形画成上下颠倒，已经用实际 CALayer 渲染
///   截图验证过。
/// - 箭头：系统资源目录里没有单独的箭头文件（大概率是直接烧录在 WindowServer
///   里的），但实测在正常 `.app` bundle 里（`open -a` 启动，不是裸命令行）
///   `NSCursor.arrow.image` 是能正常读到位图的，用它代替手绘。
/// 三者都保留手绘版本兜底：万一哪天素材路径失效或者 `.image` 又读不出来了，
/// 退化成手绘图案也不会显示空白光标。
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

    // MARK: - 优先加载原生素材

    /// 系统级光标矢量资源目录。不是公开 API，是从 AppKit 自己加载内置光标的
    /// 实际路径里找到的（用 `pointinghand`/`ibeamhorizontal` 两个真实文件夹
    /// 渲染出来跟系统显示的一模一样，已经验证过）。换 macOS 大版本时如果这个
    /// 路径挪了地方，下面的加载函数会拿到 nil，自动退化成手绘版本，不会崩溃。
    private static let systemCursorsDirectory =
        "/System/Library/Frameworks/ApplicationServices.framework/Versions/A/Frameworks/HIServices.framework/Versions/A/Resources/cursors"

    private static func makeArrowGlyph() -> Glyph {
        let cursor = NSCursor.arrow
        let image = cursor.image
        if image.size.width > 0, image.size.height > 0,
           let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            // 实测：只有真正的 .app bundle（比如 open -a 启动的 M2MApp）里这个属性
            // 才读得出位图；裸命令行进程里是空的（CLAUDE.md 记过）。这里两种情况
            // 都要兜住，读不出来就退化成手绘箭头。
            return Glyph(image: cgImage, size: image.size, hotSpot: cursor.hotSpot)
        }
        return makeArrowFallbackGlyph()
    }

    private static func makePointingHandGlyph() -> Glyph {
        loadSystemCursorGlyph(folder: "pointinghand") ?? makePointingHandFallbackGlyph()
    }

    private static func makeIBeamGlyph() -> Glyph {
        loadSystemCursorGlyph(folder: "ibeamhorizontal") ?? makeIBeamFallbackGlyph()
    }

    /// 从系统自带的矢量光标资源现取现画。`info.plist` 里的 hotx/hoty 已经用真机
    /// 渲染 + 标记点验证过，是"左上角原点、Y 轴向下"，直接拿来当 Glyph.hotSpot
    /// 用、不用换算。绘制时刻意不套用 render(path:...) 那套"先翻转 Y 轴"的变换——
    /// PDF 页面本身就是左下角原点、Y 向上，套了反而会画成上下颠倒（同样已经用
    /// 真实 CALayer 渲染截图验证过）。
    private static func loadSystemCursorGlyph(folder: String, renderScale: CGFloat = 2) -> Glyph? {
        let directory = "\(systemCursorsDirectory)/\(folder)"
        guard let plist = NSDictionary(contentsOfFile: "\(directory)/info.plist"),
              let hotX = plist["hotx"] as? NSNumber,
              let hotY = plist["hoty"] as? NSNumber,
              let pdfDocument = CGPDFDocument(URL(fileURLWithPath: "\(directory)/cursor.pdf") as CFURL),
              let page = pdfDocument.page(at: 1)
        else { return nil }

        let box = page.getBoxRect(.mediaBox)
        let pixelWidth = Int(box.width * renderScale)
        let pixelHeight = Int(box.height * renderScale)
        guard pixelWidth > 0, pixelHeight > 0,
              let context = CGContext(
                data: nil,
                width: pixelWidth,
                height: pixelHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        context.scaleBy(x: renderScale, y: renderScale)
        context.drawPDFPage(page)
        guard let image = context.makeImage() else { return nil }

        return Glyph(image: image, size: box.size,
                     hotSpot: CGPoint(x: CGFloat(hotX.doubleValue), y: CGFloat(hotY.doubleValue)))
    }

    // MARK: - 手绘兜底图形（原生素材加载失败时使用）

    private static func makeArrowFallbackGlyph() -> Glyph {
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
    private static func makePointingHandFallbackGlyph() -> Glyph {
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
    private static func makeIBeamFallbackGlyph() -> Glyph {
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

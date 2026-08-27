import AppKit

/// 音量变化提示条。系统的 ControlCenter 会识别媒体键事件是否来自真实硬件，
/// 因此合成事件虽然能修改音量，却不会触发系统 HUD。这里仅补足视觉反馈：
/// macOS 26 直接使用系统玻璃效果，旧系统则回退到 AppKit 的 HUD 材质。
final class VolumeHUDView: NSView {
    private let contentContainer = NSView()
    private let deviceLabel = NSTextField(labelWithString: "")
    private let leftIconView = NSImageView()
    private let rightIconView = NSImageView()
    private let trackLayer = CALayer()
    private let fillLayer = CALayer()
    private var tickLayers: [CALayer] = []
    private var hideWorkItem: DispatchWorkItem?
    private var presentationID = 0

    private static let hideDelay: TimeInterval = 1.8
    private static let fadeInDuration: TimeInterval = 0.14
    private static let fadeOutDuration: TimeInterval = 0.22
    private static let sidePadding: CGFloat = 16
    private static let iconSize: CGFloat = 14
    private static let barHeight: CGFloat = 3
    private static let barY: CGFloat = 22
    private static let tickCount = 16
    private static let tickDiameter: CGFloat = 2

    var deviceName: String = "iMac 内建扬声器" {
        didSet { deviceLabel.stringValue = deviceName }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        layer?.masksToBounds = false

        contentContainer.frame = bounds
        contentContainer.autoresizingMask = [.width, .height]
        contentContainer.wantsLayer = true

        if #available(macOS 26.0, *) {
            let glassView = NSGlassEffectView(frame: bounds)
            glassView.autoresizingMask = [.width, .height]
            glassView.style = .regular
            glassView.cornerRadius = 18
            glassView.contentView = contentContainer
            addSubview(glassView)
        } else {
            let effectView = NSVisualEffectView(frame: bounds)
            effectView.autoresizingMask = [.width, .height]
            effectView.material = .hudWindow
            effectView.blendingMode = .behindWindow
            effectView.state = .active
            effectView.wantsLayer = true
            effectView.layer?.cornerRadius = 18
            effectView.layer?.masksToBounds = true
            effectView.addSubview(contentContainer)
            addSubview(effectView)
        }

        deviceLabel.stringValue = deviceName
        deviceLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        deviceLabel.textColor = .labelColor
        deviceLabel.alignment = .left
        deviceLabel.frame = CGRect(
            x: Self.sidePadding,
            y: bounds.height - 27,
            width: bounds.width - Self.sidePadding * 2,
            height: 18
        )
        deviceLabel.autoresizingMask = [.width]
        contentContainer.addSubview(deviceLabel)

        leftIconView.frame = CGRect(
            x: Self.sidePadding,
            y: Self.barY - Self.iconSize / 2,
            width: Self.iconSize,
            height: Self.iconSize
        )
        leftIconView.contentTintColor = .secondaryLabelColor
        leftIconView.image = Self.smallSpeakerIcon
        contentContainer.addSubview(leftIconView)

        rightIconView.frame = CGRect(
            x: bounds.width - Self.sidePadding - Self.iconSize,
            y: Self.barY - Self.iconSize / 2,
            width: Self.iconSize,
            height: Self.iconSize
        )
        rightIconView.autoresizingMask = [.minXMargin]
        rightIconView.contentTintColor = .secondaryLabelColor
        rightIconView.image = Self.loudSpeakerIcon
        contentContainer.addSubview(rightIconView)

        guard let contentLayer = contentContainer.layer else { return }
        let barX = Self.sidePadding + Self.iconSize + 10
        let barWidth = max(0, bounds.width - barX - Self.sidePadding - Self.iconSize - 10)

        trackLayer.backgroundColor = NSColor.labelColor.withAlphaComponent(0.18).cgColor
        trackLayer.cornerRadius = Self.barHeight / 2
        trackLayer.frame = CGRect(
            x: barX,
            y: Self.barY - Self.barHeight / 2,
            width: barWidth,
            height: Self.barHeight
        )
        contentLayer.addSublayer(trackLayer)

        fillLayer.backgroundColor = NSColor.labelColor.withAlphaComponent(0.92).cgColor
        fillLayer.cornerRadius = Self.barHeight / 2
        fillLayer.frame = CGRect(
            x: barX,
            y: Self.barY - Self.barHeight / 2,
            width: 0,
            height: Self.barHeight
        )
        contentLayer.addSublayer(fillLayer)

        setupTickLayers(in: contentLayer, barX: barX, barWidth: barWidth)

        alphaValue = 0
        isHidden = true
    }

    private func setupTickLayers(in contentLayer: CALayer, barX: CGFloat, barWidth: CGFloat) {
        let spacing = barWidth / CGFloat(Self.tickCount - 1)
        for index in 0..<Self.tickCount {
            let tick = CALayer()
            tick.backgroundColor = NSColor.labelColor.withAlphaComponent(0.12).cgColor
            tick.cornerRadius = Self.tickDiameter / 2
            tick.frame = CGRect(
                x: barX + CGFloat(index) * spacing - Self.tickDiameter / 2,
                y: Self.barY - 9,
                width: Self.tickDiameter,
                height: Self.tickDiameter
            )
            contentLayer.addSublayer(tick)
            tickLayers.append(tick)
        }
    }

    /// `volume` 是 0...1 的音量值；静音时清空滑条并切换右侧图标。
    func show(volume: Float, muted: Bool) {
        hideWorkItem?.cancel()
        presentationID &+= 1
        let currentPresentationID = presentationID

        let clamped = muted ? 0 : max(0, min(1, volume))
        let fillWidth = trackLayer.frame.width * CGFloat(clamped)
        let wasHidden = isHidden

        CATransaction.begin()
        CATransaction.setAnimationDuration(wasHidden ? 0 : 0.1)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        fillLayer.frame.size.width = fillWidth
        CATransaction.commit()

        rightIconView.image = muted ? Self.mutedSpeakerIcon : Self.loudSpeakerIcon

        if wasHidden {
            alphaValue = 0
            isHidden = false
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = wasHidden ? Self.fadeInDuration : 0.08
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().alphaValue = 1
        }

        let workItem = DispatchWorkItem { [weak self] in
            self?.fadeOut(presentationID: currentPresentationID)
        }
        hideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hideDelay, execute: workItem)
    }

    func hideImmediately() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        presentationID &+= 1
        alphaValue = 0
        isHidden = true
    }

    private func fadeOut(presentationID: Int) {
        guard self.presentationID == presentationID else { return }
        hideWorkItem = nil
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeOutDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            self.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            guard let self, self.presentationID == presentationID else { return }
            self.isHidden = true
        }
    }

    private static var smallSpeakerIcon: NSImage? { symbol("speaker.fill") }
    private static var loudSpeakerIcon: NSImage? { symbol("speaker.wave.3.fill") }
    private static var mutedSpeakerIcon: NSImage? { symbol("speaker.slash.fill") }

    private static func symbol(_ name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        image?.isTemplate = true
        return image
    }
}

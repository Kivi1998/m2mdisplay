import AppKit

/// 音量变化的提示条，照搬 macOS 现代版本切换输出设备时弹出的那种卡片样式
/// （设备名 + 滑条），因为验证过 ControlCenter 触发原生 HUD 的那部分逻辑会
/// 区分事件是不是真实硬件产生的，`CGEventPost` 合成的按键骗不过去——音量能
/// 真的改变，但原生 HUD 弹不出来，所以只能自己照着样式做一份。只在 iMac
/// （接收端）一侧显示，跟光标叠加层各自独立一个窗口，避免牵扯到光标那边
/// 已经调好的动画细节。
final class VolumeHUDView: NSView {
    private let effectView = NSVisualEffectView()
    private let deviceLabel = NSTextField(labelWithString: "")
    private let leftIconView = NSImageView()
    private let rightIconView = NSImageView()
    private let trackLayer = CALayer()
    private let fillLayer = CALayer()
    private let thumbLayer = CALayer()
    private var hideWorkItem: DispatchWorkItem?

    private static let hideDelay: TimeInterval = 1.8
    private static let sidePadding: CGFloat = 22
    private static let iconSize: CGFloat = 16
    private static let barHeight: CGFloat = 5
    private static let thumbDiameter: CGFloat = 16

    var deviceName: String = "iMac 内建扬声器" {
        didSet { deviceLabel.stringValue = deviceName }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        setup()
    }

    private func setup() {
        layer?.cornerRadius = 24
        layer?.masksToBounds = true
        layer?.shadowOpacity = 0

        effectView.frame = bounds
        effectView.autoresizingMask = [.width, .height]
        effectView.material = .popover
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        addSubview(effectView)

        deviceLabel.stringValue = deviceName
        deviceLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        deviceLabel.textColor = .labelColor
        deviceLabel.alignment = .left
        deviceLabel.frame = CGRect(x: Self.sidePadding, y: bounds.height - 38, width: bounds.width - Self.sidePadding * 2, height: 22)
        deviceLabel.autoresizingMask = [.width]
        addSubview(deviceLabel)

        let barY: CGFloat = 22
        leftIconView.frame = CGRect(x: Self.sidePadding, y: barY - Self.iconSize / 2, width: Self.iconSize, height: Self.iconSize)
        leftIconView.contentTintColor = .secondaryLabelColor
        leftIconView.image = Self.smallSpeakerIcon
        addSubview(leftIconView)

        rightIconView.frame = CGRect(x: bounds.width - Self.sidePadding - Self.iconSize, y: barY - Self.iconSize / 2, width: Self.iconSize, height: Self.iconSize)
        rightIconView.contentTintColor = .secondaryLabelColor
        rightIconView.image = Self.loudSpeakerIcon
        addSubview(rightIconView)

        guard let rootLayer = layer else { return }
        let barX = Self.sidePadding + Self.iconSize + 12
        let barWidth = max(0, bounds.width - barX - Self.sidePadding - Self.iconSize - 12)
        trackLayer.backgroundColor = NSColor.tertiaryLabelColor.withAlphaComponent(0.5).cgColor
        trackLayer.cornerRadius = Self.barHeight / 2
        trackLayer.frame = CGRect(x: barX, y: barY - Self.barHeight / 2, width: barWidth, height: Self.barHeight)
        rootLayer.addSublayer(trackLayer)

        fillLayer.backgroundColor = NSColor.labelColor.cgColor
        fillLayer.cornerRadius = Self.barHeight / 2
        fillLayer.frame = CGRect(x: barX, y: barY - Self.barHeight / 2, width: 0, height: Self.barHeight)
        rootLayer.addSublayer(fillLayer)

        thumbLayer.backgroundColor = NSColor.white.cgColor
        thumbLayer.cornerRadius = Self.thumbDiameter / 2
        thumbLayer.shadowColor = NSColor.black.cgColor
        thumbLayer.shadowOpacity = 0.35
        thumbLayer.shadowRadius = 1.5
        thumbLayer.shadowOffset = CGSize(width: 0, height: -0.5)
        thumbLayer.frame = CGRect(x: barX - Self.thumbDiameter / 2, y: barY - Self.thumbDiameter / 2, width: Self.thumbDiameter, height: Self.thumbDiameter)
        rootLayer.addSublayer(thumbLayer)

        isHidden = true
    }

    /// volume 是 0...1 的音量值；muted 为真时音量条清空、右侧图标换成静音图标，
    /// 不管 volume 参数本身是多少（跟系统原生音量条的表现一致）。
    func show(volume: Float, muted: Bool) {
        hideWorkItem?.cancel()

        let clamped = muted ? 0 : max(0, min(1, volume))
        let barX = trackLayer.frame.minX
        let fillWidth = trackLayer.frame.width * CGFloat(clamped)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fillLayer.frame.size.width = fillWidth
        thumbLayer.frame.origin.x = barX + fillWidth - Self.thumbDiameter / 2
        CATransaction.commit()

        rightIconView.image = muted ? Self.mutedSpeakerIcon : Self.loudSpeakerIcon
        isHidden = false

        let workItem = DispatchWorkItem { [weak self] in self?.isHidden = true }
        hideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hideDelay, execute: workItem)
    }

    func hideImmediately() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        isHidden = true
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

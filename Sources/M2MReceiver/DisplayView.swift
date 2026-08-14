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

        // Manually-added sublayers default to 1x even inside a Retina window.
        // Keep the 1920x1080 point-sized view while compositing into its
        // 3840x2160 backing store, otherwise the decoded Retina frame is
        // downsampled before macOS presents it on the iMac panel.
        let scale = window?.backingScaleFactor ?? 2.0
        videoLayer.contentsScale = scale
        cursorLayer.contentsScale = scale

        videoLayer.videoGravity = .resize
        videoLayer.frame = rootLayer.bounds
        videoLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        rootLayer.addSublayer(videoLayer)

        // The real system pointer bitmap, not a hand-drawn approximation —
        // NSCursor.arrow.image is the actual asset AppKit ships, so this is
        // pixel-for-pixel what the user's used to seeing everywhere else.
        let cursorImage = NSCursor.arrow.image
        let hotSpot = NSCursor.arrow.hotSpot
        var imageRect = CGRect(origin: .zero, size: cursorImage.size)
        if let cgImage = cursorImage.cgImage(forProposedRect: &imageRect, context: nil, hints: nil) {
            cursorLayer.contents = cgImage
        }
        cursorLayer.bounds = CGRect(origin: .zero, size: cursorImage.size)
        // NSCursor.hotSpot is specified top-left-down (legacy from classic Mac OS
        // cursor resources), while CALayer.anchorPoint's Y is bottom-left-up —
        // flip the Y axis converting between them. Getting this backwards doesn't
        // break cursor *tracking* (the reported position is correct either way)
        // but it does put the rendered tip several points away from the real
        // click point, which is exactly narrow enough to miss small targets like
        // a tab's close button while looking "close enough" at a glance —
        // that's what was actually being reported as "clicks land in the wrong
        // place," not a tracking bug.
        cursorLayer.anchorPoint = CGPoint(x: hotSpot.x / cursorImage.size.width,
                                           y: 1 - hotSpot.y / cursorImage.size.height)
        cursorLayer.isHidden = true
        cursorLayer.zPosition = 10
        rootLayer.addSublayer(cursorLayer)
    }

    /// Updates cursor position in *normalized* (0...1, top-left origin, matching the
    /// coordinate space the sender's mouse tap reports in) coordinates. Wrapped in a
    /// no-implicit-animation transaction — this is the one path that must never
    /// inherit any easing/duration, since any smoothing here directly reintroduces
    /// the latency this whole project exists to remove.
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

    /// The cursor tap only reports position while the real cursor is over the
    /// virtual display; once it moves back onto the MacBook's own screen this
    /// hides the overlay instead of leaving it stuck at the last position it
    /// saw at the edge.
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

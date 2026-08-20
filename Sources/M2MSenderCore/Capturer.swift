import ScreenCaptureKit
import Foundation

final class FrameCapturer: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private let displayID: CGDirectDisplayID
    private let width: Int
    private let height: Int
    private let frameRate: Int
    var onFrame: ((CMSampleBuffer) -> Void)?
    var onStreamStopped: ((Error?) -> Void)?

    init(displayID: CGDirectDisplayID, width: Int, height: Int, frameRate: Int = 60) {
        self.displayID = displayID
        self.width = width
        self.height = height
        self.frameRate = frameRate
    }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let scDisplay = content.displays.first(where: { $0.displayID == displayID }) else {
            throw M2MError.displayNotFound
        }

        let filter = SCContentFilter(display: scDisplay, excludingWindows: [])

        let config = Self.makeConfiguration(width: width, height: height, frameRate: frameRate)

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue(label: "com.m2mdisplay.capture"))
        try await stream.startCapture()
        self.stream = stream
    }

    static func makeConfiguration(width: Int, height: Int, frameRate: Int) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.showsCursor = false // 光标改由独立低延迟通道传输，不烤进视频帧——
        // 视频帧要过编解码和网络，光标会跟着视频帧率一起卡；独立 UDP 通道不用等
        // 视频管线，鼠标移动到画面更新之间能做到远低于 AirPlay 的延迟。
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(frameRate))
        config.queueDepth = 3
        config.colorSpaceName = CGColorSpace.sRGB
        return config
    }

    func stop() async {
        try? await stream?.stopCapture()
        stream = nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }
        onFrame?(sampleBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStreamStopped?(error)
    }
}

enum M2MError: Error {
    case displayNotFound
    case encoderFailed(OSStatus)
}

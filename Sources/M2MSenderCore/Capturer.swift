import ScreenCaptureKit
import Foundation

final class FrameCapturer: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private let displayID: CGDirectDisplayID
    private let width: Int
    private let height: Int
    private let frameRate: Int
    var onFrame: ((CMSampleBuffer) -> Void)?
    var onAudioSampleBuffer: ((CMSampleBuffer) -> Void)?
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
        // 音频用独立队列，不要跟屏幕帧共用——音频回调对时序敏感，混在一起排队
        // 可能被视频帧处理的耗时拖慢，引入不必要的音频延迟/卡顿。
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: DispatchQueue(label: "com.m2mdisplay.audiocapture"))
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
        // 系统音频同样走 ScreenCaptureKit 采集，不需要额外的虚拟声卡/权限——复用
        // 已经申请过的屏幕录制权限。采样率/声道数在这里固定写死，跟
        // AudioWireFormat 的线上格式无关：这里定的是 ScreenCaptureKit 给我们的
        // 源格式，AudioSampleConverter 会再转换成线上那份固定格式。
        config.capturesAudio = true
        config.sampleRate = 48000
        config.channelCount = 2
        return config
    }

    func stop() async {
        try? await stream?.stopCapture()
        stream = nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        switch type {
        case .screen:
            onFrame?(sampleBuffer)
        case .audio:
            onAudioSampleBuffer?(sampleBuffer)
        default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStreamStopped?(error)
    }
}

enum M2MError: Error {
    case displayNotFound
    case encoderFailed(OSStatus)
}

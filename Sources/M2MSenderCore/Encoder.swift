import VideoToolbox
import CoreMedia
import Foundation

struct EncodedFrame {
    let payload: Data      // AVCC 格式、带长度前缀的 NAL 单元
    let avcC: Data?        // 关键帧尝试携带，包含重建格式描述所需的 VPS、SPS 和 PPS
    let isKeyframe: Bool
    let presentationTimeNanos: UInt64
}

final class VideoEncoder {
    private var session: VTCompressionSession?
    var onEncodedFrame: ((EncodedFrame) -> Void)?

    init(width: Int, height: Int, frameRate: Int, averageBitrateBps: Int) throws {
        var session: VTCompressionSession?
        let encoderSpec: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true
        ]
        let status = VTCompressionSessionCreate(
            allocator: nil,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: encoderSpec as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )
        guard status == noErr, let session else {
            throw M2MError.encoderFailed(status)
        }

        // 面向低延迟交互场景调优：使用实时节奏，不启用 B 帧或帧重排，
        // 并缩短关键帧间隔，以便丢帧或迟到帧出现后快速恢复。
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        // 选择 HEVC 而不是 H.264。对于密集文字和锐利界面边缘等本项目内容，
        // HEVC 的单位码率画质明显更好。Apple 芯片媒体引擎原生支持 HEVC 编解码，
        // 因此不会像直接提升到 4.5K 原生分辨率那样耗尽实时处理余量。
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_HEVC_Main_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: frameRate as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: averageBitrateBps as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: (frameRate * 2) as CFNumber) // 约每 2 秒一个关键帧
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 2.0 as CFNumber)

        VTCompressionSessionPrepareToEncodeFrames(session)
        self.session = session
    }

    func encode(_ sampleBuffer: CMSampleBuffer) {
        guard let session, let pixelBuffer = sampleBuffer.imageBuffer else { return }
        let pts = sampleBuffer.presentationTimeStamp
        VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: pts,
            duration: .invalid,
            frameProperties: nil,
            infoFlagsOut: nil
        ) { [weak self] status, _, sampleBuffer in
            guard status == noErr, let sampleBuffer, let self else { return }
            self.handleOutput(sampleBuffer, pts: pts)
        }
    }

    private func handleOutput(_ sampleBuffer: CMSampleBuffer, pts: CMTime) {
        guard let dataBuffer = sampleBuffer.dataBuffer else { return }
        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer) == noErr,
              let dataPointer else { return }
        let payload = Data(bytes: dataPointer, count: length)

        let isKeyframe = !(sampleBuffer.sampleAttachments.first?[.notSync] as? Bool ?? false)

        // “hvcC”（HEVC 解码器配置记录）相当于 H.264 的“avcC”。
        // 两者都保存解码器所需参数集，只是此编解码器使用不同的数据块名称和格式描述键。
        var avcCData: Data?
        if isKeyframe, let formatDescription = sampleBuffer.formatDescription,
           let atoms = CMFormatDescriptionGetExtension(formatDescription, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Any],
           let hvcC = atoms["hvcC"] as? Data {
            avcCData = hvcC
        }

        let ptsNanos = UInt64(max(0, pts.seconds) * 1_000_000_000)
        onEncodedFrame?(EncodedFrame(payload: payload, avcC: avcCData, isKeyframe: isKeyframe, presentationTimeNanos: ptsNanos))
    }

    func invalidate() {
        guard let session else { return }
        VTCompressionSessionInvalidate(session)
        self.session = nil
    }
}

import VideoToolbox
import CoreMedia
import Foundation

struct EncodedFrame {
    let payload: Data      // AVCC length-prefixed NAL units
    let avcC: Data?        // present on keyframes — SPS/PPS the decoder needs to (re)build its format description
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
            codecType: kCMVideoCodecType_H264,
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

        // Low-latency, interactive tuning: real-time pacing, no B-frames / reordering,
        // aggressive keyframe interval so a dropped/late frame recovers fast.
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        // High profile over Main — better quality per bit, which matters more
        // than usual here since screen content (text, sharp UI edges) is much
        // harder to compress cleanly than natural video.
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: frameRate as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: averageBitrateBps as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: (frameRate * 2) as CFNumber) // keyframe every ~2s
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

        var avcCData: Data?
        if isKeyframe, let formatDescription = sampleBuffer.formatDescription,
           let atoms = CMFormatDescriptionGetExtension(formatDescription, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Any],
           let avcC = atoms["avcC"] as? Data {
            avcCData = avcC
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

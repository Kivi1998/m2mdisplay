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

        // Low-latency, interactive tuning: real-time pacing, no B-frames / reordering,
        // aggressive keyframe interval so a dropped/late frame recovers fast.
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        // HEVC over H.264 — meaningfully better quality per bit for exactly the
        // kind of content this pipeline carries (dense text, sharp UI edges),
        // and Apple Silicon's media engine has native HEVC encode/decode, so
        // this doesn't cost the real-time headroom that going to native 4.5K did.
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_HEVC_Main_AutoLevel)
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

        // "hvcC" (HEVCDecoderConfigurationRecord) is HEVC's equivalent of H.264's
        // "avcC" — same role (parameter sets the decoder needs), different atom
        // name/format description key for this codec.
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

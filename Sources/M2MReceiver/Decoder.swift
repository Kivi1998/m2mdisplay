import CoreMedia
import Foundation

enum SampleBufferBuilder {
    /// Rebuilds the format description from the avcC (AVCDecoderConfigurationRecord)
    /// box the sender attaches to every keyframe — same technique VideoToolbox used
    /// to produce it on the encode side, just in reverse.
    static func formatDescription(width: Int, height: Int, avcC: Data) -> CMFormatDescription? {
        let extensions: [String: Any] = [
            "SampleDescriptionExtensionAtoms": ["avcC": avcC]
        ]
        var formatDescription: CMFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: nil,
            codecType: kCMVideoCodecType_H264,
            width: Int32(width),
            height: Int32(height),
            extensions: extensions as CFDictionary,
            formatDescriptionOut: &formatDescription
        )
        guard status == noErr else { return nil }
        return formatDescription
    }

    /// Wraps one AVCC (length-prefixed NAL units) payload into a CMSampleBuffer and
    /// flags it for immediate display — skip AVSampleBufferDisplayLayer's normal
    /// "wait until the timebase reaches this frame's PTS" pacing, since we want it
    /// on screen the instant it's decoded, not scheduled against a clock.
    static func sampleBuffer(payload: Data, formatDescription: CMFormatDescription) -> CMSampleBuffer? {
        var blockBuffer: CMBlockBuffer?
        let payloadCount = payload.count
        let status = payload.withUnsafeBytes { raw -> OSStatus in
            guard let baseAddress = raw.baseAddress else { return -1 }
            var buffer: CMBlockBuffer?
            let allocStatus = CMBlockBufferCreateWithMemoryBlock(
                allocator: nil,
                memoryBlock: nil,
                blockLength: payloadCount,
                blockAllocator: nil,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: payloadCount,
                flags: 0,
                blockBufferOut: &buffer
            )
            guard allocStatus == noErr, let buffer else { return allocStatus }
            let copyStatus = CMBlockBufferReplaceDataBytes(with: baseAddress, blockBuffer: buffer, offsetIntoDestination: 0, dataLength: payloadCount)
            guard copyStatus == noErr else { return copyStatus }
            blockBuffer = buffer
            return noErr
        }
        guard status == noErr, let blockBuffer else { return nil }

        var sampleBuffer: CMSampleBuffer?
        var timingInfo = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sampleSize = payloadCount
        let sbStatus = CMSampleBufferCreate(
            allocator: nil,
            dataBuffer: blockBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timingInfo,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard sbStatus == noErr, let sampleBuffer else { return nil }

        if let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true) {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachmentsArray, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(), Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }

        return sampleBuffer
    }
}

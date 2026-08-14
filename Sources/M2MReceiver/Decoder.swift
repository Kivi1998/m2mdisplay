import CoreMedia
import Foundation

enum SampleBufferBuilder {
    /// 根据发送端随每个关键帧附带的 hvcC（HEVC 解码器配置记录）数据块，
    /// 重新构建格式描述。其方法与 VideoToolbox 编码端生成该数据块的过程相反。
    static func formatDescription(width: Int, height: Int, avcC: Data) -> CMFormatDescription? {
        let extensions: [String: Any] = [
            "SampleDescriptionExtensionAtoms": ["hvcC": avcC]
        ]
        var formatDescription: CMFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: nil,
            codecType: kCMVideoCodecType_HEVC,
            width: Int32(width),
            height: Int32(height),
            extensions: extensions as CFDictionary,
            formatDescriptionOut: &formatDescription
        )
        guard status == noErr else { return nil }
        return formatDescription
    }

    /// 将一个 AVCC 载荷（带长度前缀的 NAL 单元）封装为 CMSampleBuffer，
    /// 并标记为立即显示。这样可跳过 AVSampleBufferDisplayLayer 常规的
    /// “等待时间基到达该帧 PTS”节奏控制，使画面在解码完成后立即上屏，
    /// 而不是再等待时钟调度。
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

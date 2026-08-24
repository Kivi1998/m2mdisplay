import AVFAudio
import CoreMedia
import M2MShared

/// 把 ScreenCaptureKit 音频回调给的 `CMSampleBuffer`（格式取决于当时系统状态，
/// 交错/非交错、采样率都不一定固定）转换成 `AudioWireFormat` 那份写死的线上
/// 格式（交错 Float32、48kHz、双声道），返回可以直接通过网络发送的裸字节。
enum AudioSampleConverter {
    private static var converter: AVAudioConverter?
    private static var converterSourceFormat: AVAudioFormat?

    static func convert(_ sampleBuffer: CMSampleBuffer) -> Data? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription),
              let sourceFormat = AVAudioFormat(streamDescription: asbd)
        else { return nil }

        // 经典的两段式调用：先只问需要多大的 AudioBufferList，再按这个大小自己
        // 分配内存拿真正的数据。bufferListOut 指向的内存只是"缓冲区描述符数组"
        // （每个描述符里的 mData 指向 blockBuffer 持有的真实采样数据），blockBuffer
        // 才是采样字节的实际所有者，函数返回后必须保持存活，直到读完数据为止——
        // 它是一个局部变量，作用域到本函数结束，读取和转换都发生在结束之前，安全。
        var bufferListSizeNeeded = 0
        var status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &bufferListSizeNeeded,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: nil
        )
        guard status == noErr, bufferListSizeNeeded > 0 else { return nil }

        let rawListPointer = UnsafeMutableRawPointer.allocate(
            byteCount: bufferListSizeNeeded,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawListPointer.deallocate() }
        let audioBufferListPointer = rawListPointer.assumingMemoryBound(to: AudioBufferList.self)

        var blockBuffer: CMBlockBuffer?
        status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: audioBufferListPointer,
            bufferListSize: bufferListSizeNeeded,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr, blockBuffer != nil,
              let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, bufferListNoCopy: audioBufferListPointer)
        else { return nil }

        let wireFormat = AudioWireFormat.format
        let needsNewConverter: Bool
        if let converterSourceFormat {
            needsNewConverter = !sourceFormat.isEqual(converterSourceFormat)
        } else {
            needsNewConverter = true
        }
        if converter == nil || needsNewConverter {
            converter = AVAudioConverter(from: sourceFormat, to: wireFormat)
            converterSourceFormat = sourceFormat
        }
        guard let converter,
              let outputBuffer = AVAudioPCMBuffer(pcmFormat: wireFormat, frameCapacity: sourceBuffer.frameLength)
        else { return nil }

        do {
            try converter.convert(to: outputBuffer, from: sourceBuffer)
        } catch {
            return nil
        }

        guard let channelData = outputBuffer.floatChannelData, outputBuffer.frameLength > 0 else { return nil }
        // wireFormat 是交错格式，floatChannelData[0] 就是完整的交错采样数据。
        let byteCount = Int(outputBuffer.frameLength) * Int(AudioWireFormat.channelCount) * MemoryLayout<Float32>.size
        return Data(bytes: channelData[0], count: byteCount)
    }
}

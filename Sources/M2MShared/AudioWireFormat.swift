import AVFAudio

/// 发送端把 ScreenCaptureKit 给的系统音频（格式随当时系统状态变化，交错/非
/// 交错、采样率都不一定固定）统一转换成这一份固定格式再发送；接收端也按这份
/// 固定格式重建播放。两端写死同一份定义，`AudioFrameHeader` 就不需要在每个
/// 包里额外携带格式信息。选交错 Float32、48kHz、双声道：雷雳桥接带宽对这个
/// 码率（约 3Mbps）毫无压力，不压缩、不降采样，避免引入额外处理延迟。
public enum AudioWireFormat {
    public static let sampleRate: Double = 48000
    public static let channelCount: AVAudioChannelCount = 2

    public static var format: AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channelCount, interleaved: true)!
    }
}

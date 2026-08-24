import AVFAudio
import M2MShared

/// 用 AVAudioEngine 播放收到的音频包。
///
/// 网络上传的是交错（interleaved）格式的 `AudioWireFormat.format`——序列化
/// 成一条连续字节流最简单。但 `AVAudioEngine` 内部图（`connect(_:to:format:)`）
/// 要求非交错格式，实测过：直接拿交错格式去 connect 会在 App 启动时就直接
/// 崩溃（`AUInterfaceBaseV3::SetFormat` 抛 NSException，`abort()`）。所以这里
/// 维护两份格式：`wireFormat` 只用来算"收到的字节对应多少帧"，真正拿去建
/// `AVAudioPCMBuffer` 播放、连接引擎图的是派生出来的非交错 `engineFormat`；
/// `enqueue()` 里手工做一次交错转非交错（按帧、按声道逐个采样搬过去，数据量
/// 很小，不值得为这个专门再拉一个 AVAudioConverter）。
///
/// 不额外加抖动缓冲，收到就立刻调度播放——雷雳桥接链路几乎不丢包不抖动，
/// 跟视频、光标两条通道同样的设计取舍：多缓一层只会增加延迟，不会提升体验。
final class AudioPlayer {
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let wireFormat: AVAudioFormat
    private let engineFormat: AVAudioFormat
    private var isRunning = false

    init(wireFormat: AVAudioFormat = AudioWireFormat.format) {
        self.wireFormat = wireFormat
        self.engineFormat = AVAudioFormat(
            commonFormat: wireFormat.commonFormat,
            sampleRate: wireFormat.sampleRate,
            channels: wireFormat.channelCount,
            interleaved: false
        )!
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: engineFormat)
    }

    func start() {
        guard !isRunning else { return }
        do {
            try engine.start()
            playerNode.play()
            isRunning = true
        } catch {
            fputs("[AudioPlayer] engine start failed: \(error)\n", stderr)
        }
    }

    func stop() {
        guard isRunning else { return }
        playerNode.stop()
        engine.stop()
        isRunning = false
    }

    func enqueue(_ payload: Data) {
        guard isRunning, !payload.isEmpty else { return }
        let bytesPerFrame = Int(wireFormat.streamDescription.pointee.mBytesPerFrame)
        let channelCount = Int(wireFormat.channelCount)
        guard bytesPerFrame > 0, channelCount > 0 else { return }
        let frameCount = Int(payload.count / bytesPerFrame)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: engineFormat, frameCapacity: AVAudioFrameCount(frameCount)),
              let channelData = buffer.floatChannelData
        else { return }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        payload.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let interleaved = raw.bindMemory(to: Float32.self).baseAddress else { return }
            for frame in 0..<frameCount {
                for channel in 0..<channelCount {
                    channelData[channel][frame] = interleaved[frame * channelCount + channel]
                }
            }
        }
        playerNode.scheduleBuffer(buffer)
    }
}

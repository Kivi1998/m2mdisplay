import XCTest
import M2MShared
@testable import M2MReceiverCore

final class AudioPlayerTests: XCTestCase {
    /// 真实踩过的坑：AudioWireFormat 是交错格式（方便网络传输），但直接拿它去
    /// connect AVAudioEngine 的节点图会在初始化时就直接 crash（AVAudioEngine
    /// 内部图要求非交错格式）。这个测试就是在验证 AudioPlayer 初始化不再崩溃——
    /// 第一版代码在这一步就直接 abort() 了，实机部署到 iMac 上才发现。
    func test播放器初始化不会崩溃() {
        let player = AudioPlayer()
        player.start()
        player.stop()
    }

    func test启动前入队音频数据会被安全忽略() {
        let player = AudioPlayer()
        let payload = Data(repeating: 0, count: 512)
        player.enqueue(payload) // 未 start()，不应该崩溃或产生任何效果
    }

    func test启动后可以入队交错PCM数据不崩溃() {
        let player = AudioPlayer()
        player.start()
        let frameCount = 256
        var samples = [Float32](repeating: 0, count: frameCount * 2)
        for i in 0..<samples.count {
            samples[i] = Float32(i % 100) / 100.0
        }
        let payload = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        player.enqueue(payload)
        player.stop()
    }
}

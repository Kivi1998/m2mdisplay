import XCTest
@testable import M2MReceiverCore

final class AudioRingBufferTests: XCTestCase {
    func test缓冲区容量固定并丢弃最旧音频() {
        let ring = AudioRingBuffer(capacityFrames: 8, primeFrames: 2)
        let samples = [Float32](repeating: 0.5, count: 12 * 2)
        let payload = samples.withUnsafeBytes { Data($0) }
        ring.write(payload: payload, frameCount: 12)

        XCTAssertEqual(ring.bufferedFrames, 8)
        XCTAssertEqual(ring.droppedFrames, 4)
    }

    func test停止前可清空全部缓冲状态() {
        let ring = AudioRingBuffer(capacityFrames: 8, primeFrames: 2)
        let samples = [Float32](repeating: 0.5, count: 4 * 2)
        ring.write(payload: samples.withUnsafeBytes { Data($0) }, frameCount: 4)
        ring.reset()

        XCTAssertEqual(ring.bufferedFrames, 0)
        XCTAssertEqual(ring.droppedFrames, 0)
        XCTAssertEqual(ring.underflowCount, 0)
    }
}

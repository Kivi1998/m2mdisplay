import AudioToolbox
import AVFAudio
import Foundation
import M2MShared

/// 固定容量的交错 Float32 环形缓冲。达到 20 ms 后才开始播放，最多保存 80 ms；
/// 若接收速度短暂超过播放速度，直接丢最旧数据，延迟不会像旧版
/// `scheduleBuffer` 那样无限增长到一秒以上。
final class AudioRingBuffer {
    private let lock = NSLock()
    private let channelCount = AudioWireFormat.channelCount
    private let capacityFrames: Int
    private let primeFrames: Int
    private var samples: [Float32]
    private var readFrame = 0
    private var writeFrame = 0
    private var storedFrames = 0
    private var primed = false
    private(set) var droppedFrames: UInt64 = 0
    private(set) var underflowCount: UInt64 = 0

    init(capacityFrames: Int = 3_840, primeFrames: Int = 960) {
        precondition(capacityFrames > primeFrames)
        self.capacityFrames = capacityFrames
        self.primeFrames = primeFrames
        samples = [Float32](repeating: 0, count: capacityFrames * channelCount)
    }

    var bufferedFrames: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedFrames
    }

    func write(payload: Data, frameCount: Int) {
        guard frameCount > 0,
              payload.count == frameCount * AudioWireFormat.bytesPerFrame
        else { return }
        payload.withUnsafeBytes { raw in
            guard let source = raw.bindMemory(to: Float32.self).baseAddress else { return }
            lock.lock()
            defer { lock.unlock() }
            for frame in 0..<frameCount {
                if storedFrames == capacityFrames {
                    readFrame = (readFrame + 1) % capacityFrames
                    storedFrames -= 1
                    droppedFrames += 1
                }
                let destination = writeFrame * channelCount
                let sourceOffset = frame * channelCount
                samples[destination] = source[sourceOffset]
                samples[destination + 1] = source[sourceOffset + 1]
                writeFrame = (writeFrame + 1) % capacityFrames
                storedFrames += 1
            }
        }
    }

    func render(frameCount requestedFrames: Int, into audioBufferList: UnsafeMutablePointer<AudioBufferList>) {
        let outputBuffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
        for buffer in outputBuffers {
            if let data = buffer.mData {
                data.initializeMemory(as: UInt8.self, repeating: 0, count: Int(buffer.mDataByteSize))
            }
        }

        lock.lock()
        defer { lock.unlock() }
        if !primed, storedFrames >= primeFrames { primed = true }
        guard primed else { return }

        let framesToRead = min(requestedFrames, storedFrames)
        for frame in 0..<framesToRead {
            let source = readFrame * channelCount
            for channel in 0..<min(channelCount, outputBuffers.count) {
                guard let output = outputBuffers[channel].mData?.assumingMemoryBound(to: Float32.self) else { continue }
                output[frame] = samples[source + channel]
            }
            readFrame = (readFrame + 1) % capacityFrames
            storedFrames -= 1
        }
        if framesToRead < requestedFrames {
            primed = false
            underflowCount += 1
        }
    }

    func reset() {
        lock.lock()
        readFrame = 0
        writeFrame = 0
        storedFrames = 0
        primed = false
        droppedFrames = 0
        underflowCount = 0
        lock.unlock()
    }
}

final class LowLatencyAudioPlayer {
    private let engine = AVAudioEngine()
    private let ringBuffer: AudioRingBuffer
    private let outputDeviceID: AudioDeviceID
    private let sourceNode: AVAudioSourceNode
    private var isRunning = false

    init(outputDeviceID: AudioDeviceID, ringBuffer: AudioRingBuffer = AudioRingBuffer()) {
        self.outputDeviceID = outputDeviceID
        self.ringBuffer = ringBuffer
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: AudioWireFormat.sampleRate,
            channels: AVAudioChannelCount(AudioWireFormat.channelCount),
            interleaved: false
        )!
        sourceNode = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList in
            ringBuffer.render(frameCount: Int(frameCount), into: audioBufferList)
            return noErr
        }
        engine.attach(sourceNode)
        engine.connect(sourceNode, to: engine.mainMixerNode, format: format)
    }

    func start() throws {
        guard !isRunning else { return }
        ringBuffer.reset()
        guard let audioUnit = engine.outputNode.audioUnit else {
            throw AudioOutputError.propertyUnavailable("播放设备")
        }
        var deviceID = outputDeviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else { throw AudioOutputError.coreAudio("指定 iMac 内建扬声器", status) }
        engine.prepare()
        try engine.start()
        isRunning = true
    }

    func enqueue(_ packet: AudioPacket) {
        guard isRunning else { return }
        ringBuffer.write(payload: packet.payload, frameCount: Int(packet.frameCount))
    }

    func stop() {
        guard isRunning else {
            ringBuffer.reset()
            return
        }
        engine.stop()
        ringBuffer.reset()
        isRunning = false
    }
}

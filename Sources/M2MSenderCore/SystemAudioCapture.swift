import CoreAudio
import Foundation
import M2MShared

enum SystemAudioCaptureError: LocalizedError {
    case coreAudio(String, OSStatus)
    case unsupportedFormat(AudioStreamBasicDescription)

    var errorDescription: String? {
        switch self {
        case .coreAudio(let operation, let status):
            return "\(operation)失败（Core Audio 状态码：\(status)）"
        case .unsupportedFormat(let format):
            return "系统音频格式不受支持：\(Int(format.mSampleRate)) Hz、\(format.mChannelsPerFrame) 声道、格式标记 \(format.mFormatFlags)"
        }
    }
}

/// Aggregate Device 写入 Tap 后会异步重建输入流；此时立刻启动 IOProc，HAL
/// 偶尔会返回 `nope`。只重试这个明确的过渡状态，其他错误立即交给调用方处理。
enum AudioDeviceStartRetrier {
    static func start(
        maxAttempts: Int = 20,
        delay: () -> Void = { Thread.sleep(forTimeInterval: 0.05) },
        operation: () -> OSStatus
    ) -> OSStatus {
        precondition(maxAttempts > 0)
        var status = operation()
        var attempt = 1
        while status == kAudioHardwareIllegalOperationError, attempt < maxAttempts {
            delay()
            status = operation()
            attempt += 1
        }
        return status
    }
}

/// 使用 Apple 在 macOS 14.2 提供的 Core Audio Process Tap 捕获整台 Mac 的输出。
/// `.mutedWhenTapped` 保证读取期间声音只进入 Tap，不再同时从 MacBook 扬声器播放；
/// 停止并销毁 Tap 后，系统自动恢复原来的输出路径和音量设置。
final class SystemAudioCapture {
    var onFrames: ((Data, UInt16) -> Void)?

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var isNonInterleaved = false
    private let callbackQueue = DispatchQueue(label: "com.kivi1998.m2mdisplay.audio-capture", qos: .userInteractive)

    func start() throws {
        guard tapID == kAudioObjectUnknown else { return }

        do {
            let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
            description.name = "M2M Display 系统音频"
            description.isPrivate = true
            description.muteBehavior = .mutedWhenTapped
            try check(AudioHardwareCreateProcessTap(description, &tapID), "创建系统音频 Tap")

            var formatAddress = AudioObjectPropertyAddress(
                mSelector: kAudioTapPropertyFormat,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            var format = AudioStreamBasicDescription()
            try check(
                AudioObjectGetPropertyData(tapID, &formatAddress, 0, nil, &formatSize, &format),
                "读取系统音频格式"
            )
            guard format.mFormatID == kAudioFormatLinearPCM,
                  format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                  format.mBitsPerChannel == 32,
                  format.mChannelsPerFrame == UInt32(AudioWireFormat.channelCount),
                  abs(format.mSampleRate - AudioWireFormat.sampleRate) < 1
            else {
                throw SystemAudioCaptureError.unsupportedFormat(format)
            }
            isNonInterleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0

            let aggregateDescription: [String: Any] = [
                kAudioAggregateDeviceNameKey: "M2M Display 私有音频设备",
                kAudioAggregateDeviceUIDKey: "com.kivi1998.m2mdisplay.audio.\(UUID().uuidString)",
                kAudioAggregateDeviceIsPrivateKey: true
            ]
            try check(
                AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregateID),
                "创建私有聚合音频设备"
            )
            try addTapToAggregateDevice()
            try waitForAggregateInputStream()

            try check(
                AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, callbackQueue) { [weak self] _, inputData, _, _, _ in
                    self?.consume(inputData)
                },
                "创建系统音频读取回调"
            )
            let startStatus = AudioDeviceStartRetrier.start {
                AudioDeviceStart(aggregateID, ioProcID)
            }
            try check(startStatus, "启动系统音频读取")
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown, let ioProcID {
            _ = AudioDeviceStop(aggregateID, ioProcID)
            _ = AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil
        if aggregateID != kAudioObjectUnknown {
            _ = AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            _ = AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    private func addTapToAggregateDevice() throws {
        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uidSize = UInt32(MemoryLayout<CFString>.stride)
        var tapUID: CFString = "" as CFString
        try withUnsafeMutablePointer(to: &tapUID) { pointer in
            try check(
                AudioObjectGetPropertyData(tapID, &uidAddress, 0, nil, &uidSize, pointer),
                "读取系统音频 Tap 标识"
            )
        }

        var listAddress = AudioObjectPropertyAddress(
            mSelector: kAudioAggregateDevicePropertyTapList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var listSize: UInt32 = 0
        try check(
            AudioObjectGetPropertyDataSize(aggregateID, &listAddress, 0, nil, &listSize),
            "读取聚合设备 Tap 列表大小"
        )
        var list: CFArray? = nil
        try withUnsafeMutablePointer(to: &list) { pointer in
            try check(
                AudioObjectGetPropertyData(aggregateID, &listAddress, 0, nil, &listSize, pointer),
                "读取聚合设备 Tap 列表"
            )
        }
        var values = list as? [CFString] ?? []
        if !values.contains(tapUID) {
            values.append(tapUID)
            listSize += UInt32(MemoryLayout<CFString>.stride)
        }
        list = values as CFArray
        try withUnsafeMutablePointer(to: &list) { pointer in
            try check(
                AudioObjectSetPropertyData(aggregateID, &listAddress, 0, nil, listSize, pointer),
                "把系统音频 Tap 加入聚合设备"
            )
        }
    }

    /// Tap 列表写入成功并不代表 Aggregate Device 已经同步产生输入流。等待可见的
    /// 输入流后再注册并启动 IOProc，避免连续创建时命中 HAL 的重配置窗口。
    private func waitForAggregateInputStream() throws {
        var streamsAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var lastStatus: OSStatus = kAudioHardwareNotReadyError
        for _ in 0..<40 {
            var size: UInt32 = 0
            lastStatus = AudioObjectGetPropertyDataSize(
                aggregateID,
                &streamsAddress,
                0,
                nil,
                &size
            )
            if lastStatus == noErr, size >= UInt32(MemoryLayout<AudioStreamID>.size) {
                return
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw SystemAudioCaptureError.coreAudio("等待聚合音频输入流就绪", lastStatus)
    }

    private func consume(_ inputData: UnsafePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        if isNonInterleaved {
            consumeNonInterleaved(buffers)
        } else {
            consumeInterleaved(buffers)
        }
    }

    private func consumeInterleaved(_ buffers: UnsafeMutableAudioBufferListPointer) {
        guard let buffer = buffers.first, let data = buffer.mData else { return }
        let frameCount = Int(buffer.mDataByteSize) / AudioWireFormat.bytesPerFrame
        guard frameCount > 0 else { return }
        let samples = data.assumingMemoryBound(to: Float32.self)
        var offset = 0
        while offset < frameCount {
            let count = min(AudioWireFormat.framesPerPacket, frameCount - offset)
            let byteCount = count * AudioWireFormat.bytesPerFrame
            let payload = Data(bytes: samples.advanced(by: offset * AudioWireFormat.channelCount), count: byteCount)
            onFrames?(payload, UInt16(count))
            offset += count
        }
    }

    private func consumeNonInterleaved(_ buffers: UnsafeMutableAudioBufferListPointer) {
        guard buffers.count >= AudioWireFormat.channelCount,
              let leftData = buffers[0].mData,
              let rightData = buffers[1].mData
        else { return }
        let left = leftData.assumingMemoryBound(to: Float32.self)
        let right = rightData.assumingMemoryBound(to: Float32.self)
        let leftFrames = Int(buffers[0].mDataByteSize) / MemoryLayout<Float32>.size
        let rightFrames = Int(buffers[1].mDataByteSize) / MemoryLayout<Float32>.size
        let frameCount = min(leftFrames, rightFrames)
        var offset = 0
        while offset < frameCount {
            let count = min(AudioWireFormat.framesPerPacket, frameCount - offset)
            var interleaved = [Float32](repeating: 0, count: count * AudioWireFormat.channelCount)
            for frame in 0..<count {
                interleaved[frame * 2] = left[offset + frame]
                interleaved[frame * 2 + 1] = right[offset + frame]
            }
            let payload = interleaved.withUnsafeBytes { Data($0) }
            onFrames?(payload, UInt16(count))
            offset += count
        }
    }

    private func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else { throw SystemAudioCaptureError.coreAudio(operation, status) }
    }

    deinit { stop() }
}

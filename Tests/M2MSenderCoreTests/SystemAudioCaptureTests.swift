import CoreAudio
import XCTest
@testable import M2MSenderCore

final class SystemAudioCaptureTests: XCTestCase {
    func test遇到聚合设备重配置错误会有限重试() {
        var statuses: [OSStatus] = [
            kAudioHardwareIllegalOperationError,
            kAudioHardwareIllegalOperationError,
            noErr,
        ]
        var delayCount = 0

        let result = AudioDeviceStartRetrier.start(maxAttempts: 5, delay: {
            delayCount += 1
        }) {
            statuses.removeFirst()
        }

        XCTAssertEqual(result, noErr)
        XCTAssertEqual(delayCount, 2)
        XCTAssertTrue(statuses.isEmpty)
    }

    func test其他CoreAudio错误不会被掩盖() {
        var callCount = 0
        let result = AudioDeviceStartRetrier.start(maxAttempts: 5, delay: {
            XCTFail("不应等待")
        }) {
            callCount += 1
            return kAudioHardwareBadObjectError
        }

        XCTAssertEqual(result, kAudioHardwareBadObjectError)
        XCTAssertEqual(callCount, 1)
    }

    func test重配置错误超过上限后原样返回() {
        var callCount = 0
        let result = AudioDeviceStartRetrier.start(maxAttempts: 3, delay: {}) {
            callCount += 1
            return kAudioHardwareIllegalOperationError
        }

        XCTAssertEqual(result, kAudioHardwareIllegalOperationError)
        XCTAssertEqual(callCount, 3)
    }
}

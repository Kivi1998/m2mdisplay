import Foundation
import IOKit.pwr_mgt

/// 发送端也必须保持显示器唤醒：系统空闲熄屏并锁屏后，ScreenCaptureKit 会失去
/// 虚拟桌面。这里只持有电源断言，不模拟用户输入，确保空闲停止计时仍可正常累积。
final class SenderPowerAssertion {
    typealias Create = (String) throws -> IOPMAssertionID
    typealias Release = (IOPMAssertionID) -> IOReturn

    private let lock = NSLock()
    private let create: Create
    private let release: Release
    private var assertionIDs: [IOPMAssertionID] = []

    init(
        create: @escaping Create = SenderPowerAssertion.createSystemAssertion,
        release: @escaping Release = { IOPMAssertionRelease($0) }
    ) {
        self.create = create
        self.release = release
    }

    func start() throws {
        try lock.withLock {
            guard assertionIDs.count != 2 else { return }
            let failures = releaseAssertions()
            guard failures.isEmpty else { throw ReleaseError(statuses: failures) }
            let displayID = try create(kIOPMAssertionTypePreventUserIdleDisplaySleep)
            // 第二项失败时，第一项也必须释放，避免启动失败却仍挡住熄屏。
            assertionIDs = [displayID]
            do {
                assertionIDs.append(try create(kIOPMAssertionTypePreventUserIdleSystemSleep))
            } catch {
                releaseAssertions()
                throw error
            }
        }
    }

    @discardableResult
    func stop() -> [IOReturn] {
        lock.withLock { releaseAssertions() }
    }

    @discardableResult
    private func releaseAssertions() -> [IOReturn] {
        var failures: [IOReturn] = []
        // 保留释放失败的 ID，正常收尾或析构时还能重试。
        assertionIDs = assertionIDs.filter { id in
            let status = release(id)
            if status != kIOReturnSuccess { failures.append(status) }
            return status != kIOReturnSuccess
        }
        return failures
    }

    private static func createSystemAssertion(type: String) throws -> IOPMAssertionID {
        var id: IOPMAssertionID = 0
        let status = IOPMAssertionCreateWithName(
            type as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "M2MSender 正在投屏，等待用户设置的无操作停止时间" as CFString,
            &id
        )
        guard status == kIOReturnSuccess else {
            throw CreationError(type: type, status: status)
        }
        return id
    }

    private struct CreationError: LocalizedError {
        let type: String
        let status: IOReturn

        var errorDescription: String? { "创建发送端电源断言失败：\(type)，错误码 \(status)" }
    }

    private struct ReleaseError: LocalizedError {
        let statuses: [IOReturn]
        var errorDescription: String? { "清理上一轮发送端电源断言失败：\(statuses)" }
    }

    deinit { stop() }
}

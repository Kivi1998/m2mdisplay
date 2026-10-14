import IOKit.pwr_mgt
import XCTest
@testable import M2MSenderCore

final class SenderPowerAssertionTests: XCTestCase {
    private enum TestError: Error { case creationFailed }

    func test重复启动不累积断言且停止后允许重新启动() throws {
        var createdTypes: [String] = []
        var releasedIDs: [IOPMAssertionID] = []
        let assertion = SenderPowerAssertion(create: { type in
            createdTypes.append(type)
            return IOPMAssertionID(createdTypes.count)
        }, release: { id in
            releasedIDs.append(id)
            return kIOReturnSuccess
        })

        try assertion.start()
        try assertion.start()
        XCTAssertEqual(createdTypes, [
            kIOPMAssertionTypePreventUserIdleDisplaySleep,
            kIOPMAssertionTypePreventUserIdleSystemSleep,
        ])
        XCTAssertTrue(assertion.stop().isEmpty)
        XCTAssertTrue(assertion.stop().isEmpty)
        XCTAssertEqual(releasedIDs, [1, 2])
        try assertion.start()
        XCTAssertEqual(createdTypes.count, 4)
        assertion.stop()
        XCTAssertEqual(releasedIDs, [1, 2, 3, 4])
    }

    func test第二项创建失败会回滚第一项并允许重试() throws {
        var attempts = 0
        var releasedIDs: [IOPMAssertionID] = []
        let assertion = SenderPowerAssertion(create: { _ in
            attempts += 1
            if attempts == 2 { throw TestError.creationFailed }
            return IOPMAssertionID(attempts)
        }, release: { id in
            releasedIDs.append(id)
            return kIOReturnSuccess
        })
        XCTAssertThrowsError(try assertion.start())
        XCTAssertEqual(releasedIDs, [1])
        try assertion.start()
        assertion.stop()
        XCTAssertEqual(releasedIDs, [1, 3, 4])
    }

    func test对象销毁会释放仍持有的断言() throws {
        var releasedIDs: [IOPMAssertionID] = []
        var nextID: IOPMAssertionID = 0
        var assertion: SenderPowerAssertion? = SenderPowerAssertion(create: { _ in
            nextID += 1
            return nextID
        }, release: { id in
            releasedIDs.append(id)
            return kIOReturnSuccess
        })
        try assertion?.start()
        assertion = nil
        XCTAssertEqual(releasedIDs, [1, 2])
    }

    func test释放失败会保留断言以便下次重试() throws {
        var nextID: IOPMAssertionID = 0
        var shouldFail = true
        var releasedIDs: [IOPMAssertionID] = []
        let assertion = SenderPowerAssertion(create: { _ in
            nextID += 1
            return nextID
        }, release: { id in
            if id == 1 && shouldFail { return kIOReturnError }
            releasedIDs.append(id)
            return kIOReturnSuccess
        })
        try assertion.start()
        XCTAssertEqual(assertion.stop(), [kIOReturnError])
        XCTAssertThrowsError(try assertion.start())
        XCTAssertEqual(nextID, 2)
        shouldFail = false
        XCTAssertTrue(assertion.stop().isEmpty)
        XCTAssertEqual(releasedIDs, [2, 1])
    }

    func test真实系统断言在启动后可查询且停止后消失() throws {
        var ids: [IOPMAssertionID] = []
        let assertion = SenderPowerAssertion(create: { type in
            var id: IOPMAssertionID = 0
            let status = IOPMAssertionCreateWithName(
                type as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "M2M 发送端电源断言回归测试" as CFString,
                &id
            )
            guard status == kIOReturnSuccess else { throw TestError.creationFailed }
            ids.append(id)
            return id
        })
        defer { assertion.stop() }
        try assertion.start()
        XCTAssertEqual(ids.count, 2)
        for id in ids { XCTAssertNotNil(IOPMAssertionCopyProperties(id)) }
        XCTAssertTrue(assertion.stop().isEmpty)
        for id in ids { XCTAssertNil(IOPMAssertionCopyProperties(id)) }
    }
}

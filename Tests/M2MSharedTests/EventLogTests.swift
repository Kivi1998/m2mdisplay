import XCTest
@testable import M2MShared

final class EventLogTests: XCTestCase {
    func testWriteAppendsTimestampedLineToLogFile() throws {
        let log = EventLog(role: "test-\(UUID().uuidString)")
        let expectation = expectation(description: "onEvent fired")
        log.onEvent = { message in
            XCTAssertEqual(message, "hello world")
            expectation.fulfill()
        }
        log.write(.info, "hello world")
        wait(for: [expectation], timeout: 1.0)
    }

    func testLogFileIsCreatedUnderLibraryLogs() throws {
        let role = "test-\(UUID().uuidString)"
        let log = EventLog(role: role)
        log.write(.error, "boom")
        Thread.sleep(forTimeInterval: 0.2) // 等后台队列把内容写完

        let expectedPath = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/M2MDisplay/\(role).log")
        let contents = try String(contentsOf: expectedPath, encoding: .utf8)
        XCTAssertTrue(contents.contains("[ERROR] boom"))
    }
}

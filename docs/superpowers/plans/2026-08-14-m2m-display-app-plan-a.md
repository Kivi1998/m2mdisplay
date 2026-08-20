# M2M Display App — Plan A: Menu Bar Shell + Local Start/Stop

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the current "SSH in, `swift build`, `scp`, `nohup ... &`" workflow with a real menu bar app on both machines that lets you pick a role, and start/stop casting with a button — including automatic recovery from the ScreenCaptureKit stream-death bug found on 2026-08-14.

**Architecture:** Split the existing `M2MSender`/`M2MReceiver` executables into library targets (`M2MSenderCore`/`M2MReceiverCore`) exposing `SenderEngine`/`ReceiverEngine` classes with `start()`/`stop()` and a state callback, plus thin CLI executables that keep today's command-line workflow working for debugging. A new `M2MApp` SwiftUI `MenuBarExtra` target drives the engines from a GUI.

**Tech Stack:** Swift 5.10, SwiftUI (`MenuBarExtra`, macOS 14+), existing ScreenCaptureKit/VideoToolbox/Network.framework/CGVirtualDisplay code (unchanged internals, just relocated).

**Spec:** `docs/superpowers/specs/2026-08-14-m2m-display-app-design.md`

## Global Constraints

- macOS 14+ only (existing `Package.swift` platform floor — do not lower it).
- Never run `M2MReceiverCLI`, `M2MApp` in receiver role, or anything that creates a full-screen overlay window, on the MacBook Pro — only ever test the receiver role on the real iMac (`ssh kivi@10.10.10.2`). This is a hard rule from prior incidents, not a style preference.
- 当前实现已在 2026-08-20 根据真实使用反馈调整：虚拟显示器在“开始投屏”时创建、
  在“停止投屏”时销毁并等待离线，使第二屏上的窗口回到 MacBook Pro 内置屏幕。
  原计划的“保持到 App 退出”会留下不可见的幽灵桌面，已由更新后的设计规格取代。
- Every engine-level state transition and every unexpected failure must go through `EventLog` (Task 1) — no `print`/`fputs`-only error paths in the engines.
- Deploy/verify exactly like the rest of this project has been verified all along: `swift build -c release`, `scp` the receiver binary to the iMac, `ssh` to restart it, check the log file's mtime/line count to confirm it's actually running the new build. No test target exists yet for anything ScreenCaptureKit/CGVirtualDisplay/AppKit-dependent — those are verified by hand on real hardware, not by automated tests.

## Out of scope for this plan (see spec, deferred to Plan B)

Cross-device state-sync protocol messages, the iMac global-hotkey toggle (and its Input Monitoring permission requirement), the MacBook optional global hotkey, the guided permission sheets with deep links to System Settings, and the connection-method/resolution editing UI beyond a fixed default. Plan A hard-codes 1920×1080 @ 2x and the existing `NetworkConfig`/`Endpoints` host resolution (env var override still works) — Plan B makes those user-editable.

---

### Task 1: `EventLog` — persistent, timestamped event logging

**Files:**
- Create: `Sources/M2MShared/EventLog.swift`
- Create: `Tests/M2MSharedTests/EventLogTests.swift`
- Modify: `Package.swift` (add test target)

**Interfaces:**
- Produces: `public enum EventLogLevel: String { case info, warning, error }`, `public final class EventLog { public init(role: String); public var onEvent: ((String) -> Void)?; public func write(_ level: EventLogLevel, _ message: String) }`. `SenderEngine` and `ReceiverEngine` (Tasks 4, 5) both own one and call `.write(...)` on every state transition and failure.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/M2MSharedTests/EventLogTests.swift
import XCTest
@testable import M2MShared

final class EventLogTests: XCTestCase {
    func testWriteAppendsTimestampedLineToLogFile() throws {
        let log = EventLog(role: "test-\(UUID().uuidString)")
        log.write(.info, "hello world")

        // write() dispatches to a background queue; give it a moment to land.
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
        Thread.sleep(forTimeInterval: 0.2) // background queue write

        let expectedPath = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/M2MDisplay/\(role).log")
        let contents = try String(contentsOf: expectedPath, encoding: .utf8)
        XCTAssertTrue(contents.contains("[ERROR] boom"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter EventLogTests`
Expected: FAIL to compile — `EventLog` does not exist yet.

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/M2MShared/EventLog.swift
import Foundation

public enum EventLogLevel: String {
    case info = "INFO"
    case warning = "WARN"
    case error = "ERROR"
}

/// Persistent, timestamped event log, one file per role, under
/// ~/Library/Logs/M2MDisplay/. Replaces the current practice of piping
/// process stdout to a throwaway /tmp file with `nohup` — those don't
/// survive a restart and require SSH-ing in to read.
public final class EventLog {
    private let fileURL: URL
    private let queue = DispatchQueue(label: "com.m2mdisplay.eventlog")

    /// Fires on the main thread after every write, for UI "最近事件" lists.
    public var onEvent: ((String) -> Void)?

    public init(role: String) {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/M2MDisplay", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("\(role).log")
    }

    public func write(_ level: EventLogLevel, _ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] [\(level.rawValue)] \(message)\n"
        queue.async { [fileURL] in
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: fileURL)
            }
        }
        fputs(line, stderr)
        DispatchQueue.main.async { [weak self] in self?.onEvent?(message) }
    }
}
```

- [ ] **Step 4: Add the test target to Package.swift**

```swift
// Add to the targets array in Package.swift, after the M2MShared target:
.testTarget(
    name: "M2MSharedTests",
    dependencies: ["M2MShared"],
    path: "Tests/M2MSharedTests"
),
```

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --filter EventLogTests`
Expected: PASS (both tests)

- [ ] **Step 6: Commit**

```bash
git add Sources/M2MShared/EventLog.swift Tests/M2MSharedTests/EventLogTests.swift Package.swift
git commit -m "Add persistent EventLog for engine state/error logging"
```

---

### Task 2: Split `M2MSender` into `M2MSenderCore` (library) + `M2MSenderCLI` (thin executable)

**Files:**
- Move: `Sources/M2MSender/AckReceiver.swift` → `Sources/M2MSenderCore/AckReceiver.swift`
- Move: `Sources/M2MSender/Capturer.swift` → `Sources/M2MSenderCore/Capturer.swift`
- Move: `Sources/M2MSender/Encoder.swift` → `Sources/M2MSenderCore/Encoder.swift`
- Move: `Sources/M2MSender/MouseTap.swift` → `Sources/M2MSenderCore/MouseTap.swift`
- Move: `Sources/M2MSender/NetworkOut.swift` → `Sources/M2MSenderCore/NetworkOut.swift`
- Move: `Sources/M2MSender/VirtualDisplay.swift` → `Sources/M2MSenderCore/VirtualDisplay.swift`
- Create: `Sources/M2MSenderCLI/main.swift`
- Delete: `Sources/M2MSender/main.swift` (its logic moves into `SenderEngine` in Task 3)
- Modify: `Package.swift`

**Interfaces:**
- Consumes: nothing new — these files are unchanged, only relocated.
- Produces: `M2MSenderCore` library target other targets (`M2MSenderCLI`, `M2MApp`) can `import`.

- [ ] **Step 1: Move the files with git mv (preserves history)**

```bash
mkdir -p Sources/M2MSenderCore Sources/M2MSenderCLI
git mv Sources/M2MSender/AckReceiver.swift Sources/M2MSenderCore/AckReceiver.swift
git mv Sources/M2MSender/Capturer.swift Sources/M2MSenderCore/Capturer.swift
git mv Sources/M2MSender/Encoder.swift Sources/M2MSenderCore/Encoder.swift
git mv Sources/M2MSender/MouseTap.swift Sources/M2MSenderCore/MouseTap.swift
git mv Sources/M2MSender/NetworkOut.swift Sources/M2MSenderCore/NetworkOut.swift
git mv Sources/M2MSender/VirtualDisplay.swift Sources/M2MSenderCore/VirtualDisplay.swift
git rm Sources/M2MSender/main.swift
rmdir Sources/M2MSender
```

- [ ] **Step 2: Update Package.swift**

Replace the `M2MSender` executable target with a library target plus a thin CLI target:

```swift
// Replace this:
//   .executableTarget(
//       name: "M2MSender",
//       dependencies: ["M2MShared", "CGVirtualDisplayShim"],
//       path: "Sources/M2MSender"
//   ),
// with:
.target(
    name: "M2MSenderCore",
    dependencies: ["M2MShared", "CGVirtualDisplayShim"],
    path: "Sources/M2MSenderCore"
),
.executableTarget(
    name: "M2MSenderCLI",
    dependencies: ["M2MSenderCore", "M2MShared"],
    path: "Sources/M2MSenderCLI"
),
```

- [ ] **Step 3: Add a placeholder main.swift so the package still builds (real content lands in Task 3)**

```swift
// Sources/M2MSenderCLI/main.swift
print("M2MSenderCLI: engine wiring lands in the next task")
```

- [ ] **Step 4: Verify the package still resolves and builds**

Run: `swift build`
Expected: builds successfully (M2MSenderCore compiles as a library, M2MSenderCLI compiles as a trivial executable). Warnings about unused files are fine at this stage — nothing calls into M2MSenderCore's classes yet.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "Split M2MSender into M2MSenderCore library + M2MSenderCLI thin executable"
```

---

### Task 3: `SenderEngine` — start/stop with automatic capture-stream recovery

**Files:**
- Create: `Sources/M2MSenderCore/SenderEngine.swift`

**Interfaces:**
- Consumes: `VirtualDisplay` (`Sources/M2MSenderCore/VirtualDisplay.swift`, `init?(name:logicalWidth:logicalHeight:backingScale:refreshRate:widthMM:heightMM:)`, properties `displayID`, `logicalWidth`, `logicalHeight`, `pixelWidth`, `pixelHeight`), `FrameCapturer` (`init(displayID:width:height:)`, `var onFrame`, `var onStreamStopped`, `func start() async throws`, `func stop() async`), `VideoEncoder` (`init(width:height:frameRate:averageBitrateBps:) throws`, `var onEncodedFrame`, `func encode(_:)`, `func invalidate()`), `VideoSender`/`CursorSender` (`Sources/M2MSenderCore/NetworkOut.swift`), `MouseTap` (`init(virtualDisplayID:width:height:)`, `var onPosition`, `func start() -> Bool`, `func stop()`), `AckReceiver` (`func start(port:) throws`, `func stop()`), `EventLog` (Task 1), `NetworkConfig`/`Endpoints` (`Sources/M2MShared`), `CursorPacket` (`Sources/M2MShared/Protocol.swift`).
- Produces: `public enum SenderState: Equatable { case idle, starting, running, reconnecting, error(String), stopping }`, `public final class SenderEngine { public init(); public var onStateChange: ((SenderState) -> Void)?; public private(set) var state: SenderState; public func prepareVirtualDisplay(width: Int, height: Int, backingScale: Int) -> Bool; public func start(receiverHost: String) async; public func stop() async }`. `AppState` (Task 8) and `M2MSenderCLI/main.swift` (Task 6) both drive this class.

- [ ] **Step 1: Write the implementation**

```swift
// Sources/M2MSenderCore/SenderEngine.swift
import Foundation
import M2MShared

public enum SenderState: Equatable {
    case idle
    case starting
    case running
    case reconnecting
    case error(String)
    case stopping
}

/// Owns the full sender-side pipeline (virtual display, capture, encode,
/// network, mouse tracking) behind start()/stop(). The virtual display is
/// created once by prepareVirtualDisplay() and kept alive for the engine's
/// lifetime — see the "虚拟显示器生命周期" section of the design spec for why
/// recreating it on every start/stop cycle is unsafe.
public final class SenderEngine {
    public private(set) var state: SenderState = .idle {
        didSet { onStateChange?(state) }
    }
    public var onStateChange: ((SenderState) -> Void)?

    private let log = EventLog(role: "sender")
    private var virtualDisplay: VirtualDisplay?
    private var capturer: FrameCapturer?
    private var encoder: VideoEncoder?
    private var videoSender: VideoSender?
    private var cursorSender: CursorSender?
    private var mouseTap: MouseTap?
    private var ackReceiver: AckReceiver?
    private var cursorSeq: UInt32 = 0

    public init() {}

    @discardableResult
    public func prepareVirtualDisplay(width: Int, height: Int, backingScale: Int) -> Bool {
        guard virtualDisplay == nil else { return true }
        guard let display = VirtualDisplay(
            name: "M2M Display",
            logicalWidth: width,
            logicalHeight: height,
            backingScale: backingScale,
            refreshRate: 60,
            widthMM: 508,
            heightMM: 285
        ) else {
            log.write(.error, "failed to create virtual display")
            return false
        }
        virtualDisplay = display
        log.write(.info, "virtual display ready: looks like \(display.logicalWidth)x\(display.logicalHeight), backing pixels \(display.pixelWidth)x\(display.pixelHeight)")
        return true
    }

    public func start(receiverHost: String) async {
        guard let virtualDisplay else {
            state = .error("virtual display not ready — call prepareVirtualDisplay first")
            return
        }
        guard state == .idle else { return }
        state = .starting
        log.write(.info, "starting cast to \(receiverHost)")

        let videoSender = VideoSender(host: receiverHost, port: NetworkConfig.videoPort)
        self.videoSender = videoSender
        let cursorSender = CursorSender(host: receiverHost, port: NetworkConfig.cursorPort)
        self.cursorSender = cursorSender

        let mouseTap = MouseTap(virtualDisplayID: virtualDisplay.displayID, width: virtualDisplay.logicalWidth, height: virtualDisplay.logicalHeight)
        self.mouseTap = mouseTap
        mouseTap.onPosition = { [weak self] x, y, isVisible in
            guard let self else { return }
            self.cursorSeq += 1
            self.cursorSender?.send(CursorPacket(x: x, y: y, cursorType: CursorType.arrow.rawValue, sequence: self.cursorSeq, isVisible: isVisible))
        }

        let ackReceiver = AckReceiver()
        self.ackReceiver = ackReceiver
        try? ackReceiver.start(port: NetworkConfig.ackPort)

        if !mouseTap.start() {
            log.write(.warning, "mouse tap failed to start — missing Input Monitoring permission")
        }

        do {
            try await videoSender.waitUntilReady()
        } catch {
            state = .error("video connection failed: \(error)")
            log.write(.error, "video connection failed: \(error)")
            return
        }

        guard await startCapturePipeline(retryCount: 0) else { return }
        state = .running
        log.write(.info, "running")
    }

    public func stop() async {
        guard state == .running || state == .reconnecting || isErrorState else { return }
        state = .stopping
        log.write(.info, "stopping (user requested)")
        await teardownCapturePipeline()
        videoSender?.stop()
        cursorSender?.stop()
        mouseTap?.stop()
        ackReceiver?.stop()
        videoSender = nil
        cursorSender = nil
        mouseTap = nil
        ackReceiver = nil
        state = .idle
        log.write(.info, "stopped")
    }

    private var isErrorState: Bool {
        if case .error = state { return true }
        return false
    }

    /// (Re)creates the ScreenCaptureKit stream and encoder. Called from
    /// start() and from the unexpected-stop recovery path below — those are
    /// the only two pieces that need recreating after a capture failure;
    /// the virtual display and network connections stay untouched.
    private func startCapturePipeline(retryCount: Int) async -> Bool {
        guard let virtualDisplay else { return false }
        guard let encoder = try? VideoEncoder(width: virtualDisplay.pixelWidth, height: virtualDisplay.pixelHeight, frameRate: 60, averageBitrateBps: 60_000_000) else {
            state = .error("failed to create encoder")
            log.write(.error, "failed to create encoder")
            return false
        }
        self.encoder = encoder
        let capturer = FrameCapturer(displayID: virtualDisplay.displayID, width: virtualDisplay.pixelWidth, height: virtualDisplay.pixelHeight)
        self.capturer = capturer

        encoder.onEncodedFrame = { [weak self] frame in
            self?.videoSender?.send(frame)
        }
        capturer.onFrame = { [weak encoder] sampleBuffer in
            encoder?.encode(sampleBuffer)
        }
        capturer.onStreamStopped = { [weak self] error in
            self?.log.write(.warning, "capture stream stopped unexpectedly: \(String(describing: error))")
            self?.recoverFromCaptureStop()
        }

        do {
            try await capturer.start()
            return true
        } catch {
            if retryCount < 3 {
                log.write(.warning, "capture start attempt \(retryCount + 1) failed: \(error), retrying")
                try? await Task.sleep(nanoseconds: 300_000_000)
                return await startCapturePipeline(retryCount: retryCount + 1)
            }
            state = .error("capture failed to start: \(error)")
            log.write(.error, "capture failed to start after \(retryCount + 1) attempts: \(error)")
            return false
        }
    }

    private func teardownCapturePipeline() async {
        await capturer?.stop()
        encoder?.invalidate()
        capturer = nil
        encoder = nil
    }

    private func recoverFromCaptureStop() {
        guard state == .running else { return } // a user-initiated stop already tore this down
        Task {
            state = .reconnecting
            log.write(.info, "attempting automatic recovery")
            await teardownCapturePipeline()
            if await startCapturePipeline(retryCount: 0) {
                state = .running
                log.write(.info, "recovered")
            }
        }
    }
}
```

- [ ] **Step 2: Verify it builds**

Run: `swift build`
Expected: `M2MSenderCore` compiles with `SenderEngine.swift` included. (No automated test here — `SCStream`/`CGVirtualDisplay`/network I/O aren't practical to unit test; this is a class of code this project has only ever validated by running it on real hardware, consistent with everything else in `M2MSenderCore`.)

- [ ] **Step 3: Commit**

```bash
git add Sources/M2MSenderCore/SenderEngine.swift
git commit -m "Add SenderEngine with start/stop and automatic capture-stream recovery"
```

---

### Task 4: Split `M2MReceiver` into `M2MReceiverCore` (library) + `M2MReceiverCLI` (thin executable)

**Files:**
- Move: `Sources/M2MReceiver/AckSender.swift` → `Sources/M2MReceiverCore/AckSender.swift`
- Move: `Sources/M2MReceiver/Decoder.swift` → `Sources/M2MReceiverCore/Decoder.swift`
- Move: `Sources/M2MReceiver/DisplayView.swift` → `Sources/M2MReceiverCore/DisplayView.swift`
- Move: `Sources/M2MReceiver/EscapeHatch.swift` → `Sources/M2MReceiverCore/EscapeHatch.swift`
- Move: `Sources/M2MReceiver/NetworkIn.swift` → `Sources/M2MReceiverCore/NetworkIn.swift`
- Move: `Sources/M2MReceiver/PowerAssertion.swift` → `Sources/M2MReceiverCore/PowerAssertion.swift`
- Create: `Sources/M2MReceiverCLI/main.swift`
- Create: `Sources/M2MReceiverCLI/AppDelegate.swift`
- Delete: `Sources/M2MReceiver/main.swift`, `Sources/M2MReceiver/AppDelegate.swift` (logic moves into `ReceiverEngine` in Task 5)
- Modify: `Package.swift`

**Interfaces:**
- Produces: `M2MReceiverCore` library target other targets (`M2MReceiverCLI`, `M2MApp`) can `import`.

- [ ] **Step 1: Move the files with git mv**

```bash
mkdir -p Sources/M2MReceiverCore Sources/M2MReceiverCLI
git mv Sources/M2MReceiver/AckSender.swift Sources/M2MReceiverCore/AckSender.swift
git mv Sources/M2MReceiver/Decoder.swift Sources/M2MReceiverCore/Decoder.swift
git mv Sources/M2MReceiver/DisplayView.swift Sources/M2MReceiverCore/DisplayView.swift
git mv Sources/M2MReceiver/EscapeHatch.swift Sources/M2MReceiverCore/EscapeHatch.swift
git mv Sources/M2MReceiver/NetworkIn.swift Sources/M2MReceiverCore/NetworkIn.swift
git mv Sources/M2MReceiver/PowerAssertion.swift Sources/M2MReceiverCore/PowerAssertion.swift
git rm Sources/M2MReceiver/main.swift Sources/M2MReceiver/AppDelegate.swift
rmdir Sources/M2MReceiver
```

- [ ] **Step 2: Update Package.swift**

```swift
// Replace this:
//   .executableTarget(
//       name: "M2MReceiver",
//       dependencies: ["M2MShared"],
//       path: "Sources/M2MReceiver"
//   ),
// with:
.target(
    name: "M2MReceiverCore",
    dependencies: ["M2MShared"],
    path: "Sources/M2MReceiverCore"
),
.executableTarget(
    name: "M2MReceiverCLI",
    dependencies: ["M2MReceiverCore", "M2MShared"],
    path: "Sources/M2MReceiverCLI"
),
```

- [ ] **Step 3: Add placeholder files so the package still builds**

```swift
// Sources/M2MReceiverCLI/main.swift
print("M2MReceiverCLI: engine wiring lands in the next task")
```

- [ ] **Step 4: Verify the package still resolves and builds**

Run: `swift build`
Expected: builds successfully.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "Split M2MReceiver into M2MReceiverCore library + M2MReceiverCLI thin executable"
```

---

### Task 5: `ReceiverEngine` — window lifecycle decoupled from process lifecycle

**Files:**
- Create: `Sources/M2MReceiverCore/ReceiverEngine.swift`

**Interfaces:**
- Consumes: `DisplayView` (`Sources/M2MReceiverCore/DisplayView.swift`, `init(frame:)`, `func updateCursor(normalizedX:normalizedY:)`, `func hideCursor()`, `func enqueue(_:)`), `VideoReceiver`/`CursorReceiver` (`Sources/M2MReceiverCore/NetworkIn.swift`), `SampleBufferBuilder` (`Sources/M2MReceiverCore/Decoder.swift`), `EscapeHatch` (`func start() -> Bool`), `PowerAssertion` (`func start() -> Bool`, `func stop()`), `AckSender` (`init(host:port:)`, `func send(_:)`), `EventLog` (Task 1), `Endpoints`/`NetworkConfig`/`AckPacket`/`CursorPacket` (`Sources/M2MShared`).
- Produces: `public enum ReceiverState: Equatable { case idle, listening, casting, error(String) }`, `public final class ReceiverEngine { public init(); public var onStateChange: ((ReceiverState) -> Void)?; public private(set) var state: ReceiverState; public func prepareWindow(); public func showCast(); public func hideCast(); public func handleDidBecomeActive(); public func handleWillResignActive(); public func shutdown() }`. `AppState` (Task 8) and `M2MReceiverCLI/AppDelegate.swift` (Task 6) both drive this class.

- [ ] **Step 1: Write the implementation**

```swift
// Sources/M2MReceiverCore/ReceiverEngine.swift
import AppKit
import CoreGraphics
import CoreMedia
import M2MShared

public enum ReceiverState: Equatable {
    case idle
    case listening
    case casting
    case error(String)
}

private final class ReceiverWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Owns the receiver-side overlay window and network listeners. Casting is a
/// separate toggle (showCast()/hideCast()) from the window/listeners
/// themselves (prepareWindow()) — the window is created once, hidden by
/// default, and network listeners stay up across a hide/show cycle so
/// toggling casting back on doesn't need the sender to reconnect.
public final class ReceiverEngine {
    public private(set) var state: ReceiverState = .idle {
        didSet { onStateChange?(state) }
    }
    public var onStateChange: ((ReceiverState) -> Void)?

    private let log = EventLog(role: "receiver")
    private var window: NSWindow!
    private var displayView: DisplayView!
    private let videoReceiver = VideoReceiver()
    private let cursorReceiver = CursorReceiver()
    private var formatDescription: CMFormatDescription?
    private let cursorSpaceWidth = 1920
    private let cursorSpaceHeight = 1080
    private let videoPixelWidth = 3840
    private let videoPixelHeight = 2160
    private let escapeHatch = EscapeHatch()
    private let powerAssertion = PowerAssertion()
    private var immersiveModeEnabled = false
    private var nativeCursorHidden = false
    private var isCasting = false
    private lazy var ackSender = AckSender(host: Endpoints.senderHost, port: NetworkConfig.ackPort)

    public init() {}

    private func physicalScreen() -> NSScreen {
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
            if CGDisplayIsBuiltin(CGDirectDisplayID(number.uint32Value)) != 0 { return screen }
        }
        return NSScreen.main ?? NSScreen.screens[0]
    }

    /// Creates the (initially hidden) overlay window and starts listening
    /// for a sender connection. Call once at app launch.
    public func prepareWindow() {
        let screenFrame = physicalScreen().frame
        window = ReceiverWindow(contentRect: screenFrame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.backgroundColor = .black
        window.isOpaque = true
        window.ignoresMouseEvents = true // 当前部署方式未连接本机输入设备，详见项目说明
        window.collectionBehavior = [.stationary, .ignoresCycle]
        displayView = DisplayView(frame: window.contentView?.bounds ?? screenFrame)
        displayView.autoresizingMask = [.width, .height]
        window.contentView = displayView
        window.setFrame(screenFrame, display: true)
        window.level = .floating
        window.orderOut(nil)

        if escapeHatch.start() {
            log.write(.info, "escape hatch armed — triple-tap Escape to hide cast")
        } else {
            log.write(.warning, "escape hatch failed to start — cast can only be hidden via the app UI or SSH")
        }

        videoReceiver.onConnected = { [weak self] in self?.log.write(.info, "sender connected") }
        videoReceiver.onFrame = { [weak self] frame in self?.handle(frame) }
        cursorReceiver.onCursor = { [weak self] packet in self?.handleCursor(packet) }

        do {
            try videoReceiver.start(port: NetworkConfig.videoPort)
            try cursorReceiver.start(port: NetworkConfig.cursorPort)
            state = .listening
            log.write(.info, "listening — video:\(NetworkConfig.videoPort) cursor:\(NetworkConfig.cursorPort)")
        } catch {
            state = .error("failed to start listeners: \(error)")
            log.write(.error, "failed to start listeners: \(error)")
        }
    }

    /// Shows the fullscreen overlay and enters immersive mode (hides Dock,
    /// menu bar, and iMac's own cursor). Idempotent.
    public func showCast() {
        guard !isCasting else { return }
        isCasting = true
        immersiveModeEnabled = true
        window.level = .screenSaver
        NSApp.setActivationPolicy(.accessory)
        window.makeKeyAndOrderFront(nil)
        NSApp.presentationOptions = [.hideDock, .hideMenuBar, .disableCursorLocationAssistance]
        NSApp.activate(ignoringOtherApps: true)
        window.orderFrontRegardless()
        hideNativeCursorIfNeeded()
        if powerAssertion.start() {
            log.write(.info, "power assertion active")
        }
        state = .casting
        log.write(.info, "cast shown")
    }

    /// Hides the overlay and restores the iMac's own desktop. Network
    /// listeners stay up so casting can be toggled back on without the
    /// sender reconnecting. Idempotent.
    public func hideCast() {
        guard isCasting else { return }
        isCasting = false
        immersiveModeEnabled = false
        NSApp.presentationOptions = []
        window.orderOut(nil)
        showNativeCursorIfNeeded()
        powerAssertion.stop()
        state = .listening
        log.write(.info, "cast hidden")
    }

    public func handleDidBecomeActive() {
        guard immersiveModeEnabled else { return }
        window.level = .screenSaver
        window.orderFrontRegardless()
        hideNativeCursorIfNeeded()
    }

    public func handleWillResignActive() {
        guard immersiveModeEnabled else { return }
        showNativeCursorIfNeeded()
        window.level = .floating
    }

    public func shutdown() {
        showNativeCursorIfNeeded()
        NSApp.presentationOptions = []
        powerAssertion.stop()
        log.write(.info, "shutting down")
    }

    private func handle(_ frame: ReceivedFrame) {
        if let avcC = frame.avcC {
            formatDescription = SampleBufferBuilder.formatDescription(width: videoPixelWidth, height: videoPixelHeight, avcC: avcC)
        }
        guard let formatDescription,
              let sampleBuffer = SampleBufferBuilder.sampleBuffer(payload: frame.payload, formatDescription: formatDescription) else { return }
        DispatchQueue.main.async { [weak self] in self?.displayView.enqueue(sampleBuffer) }
    }

    private func handleCursor(_ packet: CursorPacket) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if packet.isVisible {
                self.displayView.updateCursor(normalizedX: CGFloat(packet.x) / CGFloat(self.cursorSpaceWidth),
                                               normalizedY: CGFloat(packet.y) / CGFloat(self.cursorSpaceHeight))
            } else {
                self.displayView.hideCursor()
            }
            self.ackSender.send(AckPacket(sequence: packet.sequence))
        }
    }

    private func hideNativeCursorIfNeeded() {
        guard immersiveModeEnabled, !nativeCursorHidden, NSApp.isActive else { return }
        let result = CGDisplayHideCursor(CGMainDisplayID())
        if result == .success { nativeCursorHidden = true }
    }

    private func showNativeCursorIfNeeded() {
        guard nativeCursorHidden else { return }
        CGDisplayShowCursor(CGMainDisplayID())
        nativeCursorHidden = false
    }
}
```

- [ ] **Step 2: Verify it builds**

Run: `swift build`
Expected: `M2MReceiverCore` compiles with `ReceiverEngine.swift` included.

- [ ] **Step 3: Commit**

```bash
git add Sources/M2MReceiverCore/ReceiverEngine.swift
git commit -m "Add ReceiverEngine with cast show/hide decoupled from process lifecycle"
```

---

### Task 6: Wire the thin CLIs to the new engines (preserve today's command-line workflow)

**Files:**
- Modify: `Sources/M2MSenderCLI/main.swift`
- Modify: `Sources/M2MReceiverCLI/main.swift`
- Create: `Sources/M2MReceiverCLI/AppDelegate.swift`

**Interfaces:**
- Consumes: `SenderEngine` (Task 3), `ReceiverEngine` (Task 5), `Endpoints` (`Sources/M2MShared/Endpoints.swift`).

- [ ] **Step 1: Sender CLI**

```swift
// Sources/M2MSenderCLI/main.swift
import Foundation
import M2MSenderCore
import M2MShared

setvbuf(stdout, nil, _IOLBF, 0)

signal(SIGINT) { _ in
    print("\nCaught SIGINT, exiting")
    exit(0)
}

let engine = SenderEngine()
engine.onStateChange = { state in print("[SenderEngine] state: \(state)") }

guard engine.prepareVirtualDisplay(width: 1920, height: 1080, backingScale: 2) else {
    fputs("Failed to create virtual display\n", stderr)
    exit(1)
}

Task {
    await engine.start(receiverHost: Endpoints.receiverHost)
}

// dispatchMain() only pumps the main GCD queue — MouseTap's CGEventTap run
// loop source needs CFRunLoopRun() directly (see MouseTap.swift for the
// full history of this bug).
CFRunLoopRun()
```

- [ ] **Step 2: Receiver CLI entry point**

```swift
// Sources/M2MReceiverCLI/main.swift
import AppKit

setvbuf(stdout, nil, _IOLBF, 0)

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
```

- [ ] **Step 3: Receiver CLI app delegate**

```swift
// Sources/M2MReceiverCLI/AppDelegate.swift
import AppKit
import M2MReceiverCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let engine = ReceiverEngine()

    func applicationDidFinishLaunching(_ notification: Notification) {
        engine.onStateChange = { state in print("[ReceiverEngine] state: \(state)") }
        engine.prepareWindow()
        engine.showCast() // CLI preserves today's "always casting once launched" behavior
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationDidBecomeActive(_ notification: Notification) { engine.handleDidBecomeActive() }
    func applicationWillResignActive(_ notification: Notification) { engine.handleWillResignActive() }
    func applicationWillTerminate(_ notification: Notification) { engine.shutdown() }
}
```

- [ ] **Step 4: Build both CLI executables**

Run: `swift build -c release`
Expected: `M2MSenderCLI` and `M2MReceiverCLI` both build. `swift build -c release 2>&1 | tail -20` should end with `Build complete!`.

- [ ] **Step 5: Commit**

```bash
git add Sources/M2MSenderCLI/main.swift Sources/M2MReceiverCLI/main.swift Sources/M2MReceiverCLI/AppDelegate.swift
git commit -m "Wire thin CLI executables to SenderEngine/ReceiverEngine"
```

---

### Task 7: End-to-end verification of the refactored CLIs (no behavior regressions)

**Files:** none (verification only)

- [ ] **Step 1: Deploy the new receiver CLI binary to the iMac**

```bash
scp .build/release/M2MReceiverCLI kivi@10.10.10.2:~/m2mdisplay/M2MReceiverCLI
ssh kivi@10.10.10.2 'ls -la ~/m2mdisplay/M2MReceiverCLI'
```

Expected: the `ls -la` timestamp matches "just now" — confirms the binary actually transferred (this project has previously shipped a stale binary by mistake; always verify the timestamp).

- [ ] **Step 2: Stop whatever old sender/receiver processes are running, start the new ones**

```bash
pgrep -fl M2MSender && kill $(pgrep -f M2MSender)
ssh kivi@10.10.10.2 'pgrep -f M2MReceiver && kill $(pgrep -f M2MReceiver)'
ssh kivi@10.10.10.2 'cd ~/m2mdisplay && nohup ./M2MReceiverCLI > receiver.log 2>&1 & disown'
nohup .build/release/M2MSenderCLI > /tmp/sender_planA.log 2>&1 &
```

**Never run `M2MReceiverCLI` locally on the MacBook Pro** — it creates a full-screen overlay window, exactly like the old `M2MReceiver` did. Only ever run it via the `ssh kivi@10.10.10.2` commands above.

- [ ] **Step 3: Confirm video is actually flowing (not just the sender process being alive)**

```bash
ssh kivi@10.10.10.2 'wc -l ~/m2mdisplay/receiver.log'
sleep 3
ssh kivi@10.10.10.2 'wc -l ~/m2mdisplay/receiver.log'
```

Expected: the line count increases between the two calls — confirms frames are actively arriving, not just that the process launched (this exact check caught the ScreenCaptureKit stream-death bug on 2026-08-14 — don't skip it).

- [ ] **Step 4: Confirm the automatic capture recovery works**

Watch `/tmp/sender_planA.log` for a `[SenderEngine] state: reconnecting` line if a capture failure happens to occur during testing; if none occurs naturally, this is validated for real once Plan A's UI is in place and used daily — no artificial fault injection needed for this plan (ScreenCaptureKit doesn't expose a way to deliberately kill a stream from outside the process).

- [ ] **Step 5: Confirm `EventLog` files exist**

```bash
tail -5 ~/Library/Logs/M2MDisplay/sender.log
ssh kivi@10.10.10.2 'tail -5 ~/Library/Logs/M2MDisplay/receiver.log'
```

Expected: both show recent `[INFO]` lines (`virtual display ready`, `running`, `listening`, `cast shown`, etc.) — confirms `EventLog` (Task 1) is actually wired up end-to-end, not just unit-tested in isolation.

---

### Task 8: `M2MApp` — SwiftUI menu bar shell with role picker and start/stop

**Files:**
- Create: `Sources/M2MApp/M2MDisplayApp.swift`
- Create: `Sources/M2MApp/RoleStore.swift`
- Create: `Sources/M2MApp/AppState.swift`
- Create: `Sources/M2MApp/MenuBarView.swift`
- Modify: `Package.swift`

**Interfaces:**
- Consumes: `SenderEngine`/`SenderState` (Task 3), `ReceiverEngine`/`ReceiverState` (Task 5), `Endpoints` (`Sources/M2MShared`).

- [ ] **Step 1: Role persistence**

```swift
// Sources/M2MApp/RoleStore.swift
import Foundation

enum AppRole: String, CaseIterable, Identifiable {
    case sender
    case receiver

    var id: String { rawValue }
    var displayName: String { self == .sender ? "发送端" : "接收端" }
}

/// Remembers which role this machine plays across launches — each machine
/// has its own local UserDefaults, so MacBook Pro and iMac naturally each
/// keep their own saved choice.
final class RoleStore {
    private let roleKey = "com.m2mdisplay.role"

    var savedRole: AppRole? {
        get { UserDefaults.standard.string(forKey: roleKey).flatMap(AppRole.init(rawValue:)) }
        set { UserDefaults.standard.set(newValue?.rawValue, forKey: roleKey) }
    }
}
```

- [ ] **Step 2: App state driving the engines**

```swift
// Sources/M2MApp/AppState.swift
import Foundation
import M2MSenderCore
import M2MReceiverCore
import M2MShared

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var role: AppRole?
    @Published private(set) var statusText: String = "未启动"
    @Published private(set) var lastEvents: [String] = []
    @Published private(set) var isBusy = false
    @Published private(set) var isRunning = false

    private let roleStore = RoleStore()
    private var senderEngine: SenderEngine?
    private var receiverEngine: ReceiverEngine?
    private let maxEvents = 5

    init() {
        role = roleStore.savedRole
        if let role { activateEngine(for: role) }
    }

    func selectRole(_ role: AppRole) {
        self.role = role
        roleStore.savedRole = role
        activateEngine(for: role)
    }

    /// Lets the user pick a different role without quitting the app.
    func resetRole() {
        role = nil
        roleStore.savedRole = nil
        senderEngine = nil
        receiverEngine = nil
        statusText = "未启动"
        isRunning = false
    }

    private func activateEngine(for role: AppRole) {
        switch role {
        case .sender:
            let engine = SenderEngine()
            engine.onStateChange = { [weak self] state in
                Task { @MainActor in self?.applySenderState(state) }
            }
            senderEngine = engine
            _ = engine.prepareVirtualDisplay(width: 1920, height: 1080, backingScale: 2)
        case .receiver:
            let engine = ReceiverEngine()
            engine.onStateChange = { [weak self] state in
                Task { @MainActor in self?.applyReceiverState(state) }
            }
            receiverEngine = engine
            engine.prepareWindow()
        }
    }

    private func applySenderState(_ state: SenderState) {
        statusText = "\(state)"
        isRunning = state == .running || state == .reconnecting
        pushEvent("发送端: \(state)")
    }

    private func applyReceiverState(_ state: ReceiverState) {
        statusText = "\(state)"
        isRunning = state == .casting
        pushEvent("接收端: \(state)")
    }

    private func pushEvent(_ text: String) {
        lastEvents.insert(text, at: 0)
        if lastEvents.count > maxEvents { lastEvents.removeLast() }
    }

    func startCasting() {
        guard let role, !isBusy else { return }
        isBusy = true
        Task {
            switch role {
            case .sender:
                await senderEngine?.start(receiverHost: Endpoints.receiverHost)
            case .receiver:
                receiverEngine?.showCast()
            }
            isBusy = false
        }
    }

    func stopCasting() {
        guard let role, !isBusy else { return }
        isBusy = true
        Task {
            switch role {
            case .sender:
                await senderEngine?.stop()
            case .receiver:
                receiverEngine?.hideCast()
            }
            isBusy = false
        }
    }

    var logDirectoryURL: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/M2MDisplay", isDirectory: true)
    }
}
```

- [ ] **Step 3: Menu bar panel view**

```swift
// Sources/M2MApp/MenuBarView.swift
import SwiftUI

struct MenuBarView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let role = appState.role {
                Text("角色：\(role.displayName)").font(.headline)
                Text("状态：\(appState.statusText)")
                    .foregroundStyle(.secondary)

                HStack {
                    Button(appState.isRunning ? "停止投屏" : "开始投屏") {
                        appState.isRunning ? appState.stopCasting() : appState.startCasting()
                    }
                    .disabled(appState.isBusy)
                    Button("切换角色", action: appState.resetRole)
                }

                if !appState.lastEvents.isEmpty {
                    Divider()
                    Text("最近事件").font(.caption).foregroundStyle(.secondary)
                    ForEach(appState.lastEvents, id: \.self) { event in
                        Text(event).font(.caption).lineLimit(1)
                    }
                }

                Divider()
                Button("打开日志文件") {
                    NSWorkspace.shared.open(appState.logDirectoryURL)
                }
            } else {
                Text("选择这台机器的角色").font(.headline)
                HStack {
                    ForEach(AppRole.allCases) { role in
                        Button(role.displayName) { appState.selectRole(role) }
                    }
                }
            }
        }
        .padding()
        .frame(width: 260)
    }
}
```

- [ ] **Step 4: App entry point**

```swift
// Sources/M2MApp/M2MDisplayApp.swift
import SwiftUI

@main
struct M2MDisplayApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        MenuBarExtra("M2M Display", systemImage: "rectangle.on.rectangle") {
            MenuBarView(appState: appState)
        }
        .menuBarExtraStyle(.window)
    }
}
```

- [ ] **Step 5: Add the target to Package.swift**

```swift
.executableTarget(
    name: "M2MApp",
    dependencies: ["M2MSenderCore", "M2MReceiverCore", "M2MShared"],
    path: "Sources/M2MApp"
),
```

- [ ] **Step 6: Build**

Run: `swift build -c release 2>&1 | tail -20`
Expected: `Build complete!` with `M2MApp` included in the target list.

- [ ] **Step 7: Commit**

```bash
git add Sources/M2MApp Package.swift
git commit -m "Add M2MApp SwiftUI menu bar shell with role picker and start/stop"
```

---

### Task 9: End-to-end verification of `M2MApp` on both machines

**Files:** none (verification only)

- [ ] **Step 1: Run `M2MApp` locally on the MacBook Pro in sender role**

This is safe to run locally — unlike the receiver role, the sender role never creates a full-screen overlay window on the machine it runs on.

```bash
open .build/release/M2MApp
```

Click the menu bar icon, select "发送端", click "开始投屏". Confirm the status text moves through `starting` → `running`.

- [ ] **Step 2: Deploy and run `M2MApp` on the iMac in receiver role**

```bash
scp .build/release/M2MApp kivi@10.10.10.2:~/m2mdisplay/M2MApp
ssh kivi@10.10.10.2 'ls -la ~/m2mdisplay/M2MApp'
```

Then, **on the iMac itself** (not over SSH — this is a GUI app and needs a real login session; ask the user to double-click it or run `open` in a Terminal session on the iMac), launch it, select "接收端". Do not attempt to drive this step yourself over SSH the way the old CLI was started — a `MenuBarExtra` app needs an active GUI session, and per the project's standing rule, the receiver role is never to be validated by running it locally on the MacBook Pro either.

- [ ] **Step 3: Verify start/stop from both sides**

- Click "开始投屏" on the MacBook's `M2MApp` menu — confirm the iMac's screen shows the cast within a couple seconds.
- Click "停止投屏" on the MacBook's `M2MApp` menu — confirm the iMac's screen returns to its own normal desktop (Dock and menu bar visible, native cursor working).
- Repeat starting/stopping 2-3 times in a row to confirm the virtual-display-created-once design (Task 3) means each cycle is fast and doesn't re-trigger the mirroring/mode-activation flakiness found on 2026-08-14.

- [ ] **Step 4: Verify logs and event list**

Confirm the "最近事件" list in the menu bar panel updates live, and that `~/Library/Logs/M2MDisplay/sender.log` / `receiver.log` on the respective machines contain the same events.

---

## Self-Review Notes

- **Spec coverage:** this plan covers the spec's "产品形态" (one app, role picker), "菜单栏面板内容" (start/stop, status, recent events, log button — permission/connection/resolution rows deferred to Plan B per the "Out of scope" section above), "状态机" (`SenderState`/`ReceiverState` + automatic recovery), "虚拟显示器生命周期" (create-once in `prepareVirtualDisplay`), "投屏开关与 iMac 画面切换" (`showCast`/`hideCast`), and "日志" (`EventLog`). "双向控制" (iMac-initiated start/stop, global hotkey), "权限引导" (guided sheets), and "连接方式/分辨率" editable UI are Plan B, as scoped above.
- **Type consistency:** `SenderState`/`ReceiverState` names and cases are used identically across `SenderEngine`/`ReceiverEngine` (Tasks 3, 5), `AppState` (Task 8), and the CLI print statements (Task 6) — checked against each task's own Interfaces block above.

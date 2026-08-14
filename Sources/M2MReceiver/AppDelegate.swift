import AppKit
import CoreGraphics
import CoreMedia
import M2MShared

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var displayView: DisplayView!
    private let videoReceiver = VideoReceiver()
    private let cursorReceiver = CursorReceiver()
    private var formatDescription: CMFormatDescription?
    // Two different things, easy to conflate into one variable (did that once —
    // decoder showed only the top-left quarter, zoomed to fill the screen,
    // because it was told the frame was 1920x1080 pixels when the actual H.264
    // bitstream is 3840x2160):
    //  - cursor position math needs *points* (CGDisplayBounds' unit — stayed
    //    1920x1080 even after the virtual display's pixel mode became 3840x2160;
    //    the system auto-picked a 2x/Retina point scaling for that pixel count,
    //    matching the iMac's own real display, which is what fixed the blur)
    //  - the video format description needs the actual encoded *pixel* size
    private var cursorSpaceWidth = 1920
    private var cursorSpaceHeight = 1080
    private var videoPixelWidth = 1920
    private var videoPixelHeight = 1080
    private let escapeHatch = EscapeHatch()
    private let powerAssertion = PowerAssertion()
    private var cursorHideTimer: DispatchSourceTimer?
    private let ackSender = AckSender(host: Endpoints.senderHost, port: NetworkConfig.ackPort)

    /// NSScreen.main is whatever the system currently considers its main display,
    /// which can be a *virtual* screen (Sidecar/AirPlay/another instance of this
    /// very app) rather than the physical panel in front of the person sitting at
    /// this Mac. This receiver's only job is to draw on real physical glass, so it
    /// explicitly targets the built-in/physically-attached display and never trusts
    /// "main" — bit us in local same-machine testing where the existing AirPlay
    /// session to the iMac had claimed the Main Display slot.
    private func physicalScreen() -> NSScreen {
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
            let displayID = CGDirectDisplayID(number.uint32Value)
            if CGDisplayIsBuiltin(displayID) != 0 {
                return screen
            }
        }
        return NSScreen.main ?? NSScreen.screens[0]
    }

    private func physicalDisplayID() -> CGDirectDisplayID {
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
            let displayID = CGDirectDisplayID(number.uint32Value)
            if CGDisplayIsBuiltin(displayID) != 0 {
                return displayID
            }
        }
        return CGMainDisplayID()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let screenFrame = physicalScreen().frame
        window = NSWindow(contentRect: screenFrame, styleMask: [.borderless], backing: .buffered, defer: false)
        // Deliberately NOT sitting above the real menu bar anymore. A level
        // above .mainMenu covers it outright (cosmetically nicer — no double
        // menu bar) but also made the window immune to Mission Control / Cmd+Tab,
        // which turned into a real incident: it covered someone's live screen
        // with no visible way back short of a hard reboot. .floating leaves the
        // double-menu-bar cosmetic issue in place, but every normal macOS escape
        // route (Mission Control, Cmd+Tab, Cmd+`) still works. That trade is not
        // close — never revisit this without a solid non-visual kill switch
        // (a keyboard shortcut alone was not enough when the user had no way to
        // even read what the shortcut was).
        window.level = .floating
        window.backgroundColor = .black
        window.isOpaque = true
        window.ignoresMouseEvents = true // this Mac has no input devices attached in this setup — see project notes
        window.collectionBehavior = [.stationary, .ignoresCycle]
        displayView = DisplayView(frame: window.contentView?.bounds ?? screenFrame)
        displayView.autoresizingMask = [.width, .height]
        window.contentView = displayView
        window.setFrame(screenFrame, display: true)
        window.makeKeyAndOrderFront(nil)
        NSApp.setActivationPolicy(.accessory)

        // This Mac's own real cursor has nothing driving it (no local input
        // device is attached in this setup), so it just sits wherever it was
        // last, on top of our rendered overlay — two arrows at once. Global,
        // works regardless of which app has focus; explicitly paired with
        // CGDisplayShowCursor on quit so a real local user isn't left with an
        // invisible pointer if they ever do sit down at this Mac.
        //
        // A single hide-on-launch call reportedly doesn't stick — macOS re-shows
        // the real cursor on its own after some system event (display
        // reconfiguration, a window server hiccup, etc.), a known quirk with
        // CGDisplayHideCursor in other full-screen/kiosk apps. Re-asserting on a
        // timer is the standard workaround — but Hide/Show are refcounted per
        // Apple's docs, so blindly calling Hide on every tick would leave it
        // needing dozens of matching Show calls to undo, and a single Show on
        // quit would leave the real cursor stuck invisible forever. Each tick
        // pairs Show+Hide (net refcount change: zero) purely to force a fresh
        // redraw, so the hide depth never drifts from the original single Hide().
        let hideResult = CGDisplayHideCursor(physicalDisplayID())
        print("[M2MReceiver] hid this Mac's own cursor (result: \(hideResult.rawValue))")
        let cursorHideTimer = DispatchSource.makeTimerSource(queue: .main)
        cursorHideTimer.schedule(deadline: .now() + 2, repeating: 2)
        cursorHideTimer.setEventHandler { [weak self] in
            guard let self else { return }
            let id = self.physicalDisplayID()
            CGDisplayShowCursor(id)
            CGDisplayHideCursor(id)
        }
        cursorHideTimer.resume()
        self.cursorHideTimer = cursorHideTimer

        if escapeHatch.start() {
            print("[M2MReceiver] escape hatch armed — triple-tap Escape to quit")
        } else {
            fputs("[M2MReceiver] WARNING: escape hatch failed to start (needs Accessibility permission) — this window will cover the whole screen with no keyboard way out until that's granted\n", stderr)
        }

        if powerAssertion.start() {
            print("[M2MReceiver] power assertion active — this Mac won't sleep/lock while running")
        } else {
            fputs("[M2MReceiver] WARNING: failed to create power assertion — this Mac may lock/sleep on its normal idle timer\n", stderr)
        }

        videoReceiver.onConnected = {
            print("[M2MReceiver] sender connected")
        }
        videoReceiver.onFrame = { [weak self] frame in
            self?.handle(frame)
        }
        var cursorLogCount = 0
        cursorReceiver.onCursor = { [weak self] packet in
            guard let self else { return }
            cursorLogCount += 1
            if cursorLogCount <= 5 {
                print("[M2MReceiver] cursor #\(cursorLogCount): (\(packet.x), \(packet.y)) seq=\(packet.sequence)")
            }
            DispatchQueue.main.async {
                if packet.isVisible {
                    self.displayView.updateCursor(normalizedX: CGFloat(packet.x) / CGFloat(self.cursorSpaceWidth),
                                                   normalizedY: CGFloat(packet.y) / CGFloat(self.cursorSpaceHeight))
                } else {
                    self.displayView.hideCursor()
                }
                // Ack fires the instant the position is actually on screen, not
                // just received — this is the honest "mouse moved -> pixel
                // changed" latency measurement point.
                self.ackSender.send(AckPacket(sequence: packet.sequence))
            }
        }

        do {
            try videoReceiver.start(port: NetworkConfig.videoPort)
            try cursorReceiver.start(port: NetworkConfig.cursorPort)
            print("[M2MReceiver] listening — video:\(NetworkConfig.videoPort) cursor:\(NetworkConfig.cursorPort)")
        } catch {
            fputs("[M2MReceiver] failed to start listeners: \(error)\n", stderr)
        }
    }

    private var handledCount = 0

    private func handle(_ frame: ReceivedFrame) {
        if let avcC = frame.avcC {
            formatDescription = SampleBufferBuilder.formatDescription(width: videoPixelWidth, height: videoPixelHeight, avcC: avcC)
            print("[M2MReceiver] rebuilt formatDescription from avcC(\(avcC.count) bytes): \(formatDescription != nil ? "ok" : "FAILED")")
        }
        guard let formatDescription else {
            print("[M2MReceiver] dropping frame — no formatDescription yet")
            return
        }
        guard let sampleBuffer = SampleBufferBuilder.sampleBuffer(payload: frame.payload, formatDescription: formatDescription) else {
            print("[M2MReceiver] sampleBuffer() returned nil for a \(frame.payload.count)-byte payload")
            return
        }
        handledCount += 1
        if handledCount <= 3 {
            print("[M2MReceiver] enqueuing frame #\(handledCount), \(frame.payload.count) bytes, keyframe=\(frame.header.isKeyframe)")
        }
        DispatchQueue.main.async { [weak self] in
            self?.displayView.enqueue(sampleBuffer)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        CGDisplayShowCursor(physicalDisplayID()) // don't leave a real local user with an invisible pointer
        powerAssertion.stop()
    }
}

import CGVirtualDisplayShim
import Foundation
import ScreenCaptureKit
import M2MShared
import AppKit
import CoreImage

setvbuf(stdout, nil, _IOLBF, 0)

signal(SIGINT) { _ in
    print("\nCaught SIGINT, exiting")
    exit(0)
}

// Process-lifetime holders. Everything that needs to keep running (the capture
// stream, the network connections, the event tap) has to be reachable from
// something that outlives the `Task` closure below — local `let`s inside that
// closure get deallocated the moment the closure body finishes executing its
// synchronous setup code, which silently tore down the SCStream before it ever
// delivered a frame (confirmed via Console: "stopping a deallocated stream that
// is still running"). Global `var`s have process lifetime, so assigning into
// these is what actually keeps things alive.
var keepAliveVirtualDisplay: VirtualDisplay?
var keepAliveCapturer: FrameCapturer?
var keepAliveEncoder: VideoEncoder?
var keepAliveVideoSender: VideoSender?
var keepAliveCursorSender: CursorSender?
var keepAliveMouseTap: MouseTap?
var keepAliveAckReceiver: AckReceiver?

// Everything async lives inside this Task. Top-level `await` in main.swift taints
// the *whole file* as an implicit async entry point, and calling a blocking
// "run forever" primitive from anywhere inside that context crashes libdispatch's
// own sanity check ("dispatch_main called from a block on the main queue") —
// bit us in the real cross-machine test after the process ran fine for a while,
// then died. Keeping setup in a plain Task and the run-forever call as the one
// truly-synchronous top-level statement is what makes it legal.
Task {
    do {
        let receiverHost = Endpoints.receiverHost
        print("Target receiver: \(receiverHost) (video:\(NetworkConfig.videoPort) cursor:\(NetworkConfig.cursorPort))")

        // Tried the panel's true native 4480x2520 to chase the last bit of
        // sharpness, but at sustained 60fps that's 36% more pixels than 4K and
        // it started dropping frames/stuttering — a real regression against the
        // actual bar ("better than AirPlay," which means smooth first). 4K
        // (3840x2160) already fixed the original blur (matches the iMac's
        // active "looks like 1920x1080" scaled resolution at a clean 2x) and
        // ran smoothly; settling here rather than trading stability for the
        // last increment of crispness.
        guard let virtualDisplay = VirtualDisplay(
            name: "M2M Display",
            width: 3840,
            height: 2160,
            refreshRate: 60,
            widthMM: 508,
            heightMM: 285
        ) else {
            fputs("Failed to create virtual display\n", stderr)
            exit(1)
        }
        keepAliveVirtualDisplay = virtualDisplay
        print("Created virtual display, CGDirectDisplayID = \(virtualDisplay.displayID), requested \(virtualDisplay.width)x\(virtualDisplay.height)")

        let capturer = FrameCapturer(displayID: virtualDisplay.displayID, width: virtualDisplay.width, height: virtualDisplay.height)
        keepAliveCapturer = capturer
        // 10Mbps looked visibly blurry for 1080p60 desktop content (dense text,
        // sharp UI edges compress far worse than natural video) — bumped way up
        // since the Thunderbolt Bridge link has tens of Gbps to spare and was
        // never remotely close to the bottleneck.
        let encoder = try VideoEncoder(width: virtualDisplay.width, height: virtualDisplay.height, frameRate: 60, averageBitrateBps: 60_000_000)
        keepAliveEncoder = encoder
        let videoSender = VideoSender(host: receiverHost, port: NetworkConfig.videoPort)
        keepAliveVideoSender = videoSender
        let cursorSender = CursorSender(host: receiverHost, port: NetworkConfig.cursorPort)
        keepAliveCursorSender = cursorSender

        var rawFrames = 0
        var encodedFrames = 0
        encoder.onEncodedFrame = { frame in
            encodedFrames += 1
            if encodedFrames <= 3 { print("encoded frame #\(encodedFrames), \(frame.payload.count) bytes") }
            videoSender.send(frame)
        }
        capturer.onFrame = { sampleBuffer in
            rawFrames += 1
            if rawFrames == 60, let pb = sampleBuffer.imageBuffer {
                // One-shot ground-truth dump: exactly what the encoder receives,
                // before any H.264 compression — the reference point for
                // figuring out whether quality loss happens in encode, decode,
                // or the receiver's final render/composite step.
                let ciImage = CIImage(cvPixelBuffer: pb)
                let ctx = CIContext()
                if let cgImage = ctx.createCGImage(ciImage, from: ciImage.extent) {
                    let rep = NSBitmapImageRep(cgImage: cgImage)
                    if let data = rep.representation(using: .png, properties: [:]) {
                        try? data.write(to: URL(fileURLWithPath: "/tmp/m2m_raw_capture.png"))
                        print("dumped raw pre-encode frame to /tmp/m2m_raw_capture.png")
                    }
                }
            }
            if rawFrames <= 3, let pb = sampleBuffer.imageBuffer {
                print("captured raw frame #\(rawFrames): \(CVPixelBufferGetWidth(pb))x\(CVPixelBufferGetHeight(pb)) pixels")
            }
            encoder.encode(sampleBuffer)
        }
        capturer.onStreamStopped = { error in
            print("Stream stopped: \(String(describing: error))")
        }

        // Mouse tracking doesn't depend on the video channel — start it
        // independently instead of blocking behind the video handshake.
        var cursorSeq: UInt32 = 0
        var sentAt: [UInt32: CFAbsoluteTime] = [:]
        var latenciesMs: [Double] = []
        let mouseTap = MouseTap(virtualDisplayID: virtualDisplay.displayID, width: virtualDisplay.width, height: virtualDisplay.height)
        keepAliveMouseTap = mouseTap
        mouseTap.onPosition = { x, y, isVisible in
            cursorSeq += 1
            sentAt[cursorSeq] = CFAbsoluteTimeGetCurrent()
            cursorSender.send(CursorPacket(x: x, y: y, cursorType: CursorType.arrow.rawValue, sequence: cursorSeq, isVisible: isVisible))
        }

        // Round-trip "mouse moved -> rendered on the iMac -> ack back" timing.
        // Single-clock measurement (no cross-machine sync needed) — this is the
        // actual end-to-end number that matters, not a network ping.
        let ackReceiver = AckReceiver()
        keepAliveAckReceiver = ackReceiver
        ackReceiver.onAck = { sequence in
            guard let t0 = sentAt.removeValue(forKey: sequence) else { return }
            let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            latenciesMs.append(ms)
            if latenciesMs.count <= 30 || latenciesMs.count % 25 == 0 {
                let sorted = latenciesMs.sorted()
                let avg = latenciesMs.reduce(0, +) / Double(latenciesMs.count)
                let p50 = sorted[sorted.count / 2]
                let p95 = sorted[Int(Double(sorted.count - 1) * 0.95)]
                print(String(format: "[Latency] n=%d  last=%.2fms  avg=%.2fms  p50=%.2fms  p95=%.2fms  min=%.2fms  max=%.2fms",
                              latenciesMs.count, ms, avg, p50, p95, sorted.first ?? 0, sorted.last ?? 0))
            }
            // Cap growth so a long-running session doesn't leak memory —
            // sentAt entries only accumulate if an ack is lost, which the
            // cursor channel's own semantics (latest-wins) make rare and
            // harmless to just drop.
            if sentAt.count > 200 { sentAt.removeAll() }
        }
        try? ackReceiver.start(port: NetworkConfig.ackPort)
        if mouseTap.start() {
            print("Mouse tap active — tracking cursor over the virtual display")
        } else {
            fputs("""
            Failed to start the global mouse tap — this process needs Accessibility permission.
            Grant it under System Settings > Privacy & Security > Accessibility (or Input Monitoring),
            then restart M2MSender. Continuing without cursor tracking for now.

            """, stderr)
        }

        print("Connecting video channel to \(receiverHost):\(NetworkConfig.videoPort)...")
        try await videoSender.waitUntilReady()
        print("Video channel connected")

        // Give WindowServer a moment to register the new display before SCShareableContent enumerates it.
        for attempt in 1...10 {
            do {
                try await capturer.start()
                print("Capture started")
                break
            } catch {
                print("Capture start attempt \(attempt) failed: \(error). Retrying...")
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }

        print("Running. Move the mouse onto the virtual display; Ctrl+C to quit.")
    } catch {
        fputs("Fatal error during startup: \(error)\n", stderr)
        exit(1)
    }
}

// dispatchMain() only pumps the main GCD queue — CGEventTap's run loop source
// (CFRunLoopAddSource(CFRunLoopGetMain(), ...) in MouseTap) never actually got
// serviced under it: the tap created fine and IOHIDCheckAccess reported Input
// Monitoring as GRANTED, yet zero mouse events ever arrived, on every run since
// dispatchMain() replaced RunLoop.main.run() to fix the earlier libdispatch
// crash. CFRunLoopRun() drives CFRunLoopGetMain() directly, and the main GCD
// queue is itself served through the CFRunLoop when running on the main thread,
// so this keeps both working without reintroducing the original crash (that
// was about calling *from an implicit async context*, not about which specific
// blocking call was used).
CFRunLoopRun()

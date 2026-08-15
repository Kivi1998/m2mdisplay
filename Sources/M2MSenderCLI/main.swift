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

Task {
    guard await engine.prepareVirtualDisplay(width: 1920, height: 1080, backingScale: 2) else {
        fputs("Failed to create virtual display\n", stderr)
        exit(1)
    }
    await engine.start(receiverHost: Endpoints.receiverHost)
}

// dispatchMain() 只驱动主 GCD 队列——MouseTap 里 CGEventTap 的运行循环源
// 需要直接用 CFRunLoopRun()（这段坑的完整来龙去脉见 MouseTap.swift）。
CFRunLoopRun()

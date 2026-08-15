// Sources/M2MReceiverCLI/AppDelegate.swift
import AppKit
import M2MReceiverCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let engine = ReceiverEngine()

    func applicationDidFinishLaunching(_ notification: Notification) {
        engine.onStateChange = { state in print("[ReceiverEngine] state: \(state)") }
        engine.prepareWindow()
    }

    // 覆盖窗口隐藏后仍需保持网络监听，等待发送端下一次连接。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationDidBecomeActive(_ notification: Notification) { engine.handleDidBecomeActive() }
    func applicationWillResignActive(_ notification: Notification) { engine.handleWillResignActive() }
    func applicationWillTerminate(_ notification: Notification) { engine.shutdown() }
}

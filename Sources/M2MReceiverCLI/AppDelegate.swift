// Sources/M2MReceiverCLI/AppDelegate.swift
import AppKit
import M2MReceiverCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let engine = ReceiverEngine()

    func applicationDidFinishLaunching(_ notification: Notification) {
        engine.onStateChange = { state in print("[ReceiverEngine] state: \(state)") }
        engine.prepareWindow()
        engine.showCast() // 命令行版本保留"启动就立刻投屏"的旧行为
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationDidBecomeActive(_ notification: Notification) { engine.handleDidBecomeActive() }
    func applicationWillResignActive(_ notification: Notification) { engine.handleWillResignActive() }
    func applicationWillTerminate(_ notification: Notification) { engine.shutdown() }
}

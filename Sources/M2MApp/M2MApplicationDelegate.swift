import AppKit

@MainActor
final class M2MApplicationDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    let appState = AppState()
    private var terminationReplyPending = false

    /// AppKit 必须等异步抓屏流水线停止后再结束进程，否则虚拟显示器可能成为孤儿。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if appState.isPreparedForTermination { return .terminateNow }
        guard !terminationReplyPending else { return .terminateLater }
        terminationReplyPending = true
        Task {
            await appState.prepareForTermination()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// App 已在后台运行时再次从 Applications 打开，也重新确认 iMac 接收端已启动。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        appState.ensureReceiverIsRunning()
        return true
    }
}

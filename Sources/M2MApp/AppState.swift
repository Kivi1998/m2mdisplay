import AppKit
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
    @Published private(set) var isQuitting = false

    private let roleStore = RoleStore()
    private let log = EventLog(role: "app")
    private let lifecycleScripts = PeerLifecycleScripts()
    private let controlServer = PeerControlServer()
    private var senderEngine: SenderEngine?
    private var receiverEngine: ReceiverEngine?
    private let maxEvents = 5
    private var didPrepareForTermination = false
    private lazy var idleCastingGuard = IdleCastingGuard { [weak self] in
        self?.handleIdleTimeout()
    }

    init() {
        if let requestedRole = roleStore.roleFromLaunchArguments {
            roleStore.savedRole = requestedRole
            role = requestedRole
        } else {
            role = roleStore.savedRole
        }

        do {
            try controlServer.start { [weak self] in self?.handlePeerQuitRequest() }
        } catch {
            pushEvent("双机退出控制启动失败：\(error)")
        }

        if let role { activateEngine(for: role) }
    }

    func selectRole(_ role: AppRole) {
        self.role = role
        roleStore.savedRole = role
        activateEngine(for: role)
    }

    /// 让用户不用退出 App 就能重新选择角色。
    func resetRole() {
        let outgoingSender = senderEngine
        let outgoingReceiver = receiverEngine
        outgoingSender?.onStateChange = nil
        outgoingReceiver?.onStateChange = nil
        role = nil
        roleStore.savedRole = nil
        senderEngine = nil
        receiverEngine = nil
        statusText = "未启动"
        isRunning = false
        idleCastingGuard.stop()
        DispatchQueue.main.async { NSApp.setActivationPolicy(.accessory) }
        Task {
            await outgoingSender?.stop()
            outgoingReceiver?.hideCast()
        }
    }

    private func activateEngine(for role: AppRole) {
        switch role {
        case .sender:
            // 发送端（MacBook）常驻 Dock，可以固定在 Dock 里，点击图标即可重新
            // 确认/启动两端连接（见 applicationShouldHandleReopen）。接收端
            // （iMac）继续保持 Info.plist 里 LSUIElement 的默认无 Dock 图标状态，
            // 不受这里影响。
            // activateEngine(for:) 在 App 冷启动时会从 AppState.init() 同步调用，
            // 这时 SwiftUI 的启动流程可能还没来得及给 NSApp 这个全局量赋值，直接
            // 调用 NSApp.setActivationPolicy(...) 会隐式解包到 nil 崩溃（已实测
            // 踩过）；派发到下一个 run loop 循环，此时 NSApp 一定已经就绪。
            DispatchQueue.main.async { NSApp.setActivationPolicy(.regular) }
            let engine = SenderEngine()
            engine.onStateChange = { [weak self] state in
                Task { @MainActor in self?.applySenderState(state) }
            }
            senderEngine = engine
            statusText = "待投屏"
            Task {
                let startResult = await lifecycleScripts.startReceiver()
                reportLifecycleResult(startResult, successMessage: "iMac 接收端已启动")
            }
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
        if isRunning {
            idleCastingGuard.start()
        } else {
            idleCastingGuard.stop()
        }
        pushEvent("发送端: \(state)")
    }

    /// 投屏期间检测到长时间无操作（见 IdleCastingGuard），自动停止投屏，
    /// 让两台 Mac 都能恢复各自平时设置的息屏/屏保节奏，不至于亮一整晚。
    private func handleIdleTimeout() {
        guard role == .sender, isRunning, !isBusy else { return }
        log.write(.info, "投屏期间检测到长时间无操作，自动停止投屏")
        pushEvent("长时间无操作，已自动停止投屏")
        stopCasting()
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
                guard let senderEngine else { break }
                let prepared = await senderEngine.prepareVirtualDisplay(width: 1920, height: 1080, backingScale: 2)
                if prepared {
                    await senderEngine.start(receiverHost: Endpoints.receiverHost)
                }
            case .receiver:
                pushEvent("接收端将在收到真实首帧后自动显示")
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

    /// 当发送端从 Applications 启动或已运行的 App 被再次打开时，确保 iMac 的
    /// 正式接收端 App 已经存在并运行。接收端本身不反向启动发送端，因为 MacBook
    /// 没有开启远程登录；日常入口固定为 MacBook Pro 的 Applications。
    func ensureReceiverIsRunning() {
        guard role == .sender, !isQuitting else { return }
        Task {
            let result = await lifecycleScripts.startReceiver()
            reportLifecycleResult(result, successMessage: "已确认 iMac 接收端运行")
        }
    }

    /// 菜单栏的“退出 M2M Display”会先请求另一端正常退出，再终止本机。即使
    /// 对端已经离线，本机也必须继续退出，不能让一次网络故障把 App 锁在后台。
    func quitAll() {
        guard !isQuitting else { return }
        isQuitting = true
        pushEvent("正在退出两台 Mac 上的 M2M Display")
        log.write(.info, "用户请求退出两台 Mac 上的 M2M Display")

        Task {
            if let role {
                let peerHost = role == .sender ? Endpoints.receiverHost : Endpoints.senderHost
                let result = await lifecycleScripts.stopPeer(host: peerHost)
                reportLifecycleResult(result, successMessage: "另一端已收到退出请求")
            }
            await prepareForTermination()
            NSApp.terminate(nil)
        }
    }

    /// AppKit 退出委托会等待这里完成后才真正结束进程，确保抓屏、网络、沉浸窗口
    /// 与原生光标都恢复到未启动 M2M Display 时的状态。
    func prepareForTermination() async {
        guard !didPrepareForTermination else { return }
        didPrepareForTermination = true
        log.write(.info, "正在执行 App 正常退出收尾")
        controlServer.stop()

        switch role {
        case .sender:
            await senderEngine?.stop()
        case .receiver:
            receiverEngine?.shutdown()
        case nil:
            break
        }
        log.write(.info, "App 正常退出收尾完成")
    }

    var isPreparedForTermination: Bool { didPrepareForTermination }

    private func handlePeerQuitRequest() {
        guard !isQuitting else { return }
        isQuitting = true
        pushEvent("收到另一台 Mac 的退出请求")
        log.write(.info, "收到另一台 Mac 的退出请求")
        Task {
            await prepareForTermination()
            NSApp.terminate(nil)
        }
    }

    private func reportLifecycleResult(_ result: LifecycleScriptResult, successMessage: String) {
        if result.succeeded {
            pushEvent(successMessage)
        } else {
            let detail = result.detail.isEmpty ? "未知错误" : result.detail
            pushEvent("双机操作失败：\(detail)")
        }
    }

    var logDirectoryURL: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/M2MDisplay", isDirectory: true)
    }
}

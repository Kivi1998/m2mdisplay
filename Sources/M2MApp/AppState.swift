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
        Task {
            await outgoingSender?.stop()
            outgoingReceiver?.hideCast()
        }
    }

    private func activateEngine(for role: AppRole) {
        switch role {
        case .sender:
            let engine = SenderEngine()
            engine.onStateChange = { [weak self] state in
                Task { @MainActor in self?.applySenderState(state) }
            }
            senderEngine = engine
            isBusy = true
            Task {
                _ = await engine.prepareVirtualDisplay(width: 1920, height: 1080, backingScale: 2)
                isBusy = false
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

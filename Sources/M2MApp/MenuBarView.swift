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
                        .disabled(appState.isBusy)
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

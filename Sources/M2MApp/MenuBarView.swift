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
                        .disabled(appState.isBusy || appState.isMainDisplayBusy)
                }

                if role == .sender {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("声音输出").font(.caption).foregroundStyle(.secondary)
                        Picker("声音输出", selection: Binding(
                            get: { appState.audioOutputPreference },
                            set: { appState.setAudioOutputPreference($0) }
                        )) {
                            ForEach(AudioOutputPreference.allCases) { preference in
                                Text(preference.displayName).tag(preference)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .disabled(appState.isBusy || appState.isMainDisplayBusy)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("主显示器").font(.caption).foregroundStyle(.secondary)
                        Picker("主显示器", selection: Binding(
                            get: { appState.mainDisplayPreference },
                            set: { appState.setMainDisplayPreference($0) }
                        )) {
                            ForEach(MainDisplayPreference.allCases) { preference in
                                Text(appState.displayName(for: preference)).tag(preference)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .disabled(appState.isBusy || appState.isMainDisplayBusy)
                        Text("另一台自动作为扩展显示器")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("无操作后停止投屏").font(.caption).foregroundStyle(.secondary)
                        Picker("无操作后停止投屏", selection: Binding(
                            get: { appState.idleStopPreference },
                            set: { appState.setIdleStopPreference($0) }
                        )) {
                            ForEach(IdleStopPreference.allCases) { preference in
                                Text(preference.displayName).tag(preference)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .disabled(appState.isBusy)
                    }
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
                Button("退出 M2M Display") {
                    appState.quitAll()
                }
                .keyboardShortcut("q")
                .disabled(appState.isQuitting)
            } else {
                Text("选择这台机器的角色").font(.headline)
                HStack {
                    ForEach(AppRole.allCases) { role in
                        Button(role.displayName) { appState.selectRole(role) }
                    }
                }

                Divider()
                Button("退出 M2M Display") {
                    appState.quitAll()
                }
                .keyboardShortcut("q")
                .disabled(appState.isQuitting)
            }
        }
        .padding()
        .frame(width: 260)
    }
}

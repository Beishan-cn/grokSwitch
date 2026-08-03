import SwiftUI

@main
struct GrokSwitchApp: App {
    @StateObject private var store = ProfileStore()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(store)
        } label: {
            Label(store.menuBarTitle, systemImage: "arrow.left.arrow.right.circle.fill")
        }
        .menuBarExtraStyle(.window)

        // Settings scene keeps the app from being pure accessory-only in some macOS versions;
        // we still set LSUIElement so there's no Dock icon.
        Settings {
            SettingsView()
                .environmentObject(store)
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var store: ProfileStore

    private var installedTerminals: [TerminalApp] {
        TerminalApp.installed
    }

    var body: some View {
        Form {
            Section("菜单栏") {
                Toggle("在菜单栏显示账号短名", isOn: Binding(
                    get: { store.config.showEmailInMenuBar },
                    set: { newValue in
                        store.setShowEmailInMenuBar(newValue)
                    }
                ))
            }
            Section {
                Picker("默认终端", selection: Binding(
                    get: { store.config.preferredTerminalApp },
                    set: { store.setPreferredTerminal($0) }
                )) {
                    ForEach(pickerTerminals) { app in
                        Text(terminalLabel(app)).tag(app)
                    }
                }
                if !store.config.preferredTerminalApp.isInstalled,
                   store.config.preferredTerminalApp != .terminal {
                    Text("「\(store.config.preferredTerminalApp.displayName)」似乎未安装，打开时可能失败。")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("终端")
            } footer: {
                Text("「用当前账号打开 Grok」会使用此终端启动。支持 Terminal、iTerm2、Ghostty、Otty、Warp、Alacritty、Kitty、WezTerm 等。")
                    .font(.caption)
            }
            Section("路径") {
                LabeledContent("配置目录") {
                    Text(Paths.grokSwitchRoot.path)
                        .font(.caption)
                        .textSelection(.enabled)
                }
                LabeledContent("active.env") {
                    Text(Paths.activeEnvFile.path)
                        .font(.caption)
                        .textSelection(.enabled)
                }
            }
            Section("说明") {
                Text("切换账号后，新开的终端会通过 ~/.zshrc 加载 GROK_HOME。已打开的终端需要重开或手动 source ~/.grokswitch/active.env。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 360)
        .padding()
    }

    /// Installed apps plus current selection (so a missing pick still appears).
    private var pickerTerminals: [TerminalApp] {
        var list = installedTerminals
        let current = store.config.preferredTerminalApp
        if !list.contains(current) {
            list.append(current)
        }
        // Stable order matching CaseIterable
        let order = TerminalApp.allCases
        return list.sorted {
            (order.firstIndex(of: $0) ?? 0) < (order.firstIndex(of: $1) ?? 0)
        }
    }

    private func terminalLabel(_ app: TerminalApp) -> String {
        if app == .terminal || app.isInstalled {
            return app.displayName
        }
        return "\(app.displayName)（未安装）"
    }
}


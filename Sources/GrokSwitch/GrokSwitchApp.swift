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
        .frame(width: 420, height: 280)
        .padding()
    }
}


import SwiftUI

@main
struct GrokSwitchApp: App {
    @StateObject private var store = ProfileStore()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(store)
        } label: {
            // CodexBar-style brand mark (16pt template); remaining % is title text.
            HStack(spacing: 4) {
                MenuBarIcon.image(usage: store.activeUsage)
                    .renderingMode(.template)
                    .frame(width: 16, height: 16)
                Text(store.menuBarTitle)
            }
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
    @State private var scannedProjects: [ProjectFolder] = []

    private var installedTerminals: [TerminalApp] {
        TerminalApp.installed
    }

    var body: some View {
        Form {
            Section("菜单栏") {
                Toggle("在菜单栏显示剩余用量", isOn: Binding(
                    get: { store.config.showUsageInMenuBar },
                    set: { newValue in
                        store.setShowUsageInMenuBar(newValue)
                    }
                ))
                Toggle("无用量数据时显示账号短名", isOn: Binding(
                    get: { store.config.showEmailInMenuBar },
                    set: { newValue in
                        store.setShowEmailInMenuBar(newValue)
                    }
                ))
                Text("菜单栏默认只显示 Grok 图标与剩余百分比，账号名在下拉列表中查看。用量按每个账号的 auth.json 独立查询。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
            Section {
                LabeledContent("扫描目录") {
                    Text(scanRootLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                }
                HStack {
                    Button("选择扫描目录…") {
                        chooseScanRoot()
                    }
                    if ProjectScanner.isUsingConfiguredRoot(store.config.projectsScanRoot) {
                        Button("恢复自动检测") {
                            store.setProjectsScanRoot(nil)
                            refreshScannedProjects()
                        }
                    }
                    Spacer()
                    Button("浏览项目…") {
                        chooseAnyProject()
                    }
                }
                Picker("默认项目", selection: Binding(
                    get: { store.config.preferredProjectPath ?? "" },
                    set: { newValue in
                        store.setPreferredProjectPath(newValue.isEmpty ? nil : newValue)
                    }
                )) {
                    Text("未选择").tag("")
                    ForEach(scannedProjects) { project in
                        Text(project.name).tag(project.path)
                    }
                    // Keep current selection if it is outside the scan root.
                    if let current = store.config.preferredProjectPath,
                       !current.isEmpty,
                       !scannedProjects.contains(where: { $0.path == current }) {
                        Text("\((current as NSString).lastPathComponent)（当前）").tag(current)
                    }
                }
                if let path = store.config.preferredProjectPath, !path.isEmpty {
                    Text(path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            } header: {
                Text("项目")
            } footer: {
                Text(projectSectionFooter)
                    .font(.caption)
            }
            .onAppear {
                refreshScannedProjects()
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
        .frame(width: 440, height: 560)
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

    private var scanRootLabel: String {
        let path = ProjectScanner.displayRoot(configured: store.config.projectsScanRoot)
        if ProjectScanner.isUsingConfiguredRoot(store.config.projectsScanRoot) {
            return path
        }
        if ProjectScanner.resolveRoot(configured: nil) == nil {
            return "未找到（请手动选择）"
        }
        return "\(path)（自动）"
    }

    private var projectSectionFooter: String {
        let root = ProjectScanner.displayRoot(configured: store.config.projectsScanRoot)
        return "扫描 \(root) 下的子文件夹作为候选；也可「浏览项目」任选路径。「用当前账号打开 Grok」会以 grok --cwd 进入所选项目。未配置时自动识别 ~/Projects、~/Developer、~/Code 等常见目录。"
    }

    private func refreshScannedProjects() {
        scannedProjects = ProjectScanner.scan(configuredRoot: store.config.projectsScanRoot)
    }

    private func chooseScanRoot() {
        let start = ProjectScanner.resolveRoot(configured: store.config.projectsScanRoot)
        guard let url = FolderPicker.pickDirectory(
            message: "选择要扫描的项目父目录（其下的一级子文件夹会出现在列表中）",
            prompt: "用作扫描目录",
            startingAt: start
        ) else {
            return
        }
        store.setProjectsScanRoot(url.path)
        refreshScannedProjects()
    }

    private func chooseAnyProject() {
        let start = ProjectScanner.resolveRoot(configured: store.config.projectsScanRoot)
        guard let url = FolderPicker.pickDirectory(
            message: "选择用作默认项目的文件夹（将作为 grok --cwd）",
            prompt: "设为默认项目",
            startingAt: start
        ) else {
            return
        }
        store.setPreferredProjectPath(url.path)
        refreshScannedProjects()
    }
}


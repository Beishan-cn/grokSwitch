import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: ProfileStore

    @State private var scannedProjects: [ProjectFolder] = []
    @State private var profilePendingDelete: Profile?
    @State private var renameDrafts: [String: String] = [:]
    @State private var isAddingAccount = false
    @State private var newProfileName = ""

    private var installedTerminals: [TerminalApp] {
        TerminalApp.installed
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                settingsHeader
                accountsSection
                menuBarSection
                terminalSection
                projectsSection
                pathsSection
                notesSection
            }
            .frame(maxWidth: 680)
            .padding(.horizontal, 28)
            .padding(.vertical, 26)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(
            minWidth: 560,
            idealWidth: 620,
            maxWidth: 760,
            minHeight: 480,
            idealHeight: 700
        )
        .confirmationDialog(
            deleteConfirmationTitle,
            isPresented: Binding(
                get: { profilePendingDelete != nil },
                set: { if !$0 { profilePendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除账号", role: .destructive) {
                if let profile = profilePendingDelete {
                    _ = store.deleteProfile(id: profile.id)
                    renameDrafts.removeValue(forKey: profile.id)
                }
                profilePendingDelete = nil
            }
            Button("取消", role: .cancel) {
                profilePendingDelete = nil
            }
        } message: {
            Text("将永久删除该账号的本地登录数据。")
        }
        .onAppear {
            syncRenameDrafts()
            refreshScannedProjects()
        }
        .onChange(of: store.config.profiles) { _, profiles in
            syncRenameDrafts(with: profiles)
        }
    }

    // MARK: - Header

    private var settingsHeader: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.accentColor.opacity(0.12))
                // Same brand mark as the menu bar (template, tinted).
                MenuBarIcon.image(usage: nil)
                    .renderingMode(.template)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 24, height: 24)
                    .foregroundStyle(.tint)
            }
            .frame(width: 46, height: 46)

            VStack(alignment: .leading, spacing: 3) {
                Text("GrokSwitch")
                    .font(.title2.weight(.semibold))
                Text("管理账号、终端与项目偏好")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Accounts

    private var accountsSection: some View {
        SettingsSectionCard(
            title: "账号",
            systemImage: "person.2",
            footer: "删除会移除该账号的 GROK_HOME 目录（含登录凭证），不可恢复。至少保留一个账号。也可在菜单栏点「管理账号…」。"
        ) {
            VStack(alignment: .leading, spacing: 12) {
                if store.config.profiles.isEmpty {
                    emptyAccountsView
                } else {
                    VStack(spacing: 10) {
                        ForEach(store.config.profiles) { profile in
                            accountManageCard(profile)
                        }
                    }
                }

                if isAddingAccount {
                    addAccountForm
                } else {
                    Button {
                        isAddingAccount = true
                        newProfileName = ""
                    } label: {
                        Label("添加账号…", systemImage: "plus.circle")
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    private var emptyAccountsView: some View {
        VStack(spacing: 8) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            Text("没有账号配置")
                .font(.callout.weight(.medium))
            Text("在此添加账号，或从菜单栏进入账号管理。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
    }

    private var addAccountForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("独立 GROK_HOME · 创建后打开终端运行 grok login")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("显示名称（如 工作 / 个人）", text: $newProfileName)
                .textFieldStyle(.roundedBorder)
                .onSubmit { confirmAddAccount() }

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("取消") {
                    isAddingAccount = false
                    newProfileName = ""
                }
                Button("创建") {
                    confirmAddAccount()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(newProfileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(nsColor: .textBackgroundColor).opacity(0.45),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 1)
        }
    }

    private func confirmAddAccount() {
        // Match menu bar: activate and open terminal so user can run grok login.
        if let profile = store.addProfile(name: newProfileName, activate: true) {
            isAddingAccount = false
            newProfileName = ""
            store.openTerminal(for: profile)
        }
    }

    // MARK: - Menu bar

    private var menuBarSection: some View {
        SettingsSectionCard(
            title: "菜单栏",
            systemImage: "menubar.rectangle",
            footer: "菜单栏默认只显示 Grok 图标与剩余百分比；开启上方开关后，在无用量数据时显示账号短名。账号名始终可在下拉列表中查看。用量按每个账号的 auth.json 独立查询。"
        ) {
            VStack(spacing: 0) {
                Toggle("在菜单栏显示剩余用量", isOn: Binding(
                    get: { store.config.showUsageInMenuBar },
                    set: { store.setShowUsageInMenuBar($0) }
                ))
                .settingsControlRow()

                Divider()

                Toggle("无用量数据时显示账号短名", isOn: Binding(
                    get: { store.config.showEmailInMenuBar },
                    set: { store.setShowEmailInMenuBar($0) }
                ))
                .settingsControlRow()
            }
        }
    }

    // MARK: - Terminal

    private var terminalSection: some View {
        SettingsSectionCard(
            title: "终端",
            systemImage: "terminal",
            footer: "「用当前账号打开 Grok」会使用此终端启动。支持 Terminal、iTerm2、Ghostty、Otty、Warp、Alacritty、Kitty、WezTerm 等。"
        ) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 16) {
                    Text("默认终端")
                        .layoutPriority(1)
                    Spacer(minLength: 12)
                    Picker("默认终端", selection: Binding(
                        get: { store.config.preferredTerminalApp },
                        set: { store.setPreferredTerminal($0) }
                    )) {
                        ForEach(pickerTerminals) { app in
                            Text(terminalLabel(app))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .tag(app)
                        }
                    }
                    .labelsHidden()
                    .frame(minWidth: 140, idealWidth: 220, maxWidth: 320, alignment: .trailing)
                    .layoutPriority(0)
                }

                if !store.config.preferredTerminalApp.isInstalled,
                   store.config.preferredTerminalApp != .terminal {
                    Label(
                        "「\(store.config.preferredTerminalApp.displayName)」似乎未安装，打开时可能失败。",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
            }
        }
    }

    // MARK: - Projects

    private var projectsSection: some View {
        SettingsSectionCard(
            title: "项目",
            systemImage: "folder",
            footer: projectSectionFooter
        ) {
            VStack(alignment: .leading, spacing: 14) {
                // Scan root tools
                VStack(alignment: .leading, spacing: 10) {
                    settingsValueRow(title: "扫描目录", value: scanRootLabel)

                    HStack(spacing: 8) {
                        Button("选择扫描目录…") {
                            chooseScanRoot()
                        }
                        if ProjectScanner.isUsingConfiguredRoot(store.config.projectsScanRoot) {
                            Button("恢复自动检测") {
                                store.setProjectsScanRoot(nil)
                                refreshScannedProjects()
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .controlSize(.small)
                }

                Divider()

                // Default project tools
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        Text("默认项目")
                            .layoutPriority(1)
                        Spacer(minLength: 12)
                        Picker("默认项目", selection: Binding(
                            get: { store.config.preferredProjectPath ?? "" },
                            set: { newValue in
                                store.setPreferredProjectPath(newValue.isEmpty ? nil : newValue)
                            }
                        )) {
                            Text("未选择").tag("")
                            ForEach(scannedProjects) { project in
                                Text(project.name)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .tag(project.path)
                            }
                            if let current = store.config.preferredProjectPath,
                               !current.isEmpty,
                               !scannedProjects.contains(where: { $0.path == current }) {
                                Text("\((current as NSString).lastPathComponent)（当前）")
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .tag(current)
                            }
                        }
                        .labelsHidden()
                        .frame(minWidth: 160, idealWidth: 240, maxWidth: 360, alignment: .trailing)
                    }

                    HStack(spacing: 8) {
                        Button("浏览项目…") {
                            chooseAnyProject()
                        }
                        .help("任选文件夹作为默认项目（不必在扫描目录下）")
                        Spacer(minLength: 0)
                    }
                    .controlSize(.small)

                    if let path = store.config.preferredProjectPath, !path.isEmpty {
                        Text(path)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    // MARK: - Paths & notes

    private var pathsSection: some View {
        SettingsSectionCard(title: "路径", systemImage: "point.topleft.down.to.point.bottomright.curvepath") {
            VStack(spacing: 0) {
                settingsValueRow(title: "配置目录", value: Paths.grokSwitchRoot.path)
                    .padding(.bottom, 13)
                Divider()
                settingsValueRow(title: "active.env", value: Paths.activeEnvFile.path)
                    .padding(.top, 13)
            }
        }
    }

    private var notesSection: some View {
        SettingsSectionCard(title: "说明", systemImage: "info.circle") {
            Text("切换账号后，新开的 zsh 终端会通过 ~/.zshrc 加载 GROK_HOME。bash/fish 请手动 source ~/.grokswitch/active.env。已打开的终端需要重开。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Account card

    private var deleteConfirmationTitle: String {
        if let name = profilePendingDelete?.name {
            return "删除「\(name)」？"
        }
        return "删除账号？"
    }

    @ViewBuilder
    private func accountManageCard(_ profile: Profile) -> some View {
        let identity = store.identities[profile.id]
        let isActive = store.activeProfile?.id == profile.id
        let canDelete = store.config.profiles.count > 1

        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                ZStack {
                    Circle()
                        .fill(isActive ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.10))
                    Image(systemName: identity == nil ? "person.crop.circle.badge.xmark" : "person.crop.circle")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                }
                .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 4) {
                    TextField(
                        "显示名称",
                        text: Binding(
                            get: { renameDrafts[profile.id] ?? profile.name },
                            set: { renameDrafts[profile.id] = $0 }
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        commitRename(profileID: profile.id)
                    }

                    Text(identity?.detailLabel ?? "未登录")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if isActive {
                    Text("当前")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tint)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.accentColor.opacity(0.10), in: Capsule())
                        .overlay {
                            Capsule()
                                .stroke(Color.accentColor.opacity(0.22), lineWidth: 1)
                        }
                }
            }

            HStack(spacing: 8) {
                Button("保存名称") {
                    commitRename(profileID: profile.id)
                }
                .disabled(!canCommitRename(profile))

                Button {
                    store.openTerminal(for: profile)
                } label: {
                    Label("打开终端", systemImage: "terminal")
                }

                Spacer(minLength: 12)

                Button("删除", role: .destructive) {
                    profilePendingDelete = profile
                }
                .disabled(!canDelete)
                .help(canDelete ? "删除此账号及其登录数据" : "至少保留一个账号")
            }
            .controlSize(.small)
        }
        .padding(14)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.55), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(
                    isActive ? Color.accentColor.opacity(0.34) : Color(nsColor: .separatorColor).opacity(0.55),
                    lineWidth: 1
                )
        }
    }

    private func settingsValueRow(title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(title)
            Spacer(minLength: 20)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Rename helpers

    private func canCommitRename(_ profile: Profile) -> Bool {
        let draft = (renameDrafts[profile.id] ?? profile.name)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return !draft.isEmpty && draft != profile.name
    }

    private func commitRename(profileID: String) {
        let draft = renameDrafts[profileID] ?? ""
        if store.renameProfile(id: profileID, name: draft) {
            renameDrafts[profileID] = store.config.profiles
                .first(where: { $0.id == profileID })?.name ?? draft
        }
    }

    private func syncRenameDrafts(with profiles: [Profile]? = nil) {
        let list = profiles ?? store.config.profiles
        var drafts: [String: String] = [:]
        // Re-seed from store so menu renames cannot be undone by stale Settings drafts.
        // In-progress edits are lost when the profile list changes; acceptable for this UI.
        for profile in list {
            drafts[profile.id] = profile.name
        }
        renameDrafts = drafts
    }

    // MARK: - Terminal / project helpers

    /// Installed apps plus current selection (so a missing pick still appears).
    private var pickerTerminals: [TerminalApp] {
        var list = installedTerminals
        let current = store.config.preferredTerminalApp
        if !list.contains(current) {
            list.append(current)
        }
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

// MARK: - Section card

private struct SettingsSectionCard<Content: View>: View {
    let title: String
    let systemImage: String
    let footer: String?
    @ViewBuilder let content: Content

    init(
        title: String,
        systemImage: String,
        footer: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .foregroundStyle(.primary)
                .symbolRenderingMode(.hierarchical)

            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 1)
            }

            if let footer {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
            }
        }
    }
}

private extension View {
    func settingsControlRow() -> some View {
        self
            .controlSize(.regular)
            .padding(.vertical, 11)
    }
}

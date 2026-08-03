import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: ProfileStore

    @State private var scannedProjects: [ProjectFolder] = []
    @State private var profilePendingDelete: Profile?
    /// Inline rename: only one account at a time (display by default, edit on demand).
    @State private var renamingProfileID: String?
    @State private var renameDraft = ""
    @State private var isAddingAccount = false
    @State private var newProfileName = ""
    @FocusState private var renameFieldFocused: Bool

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
                    if renamingProfileID == profile.id {
                        cancelRename()
                    }
                    _ = store.deleteProfile(id: profile.id)
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
            refreshScannedProjects()
        }
        .onChange(of: store.config.profiles) { _, profiles in
            // Drop rename draft if the profile was removed elsewhere (e.g. menu bar).
            if let id = renamingProfileID, !profiles.contains(where: { $0.id == id }) {
                cancelRename()
            }
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
            footer: "删除会移除该账号的 GROK_HOME（含登录凭证），不可恢复。至少保留一个账号。"
        ) {
            VStack(alignment: .leading, spacing: 0) {
                if store.config.profiles.isEmpty, !isAddingAccount {
                    emptyAccountsView
                    Divider()
                } else if !store.config.profiles.isEmpty {
                    ForEach(Array(store.config.profiles.enumerated()), id: \.element.id) { index, profile in
                        if index > 0 {
                            Divider()
                        }
                        accountRow(profile)
                    }
                    Divider()
                }

                if isAddingAccount {
                    addAccountForm
                } else {
                    Button {
                        beginAddAccount()
                    } label: {
                        Label("添加账号…", systemImage: "plus.circle")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                    .padding(.vertical, 11)
                }
            }
        }
    }

    private var emptyAccountsView: some View {
        VStack(spacing: 8) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            Text("没有账号")
                .font(.callout.weight(.medium))
            Text("添加一个账号后即可切换 GROK_HOME 并登录。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
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
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func beginAddAccount() {
        cancelRename()
        isAddingAccount = true
        newProfileName = ""
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
            // Two related toggles side-by-side — fills the card without the sparse two-row list look.
            HStack(alignment: .center, spacing: 20) {
                Toggle("显示剩余用量", isOn: Binding(
                    get: { store.config.showUsageInMenuBar },
                    set: { store.setShowUsageInMenuBar($0) }
                ))
                .help("在菜单栏显示当前账号的剩余用量百分比")
                .frame(maxWidth: .infinity, alignment: .leading)

                Toggle("无用量时显示短名", isOn: Binding(
                    get: { store.config.showEmailInMenuBar },
                    set: { store.setShowEmailInMenuBar($0) }
                ))
                .help("无用量数据时在菜单栏显示账号短名；账号名始终可在下拉列表中查看")
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .controlSize(.regular)
            .toggleStyle(.checkbox)
            .padding(.vertical, 4)
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

    // MARK: - Account row

    private var deleteConfirmationTitle: String {
        if let name = profilePendingDelete?.name {
            return "删除「\(name)」？"
        }
        return "删除账号？"
    }

    @ViewBuilder
    private func accountRow(_ profile: Profile) -> some View {
        let identity = store.identities[profile.id]
        let usage = store.usages[profile.id]
        let isActive = store.activeProfile?.id == profile.id
        let isRenaming = renamingProfileID == profile.id
        let canDelete = store.config.profiles.count > 1

        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                // Login status + person glyph (aligned with menu bar semantics).
                ZStack(alignment: .bottomTrailing) {
                    ZStack {
                        Circle()
                            .fill(isActive ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.10))
                        Image(systemName: isActive ? "checkmark.circle.fill" : "person.crop.circle")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                    }
                    .frame(width: 32, height: 32)

                    Circle()
                        .fill(loginStatusColor(identity))
                        .frame(width: 8, height: 8)
                        .overlay {
                            Circle()
                                .stroke(Color(nsColor: .controlBackgroundColor), lineWidth: 1.5)
                        }
                        .offset(x: 1, y: 1)
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(profile.name)
                            .font(.body.weight(isActive ? .semibold : .regular))
                            .lineLimit(1)

                        if isActive {
                            Text("当前")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tint)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.10), in: Capsule())
                        }
                    }

                    Text(identity?.detailLabel ?? "未登录")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                if let label = usage?.remainingLabel, usage?.status == .ready {
                    Text(label)
                        .font(.body.monospacedDigit().weight(.semibold))
                        .foregroundStyle(usageColor(usage?.severity))
                }

                Menu {
                    Button("重命名") {
                        beginRename(profile)
                    }
                    Button("打开终端") {
                        store.openTerminal(for: profile)
                    }
                    Divider()
                    Button("删除…", role: .destructive) {
                        profilePendingDelete = profile
                    }
                    .disabled(!canDelete)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 24)
                .help(canDelete ? "更多操作" : "更多操作（至少保留一个账号）")
            }
            .padding(.vertical, 11)
            .accessibilityElement(children: .combine)

            if isRenaming {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("显示名称", text: $renameDraft)
                        .textFieldStyle(.roundedBorder)
                        .focused($renameFieldFocused)
                        .onSubmit { commitRename(profileID: profile.id) }
                        .onAppear {
                            renameFieldFocused = true
                        }

                    HStack(spacing: 8) {
                        Spacer(minLength: 0)
                        Button("取消") {
                            cancelRename()
                        }
                        Button("完成") {
                            commitRename(profileID: profile.id)
                        }
                        .keyboardShortcut(.defaultAction)
                        .disabled(renameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .controlSize(.small)
                }
                .padding(.leading, 44)
                .padding(.bottom, 12)
            }
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

    // MARK: - Account helpers

    private func loginStatusColor(_ identity: AccountIdentity?) -> Color {
        guard let identity else {
            return Color.orange.opacity(0.85)
        }
        if identity.hasBrokenAuthFile {
            return Color.red.opacity(0.85)
        }
        if identity.isLoggedIn, !identity.isExpired {
            return Color.green.opacity(0.85)
        }
        return Color.orange.opacity(0.85)
    }

    private func usageColor(_ severity: UsageSeverity?) -> Color {
        switch severity {
        case .ok:
            return Color.green
        case .warning:
            return Color.orange
        case .critical:
            return Color.red
        case .unknown, .none:
            return Color.secondary
        }
    }

    private func beginRename(_ profile: Profile) {
        isAddingAccount = false
        newProfileName = ""
        renamingProfileID = profile.id
        renameDraft = profile.name
    }

    private func cancelRename() {
        renamingProfileID = nil
        renameDraft = ""
        renameFieldFocused = false
    }

    private func commitRename(profileID: String) {
        let draft = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !draft.isEmpty else { return }
        if store.renameProfile(id: profileID, name: draft) {
            cancelRename()
        }
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

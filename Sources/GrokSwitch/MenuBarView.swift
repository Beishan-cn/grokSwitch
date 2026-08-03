import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var store: ProfileStore
    @Environment(\.openSettings) private var openSettings
    /// Inline expander for add-account form (sheet on MenuBarExtra breaks after focus loss).
    @State private var isAdding = false
    @State private var newProfileName = ""
    /// Manage mode: rename / delete instead of switch-on-click.
    @State private var isManaging = false
    @State private var renamingProfileID: String?
    @State private var renameDraft = ""
    @State private var confirmingDeleteID: String?
    /// Inline expander for terminal list (sheet on MenuBarExtra is flaky and auto-closes).
    @State private var isChoosingTerminal = false
    /// Pending pick while the expander is open; committed only on 完成.
    @State private var pendingTerminal: TerminalApp = .terminal
    /// Inline expander for project list under the scan root.
    @State private var isChoosingProject = false
    /// Pending project path (`nil` = no project). Committed only on 完成.
    @State private var pendingProjectPath: String? = nil
    @State private var scannedProjects: [ProjectFolder] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            profileList
            Divider()
            actions
            if let status = store.statusMessage {
                Divider()
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
            if let error = store.lastError {
                Divider()
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
            Divider()
            footer
        }
        .padding(.vertical, 4)
        .frame(minWidth: 280)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("GrokSwitch")
                    .font(.headline)
                if let active = store.activeProfile {
                    let identity = store.identities[active.id]
                    // Usage / GROK_HOME path live elsewhere (profile rows, Settings) so the
                    // header stays a compact identity summary.
                    Text(identity?.detailLabel ?? active.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else {
                    Text("尚未配置账号")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Button {
                store.reload()
                store.refreshUsage(force: true)
                store.noteStatus("已刷新账号与用量")
            } label: {
                if store.isRefreshingUsage {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .disabled(store.isRefreshingUsage)
            .help("刷新账号与用量")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var profileList: some View {
        Group {
            if store.config.profiles.isEmpty {
                Text("没有账号配置")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            } else if store.config.profiles.count > 8 {
                // Scroll only when many accounts. A bare ScrollView in MenuBarExtra's VStack
                // often collapses to 0 height → stacked Dividers look double and rows vanish.
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(store.config.profiles) { profile in
                            profileRow(profile)
                        }
                    }
                }
                .frame(maxHeight: 280)
            } else {
                VStack(spacing: 0) {
                    ForEach(store.config.profiles) { profile in
                        profileRow(profile)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func profileRow(_ profile: Profile) -> some View {
        if isManaging {
            manageProfileRow(profile)
        } else {
            switchProfileRow(profile)
        }
    }

    private func switchProfileRow(_ profile: Profile) -> some View {
        let isActive = store.activeProfile?.id == profile.id
        let identity = store.identities[profile.id]
        let usage = store.usages[profile.id]
        return Button {
            _ = store.switchTo(profileID: profile.id)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                    .font(.body)
                VStack(alignment: .leading, spacing: 1) {
                    Text(profile.name)
                        .font(.body.weight(isActive ? .semibold : .regular))
                    Text(identity?.detailLabel ?? "未登录")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let secondary = usage?.rowSecondaryLabel {
                        Text(secondary)
                            .font(.caption2)
                            .foregroundStyle(usageColor(usage?.severity))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if let label = usage?.remainingLabel, usage?.status == .ready {
                    Text(label)
                        .font(.body.monospacedDigit().weight(.semibold))
                        .foregroundStyle(usageColor(usage?.severity))
                } else if identity?.hasBrokenAuthFile == true {
                    Circle()
                        .fill(Color.red.opacity(0.85))
                        .frame(width: 7, height: 7)
                } else if identity?.isLoggedIn == true, identity?.isExpired != true {
                    Circle()
                        .fill(Color.green.opacity(0.85))
                        .frame(width: 7, height: 7)
                } else {
                    Circle()
                        .fill(Color.orange.opacity(0.85))
                        .frame(width: 7, height: 7)
                }
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(MenuRowButtonStyle())
        .padding(.horizontal, 4)
    }

    private func manageProfileRow(_ profile: Profile) -> some View {
        let isActive = store.activeProfile?.id == profile.id
        let identity = store.identities[profile.id]
        let isRenaming = renamingProfileID == profile.id
        let isConfirmingDelete = confirmingDeleteID == profile.id
        let canDelete = store.config.profiles.count > 1

        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: isActive ? "checkmark.circle.fill" : "person.crop.circle")
                    .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                    .font(.body)
                VStack(alignment: .leading, spacing: 1) {
                    Text(profile.name)
                        .font(.body.weight(isActive ? .semibold : .regular))
                    Text(identity?.detailLabel ?? "未登录")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Button("重命名") {
                    isAdding = false
                    newProfileName = ""
                    confirmingDeleteID = nil
                    renamingProfileID = profile.id
                    renameDraft = profile.name
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("删除", role: .destructive) {
                    isAdding = false
                    newProfileName = ""
                    renamingProfileID = nil
                    renameDraft = ""
                    confirmingDeleteID = profile.id
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!canDelete)
                .help(canDelete ? "删除此账号及其登录数据" : "至少保留一个账号")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            if isRenaming {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("显示名称", text: $renameDraft)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { confirmRename(profileID: profile.id) }

                    HStack(spacing: 8) {
                        Button("取消") {
                            renamingProfileID = nil
                            renameDraft = ""
                        }
                        .buttonStyle(.bordered)

                        Button("完成") { confirmRename(profileID: profile.id) }
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.defaultAction)
                            .disabled(renameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }

            if isConfirmingDelete {
                VStack(alignment: .leading, spacing: 8) {
                    Text("删除「\(profile.name)」？将移除其 GROK_HOME（含登录凭证），不可恢复。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 8) {
                        Button("取消") {
                            confirmingDeleteID = nil
                        }
                        .buttonStyle(.bordered)

                        Button("确认删除", role: .destructive) {
                            confirmDelete(profileID: profile.id)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
        }
        .padding(.horizontal, 4)
    }

    private var actions: some View {
        VStack(spacing: 0) {
            Button {
                store.openTerminal()
            } label: {
                labelRow(
                    systemImage: "terminal",
                    title: "用当前账号打开 Grok",
                    subtitle: openGrokSubtitle
                )
            }
            .buttonStyle(MenuRowButtonStyle())
            .padding(.horizontal, 4)

            Button {
                if isChoosingTerminal {
                    // Collapse without saving
                    isChoosingTerminal = false
                } else {
                    collapseAccountEditors()
                    isChoosingProject = false
                    pendingTerminal = store.config.preferredTerminalApp
                    isChoosingTerminal = true
                }
            } label: {
                labelRow(
                    systemImage: "macwindow.on.rectangle",
                    title: isChoosingTerminal ? "默认终端" : "默认终端…",
                    subtitle: isChoosingTerminal
                        ? pendingTerminal.displayName
                        : store.config.preferredTerminalApp.displayName
                )
            }
            .buttonStyle(MenuRowButtonStyle())
            .padding(.horizontal, 4)

            if isChoosingTerminal {
                terminalPickerInline
            }

            Button {
                if isChoosingProject {
                    isChoosingProject = false
                } else {
                    isChoosingTerminal = false
                    collapseAccountEditors()
                    pendingProjectPath = store.config.preferredProjectPath
                    refreshScannedProjects()
                    isChoosingProject = true
                }
            } label: {
                labelRow(
                    systemImage: "folder",
                    title: isChoosingProject ? "默认项目" : "默认项目…",
                    subtitle: isChoosingProject
                        ? projectDisplayName(pendingProjectPath)
                        : store.config.preferredProjectDisplayName
                )
            }
            .buttonStyle(MenuRowButtonStyle())
            .padding(.horizontal, 4)

            if isChoosingProject {
                projectPickerInline
            }

            Button {
                if isManaging {
                    exitManageMode()
                } else {
                    isChoosingTerminal = false
                    isChoosingProject = false
                    isManaging = true
                }
            } label: {
                labelRow(
                    systemImage: "person.crop.circle.badge.checkmark",
                    title: isManaging ? "完成管理" : "管理账号…"
                )
            }
            .buttonStyle(MenuRowButtonStyle())
            .padding(.horizontal, 4)

            if isManaging {
                manageAccountsInline
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Button {
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            } label: {
                labelRow(systemImage: "gearshape", title: "设置…")
            }
            .buttonStyle(MenuRowButtonStyle())
            .padding(.horizontal, 4)

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                labelRow(systemImage: "power", title: "退出 GrokSwitch")
            }
            .buttonStyle(MenuRowButtonStyle())
            .padding(.horizontal, 4)
        }
    }

    /// Account management extras under「管理账号」：add form lives here, not as a top-level action.
    private var manageAccountsInline: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                if isAdding {
                    isAdding = false
                    newProfileName = ""
                } else {
                    renamingProfileID = nil
                    renameDraft = ""
                    confirmingDeleteID = nil
                    newProfileName = ""
                    isAdding = true
                }
            } label: {
                labelRow(
                    systemImage: "plus.circle",
                    title: isAdding ? "添加账号" : "添加账号…"
                )
            }
            .buttonStyle(MenuRowButtonStyle())
            .padding(.horizontal, 4)

            if isAdding {
                addProfileInline
            }
        }
    }

    /// Inline form under the menu (no sheet — MenuBarExtra sheets break after focus loss).
    private var addProfileInline: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("独立 GROK_HOME · 创建后打开终端运行 grok login")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("显示名称（如 工作 / 个人）", text: $newProfileName)
                .textFieldStyle(.roundedBorder)
                .onSubmit { confirmAdd() }

            HStack(spacing: 8) {
                Button("取消") {
                    isAdding = false
                    newProfileName = ""
                }
                .buttonStyle(.bordered)

                Button("创建") { confirmAdd() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(newProfileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.top, 2)
        .padding(.bottom, 8)
    }

    private func confirmAdd() {
        if let profile = store.addProfile(name: newProfileName, activate: true) {
            isAdding = false
            newProfileName = ""
            store.openTerminal(for: profile)
        }
    }

    private func confirmRename(profileID: String) {
        if store.renameProfile(id: profileID, name: renameDraft) {
            renamingProfileID = nil
            renameDraft = ""
        }
    }

    private func confirmDelete(profileID: String) {
        if store.deleteProfile(id: profileID) {
            confirmingDeleteID = nil
            if renamingProfileID == profileID {
                renamingProfileID = nil
                renameDraft = ""
            }
        }
    }

    private func exitManageMode() {
        isManaging = false
        isAdding = false
        newProfileName = ""
        renamingProfileID = nil
        renameDraft = ""
        confirmingDeleteID = nil
    }

    private func collapseAccountEditors() {
        exitManageMode()
    }

    /// Inline list under the menu (no sheet — avoids MenuBarExtra auto-dismiss).
    private var terminalPickerInline: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("点选后按「完成」保存")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 16)
                .padding(.top, 2)
                .padding(.bottom, 4)

            ForEach(pickerTerminals) { app in
                let isSelected = pendingTerminal == app
                Button {
                    // Only update local pending state — do not dismiss / save yet.
                    pendingTerminal = app
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                            .frame(width: 16)
                        Text(app.displayName)
                            .font(.body.weight(isSelected ? .semibold : .regular))
                        Spacer(minLength: 8)
                        if !app.isInstalled && app != .terminal {
                            Text("未安装")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(MenuRowButtonStyle())
                .padding(.horizontal, 12)
            }

            HStack(spacing: 8) {
                Button("取消") {
                    isChoosingTerminal = false
                }
                .buttonStyle(.bordered)

                Button("完成") {
                    store.setPreferredTerminal(pendingTerminal)
                    isChoosingTerminal = false
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 4)
        }
        .padding(.bottom, 4)
    }

    private var pickerTerminals: [TerminalApp] {
        var list = TerminalApp.installed
        // Keep both the saved preference and the in-progress pick visible.
        for extra in [store.config.preferredTerminalApp, pendingTerminal] {
            if !list.contains(extra) {
                list.append(extra)
            }
        }
        let order = TerminalApp.allCases
        return list.sorted {
            (order.firstIndex(of: $0) ?? 0) < (order.firstIndex(of: $1) ?? 0)
        }
    }

    /// Inline project list under the menu (same pattern as terminal picker).
    private var projectPickerInline: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(projectScanHint)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 16)
                .padding(.top, 2)
                .padding(.bottom, 4)

            // None option
            Button {
                pendingProjectPath = nil
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: pendingProjectPath == nil ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(pendingProjectPath == nil ? Color.accentColor : Color.secondary)
                        .frame(width: 16)
                    Text("未选择")
                        .font(.body.weight(pendingProjectPath == nil ? .semibold : .regular))
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(MenuRowButtonStyle())
            .padding(.horizontal, 12)

            if scannedProjects.isEmpty {
                Text(emptyProjectsMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 6)
            } else if scannedProjects.count > 10 {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(scannedProjects) { project in
                            projectPickRow(project)
                        }
                    }
                }
                .frame(maxHeight: 240)
            } else {
                VStack(spacing: 0) {
                    ForEach(scannedProjects) { project in
                        projectPickRow(project)
                    }
                }
            }

            // Keep a saved path visible if it is outside the scan root or was renamed.
            if let pending = pendingProjectPath,
               !scannedProjects.contains(where: { $0.path == pending }) {
                let name = (pending as NSString).lastPathComponent
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 16)
                    Text(name)
                        .font(.body.weight(.semibold))
                    Spacer(minLength: 8)
                    Text("当前")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 6)
            }

            // Free-form pick + scan-root change (not everyone uses ~/Projects).
            HStack(spacing: 8) {
                Button("浏览…") {
                    browseAnyProject()
                }
                .buttonStyle(.bordered)

                Button("扫描目录…") {
                    changeScanRoot()
                }
                .buttonStyle(.bordered)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)

            HStack(spacing: 8) {
                Button("取消") {
                    isChoosingProject = false
                }
                .buttonStyle(.bordered)

                Button("完成") {
                    store.setPreferredProjectPath(pendingProjectPath)
                    isChoosingProject = false
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 4)
        }
        .padding(.bottom, 4)
    }

    private func projectPickRow(_ project: ProjectFolder) -> some View {
        let isSelected = pendingProjectPath == project.path
        return Button {
            pendingProjectPath = project.path
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .frame(width: 16)
                Text(project.name)
                    .font(.body.weight(isSelected ? .semibold : .regular))
                    .lineLimit(1)
                Spacer(minLength: 8)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(MenuRowButtonStyle())
        .padding(.horizontal, 12)
    }

    private var projectScanHint: String {
        let root = ProjectScanner.displayRoot(configured: store.config.projectsScanRoot)
        let mode = ProjectScanner.isUsingConfiguredRoot(store.config.projectsScanRoot) ? "" : "（自动）"
        return "扫描 \(root)\(mode) · 点选后按「完成」保存"
    }

    private var emptyProjectsMessage: String {
        if ProjectScanner.resolveRoot(configured: store.config.projectsScanRoot) == nil {
            return "未找到常见项目目录，请点「扫描目录…」或「浏览…」"
        }
        return "该目录下没有子文件夹，可「浏览…」任选路径"
    }

    private func refreshScannedProjects() {
        scannedProjects = ProjectScanner.scan(configuredRoot: store.config.projectsScanRoot)
    }

    private func browseAnyProject() {
        let start = ProjectScanner.resolveRoot(configured: store.config.projectsScanRoot)
        guard let url = FolderPicker.pickDirectory(
            message: "选择用作默认项目的文件夹",
            prompt: "设为默认项目",
            startingAt: start
        ) else {
            return
        }
        // Commit immediately: MenuBarExtra often dismisses when the panel steals focus.
        pendingProjectPath = url.path
        store.setPreferredProjectPath(url.path)
        refreshScannedProjects()
    }

    private func changeScanRoot() {
        let start = ProjectScanner.resolveRoot(configured: store.config.projectsScanRoot)
        guard let url = FolderPicker.pickDirectory(
            message: "选择要扫描的项目父目录",
            prompt: "用作扫描目录",
            startingAt: start
        ) else {
            return
        }
        store.setProjectsScanRoot(url.path)
        refreshScannedProjects()
    }

    private func projectDisplayName(_ path: String?) -> String {
        guard let path, !path.isEmpty else { return "未选择" }
        return (path as NSString).lastPathComponent
    }

    private var openGrokSubtitle: String {
        let terminal = store.config.preferredTerminalApp.displayName
        if let path = store.config.preferredProjectPath, !path.isEmpty {
            return "\(terminal) · \((path as NSString).lastPathComponent)"
        }
        return terminal
    }

    private func labelRow(systemImage: String, title: String, subtitle: String? = nil) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .frame(width: 16)
            Text(title)
            Spacer(minLength: 8)
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
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
}

/// Menu-style row highlight for hover / pressed states.
private struct MenuRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        MenuRowButton(configuration: configuration)
    }

    private struct MenuRowButton: View {
        let configuration: ButtonStyle.Configuration
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(fillColor)
                )
                .onHover { hovering in
                    isHovered = hovering
                }
        }

        private var fillColor: Color {
            if configuration.isPressed {
                return Color.primary.opacity(0.14)
            }
            if isHovered {
                return Color.primary.opacity(0.08)
            }
            return .clear
        }
    }
}

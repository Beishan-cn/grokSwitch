import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var store: ProfileStore
    @State private var isAdding = false
    @State private var newProfileName = ""

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
        .sheet(isPresented: $isAdding) {
            addProfileSheet
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("GrokSwitch")
                .font(.headline)
            if let active = store.activeProfile {
                let identity = store.identities[active.id]
                Text(identity?.detailLabel ?? active.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Text("GROK_HOME → \(shortHome(active))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text("尚未配置账号")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
            } else {
                ForEach(store.config.profiles) { profile in
                    profileRow(profile)
                }
            }
        }
    }

    private func profileRow(_ profile: Profile) -> some View {
        let isActive = store.activeProfile?.id == profile.id
        let identity = store.identities[profile.id]
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
                }
                Spacer(minLength: 8)
                if identity?.isLoggedIn == true {
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

    private var actions: some View {
        VStack(spacing: 0) {
            Button {
                store.openTerminal()
            } label: {
                labelRow(systemImage: "terminal", title: "用当前账号打开 Grok")
            }
            .buttonStyle(MenuRowButtonStyle())
            .padding(.horizontal, 4)

            Button {
                store.copyLaunchCommand()
            } label: {
                labelRow(systemImage: "doc.on.clipboard", title: "复制启动命令")
            }
            .buttonStyle(MenuRowButtonStyle())
            .padding(.horizontal, 4)

            Button {
                newProfileName = ""
                isAdding = true
            } label: {
                labelRow(systemImage: "plus.circle", title: "添加账号…")
            }
            .buttonStyle(MenuRowButtonStyle())
            .padding(.horizontal, 4)

            Button {
                store.reload()
                store.statusMessage = "已刷新账号状态"
            } label: {
                labelRow(systemImage: "arrow.clockwise", title: "刷新")
            }
            .buttonStyle(MenuRowButtonStyle())
            .padding(.horizontal, 4)
        }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Button {
                NSApp.activate(ignoringOtherApps: true)
                // Reveal config folder
                NSWorkspace.shared.open(Paths.grokSwitchRoot)
            } label: {
                labelRow(systemImage: "folder", title: "打开配置目录")
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

    private var addProfileSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("添加 Grok 账号")
                .font(.title3.weight(.semibold))
            Text("会创建一个独立的 GROK_HOME 目录。创建后用该账号打开终端，运行 grok login 完成登录。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("显示名称（如 工作 / 个人）", text: $newProfileName)
                .textFieldStyle(.roundedBorder)
                .onSubmit { confirmAdd() }

            HStack {
                Spacer()
                Button("取消") { isAdding = false }
                    .keyboardShortcut(.cancelAction)
                Button("创建") { confirmAdd() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(newProfileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    private func confirmAdd() {
        if let profile = store.addProfile(name: newProfileName) {
            isAdding = false
            // Switch to the new profile and open terminal for login
            _ = store.switchTo(profileID: profile.id)
            store.openTerminal(for: profile)
        }
    }

    private func labelRow(systemImage: String, title: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .frame(width: 16)
            Text(title)
            Spacer()
        }
        .contentShape(Rectangle())
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func shortHome(_ profile: Profile) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = profile.homeURL.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
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

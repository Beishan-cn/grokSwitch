import AppKit
import Combine
import Foundation

@MainActor
final class ProfileStore: ObservableObject {
    @Published private(set) var config: AppConfig
    @Published private(set) var identities: [String: AccountIdentity] = [:]
    @Published var lastError: String?
    @Published var statusMessage: String?

    private let fm = FileManager.default
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    init() {
        self.config = .empty
        bootstrapIfNeeded()
        reload()
    }

    var activeProfile: Profile? {
        guard let id = config.activeProfileID else { return config.profiles.first }
        return config.profiles.first(where: { $0.id == id }) ?? config.profiles.first
    }

    var menuBarTitle: String {
        guard let profile = activeProfile else { return "Grok" }
        if config.showEmailInMenuBar {
            let identity = identities[profile.id]
            let short = identity?.shortLabel ?? profile.name
            return "G·\(short)"
        }
        return "G·\(profile.name)"
    }

    func reload() {
        ensureDirectories()
        config = loadConfig()
        if config.profiles.isEmpty {
            seedDefaultProfileFromExistingGrokHome()
            config = loadConfig()
        }
        refreshIdentities()
        // Keep env hook in sync with active profile
        if let active = activeProfile {
            try? writeActiveEnv(for: active)
            _ = ShellHook.ensureInstalled()
        }
    }

    func refreshIdentities() {
        var map: [String: AccountIdentity] = [:]
        for profile in config.profiles {
            map[profile.id] = AuthReader.identity(at: profile.authURL)
        }
        identities = map
    }

    @discardableResult
    func switchTo(profileID: String) -> Bool {
        guard let profile = config.profiles.first(where: { $0.id == profileID }) else {
            lastError = "找不到账号配置"
            return false
        }
        config.activeProfileID = profile.id
        do {
            try saveConfig()
            try writeActiveEnv(for: profile)
            _ = ShellHook.ensureInstalled()
            refreshIdentities()
            statusMessage = "已切换到 \(profile.name)。新开终端生效。"
            lastError = nil
            return true
        } catch {
            lastError = "切换失败：\(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    func addProfile(name: String) -> Profile? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            lastError = "名称不能为空"
            return nil
        }

        let slug = slugify(trimmed)
        var id = slug
        var n = 2
        while config.profiles.contains(where: { $0.id == id }) {
            id = "\(slug)-\(n)"
            n += 1
        }

        let home = Paths.profileHome(id: id)
        do {
            try fm.createDirectory(at: home, withIntermediateDirectories: true)
            let profile = Profile(
                id: id,
                name: trimmed,
                homePath: home.path,
                createdAt: Date()
            )
            config.profiles.append(profile)
            if config.activeProfileID == nil {
                config.activeProfileID = profile.id
                try writeActiveEnv(for: profile)
                _ = ShellHook.ensureInstalled()
            }
            try saveConfig()
            refreshIdentities()
            statusMessage = "已创建「\(trimmed)」。打开终端后运行 grok login。"
            lastError = nil
            return profile
        } catch {
            lastError = "创建失败：\(error.localizedDescription)"
            return nil
        }
    }

    func openTerminal(for profile: Profile? = nil) {
        let target = profile ?? activeProfile
        guard let target else {
            lastError = "没有可用账号"
            return
        }
        let terminal = config.preferredTerminalApp
        do {
            try TerminalLauncher.open(profile: target, terminal: terminal)
            statusMessage = "已用 \(terminal.displayName) 打开：\(target.name)"
            lastError = nil
        } catch {
            lastError = "打开终端失败：\(error.localizedDescription)"
        }
    }

    func setPreferredTerminal(_ terminal: TerminalApp) {
        config.preferredTerminal = terminal.rawValue
        do {
            try saveConfig()
            objectWillChange.send()
            statusMessage = "默认终端已设为 \(terminal.displayName)"
            lastError = nil
        } catch {
            lastError = "保存设置失败：\(error.localizedDescription)"
        }
    }

    func copyLaunchCommand(for profile: Profile? = nil) {
        let target = profile ?? activeProfile
        guard let target else { return }
        let cmd = TerminalLauncher.launchCommand(profile: target)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(cmd, forType: .string)
        statusMessage = "已复制启动命令"
    }

    func setShowEmailInMenuBar(_ value: Bool) {
        config.showEmailInMenuBar = value
        do {
            try saveConfig()
            objectWillChange.send()
        } catch {
            lastError = "保存设置失败：\(error.localizedDescription)"
        }
    }

    // MARK: - Private

    private func ensureDirectories() {
        try? fm.createDirectory(at: Paths.profilesRoot, withIntermediateDirectories: true)
    }

    private func loadConfig() -> AppConfig {
        guard fm.fileExists(atPath: Paths.configFile.path) else {
            return .empty
        }
        do {
            let data = try Data(contentsOf: Paths.configFile)
            var cfg = try decoder.decode(AppConfig.self, from: data)
            // Normalize home paths that may use ~
            cfg.profiles = cfg.profiles.map { p in
                var copy = p
                copy.homePath = (p.homePath as NSString).expandingTildeInPath
                return copy
            }
            return cfg
        } catch {
            lastError = "读取配置失败：\(error.localizedDescription)"
            return .empty
        }
    }

    private func saveConfig() throws {
        ensureDirectories()
        let data = try encoder.encode(config)
        try data.write(to: Paths.configFile, options: .atomic)
    }

    private func writeActiveEnv(for profile: Profile) throws {
        ensureDirectories()
        let homePath = profile.homeURL.path
        let content = """
        # Generated by GrokSwitch — do not edit by hand
        export GROK_HOME="\(homePath)"

        """
        try content.write(to: Paths.activeEnvFile, atomically: true, encoding: .utf8)
    }

    private func bootstrapIfNeeded() {
        ensureDirectories()
    }

    /// First-run: import current ~/.grok state into a "default" profile if auth exists.
    private func seedDefaultProfileFromExistingGrokHome() {
        let source = Paths.defaultGrokHome
        let auth = source.appendingPathComponent("auth.json")
        guard fm.fileExists(atPath: auth.path) else {
            // Create an empty default profile so UI isn't blank
            let home = Paths.profileHome(id: "default")
            try? fm.createDirectory(at: home, withIntermediateDirectories: true)
            let profile = Profile(
                id: "default",
                name: "默认",
                homePath: home.path,
                createdAt: Date()
            )
            config = AppConfig(
                version: AppConfig.currentVersion,
                activeProfileID: profile.id,
                profiles: [profile],
                showEmailInMenuBar: true,
                preferredTerminal: TerminalApp.terminal.rawValue
            )
            try? saveConfig()
            try? writeActiveEnv(for: profile)
            _ = ShellHook.ensureInstalled()
            return
        }

        let dest = Paths.profileHome(id: "default")
        do {
            if !fm.fileExists(atPath: dest.path) {
                try fm.createDirectory(at: dest, withIntermediateDirectories: true)
            }
            // Copy identity + settings; leave binary install at ~/.grok alone.
            let filesToCopy = [
                "auth.json",
                "config.toml",
                "trusted_folders.toml",
                "models_cache.json",
            ]
            for name in filesToCopy {
                let from = source.appendingPathComponent(name)
                let to = dest.appendingPathComponent(name)
                guard fm.fileExists(atPath: from.path) else { continue }
                if fm.fileExists(atPath: to.path) {
                    try fm.removeItem(at: to)
                }
                try fm.copyItem(at: from, to: to)
            }

            // Sessions can be huge; do not block first launch by copying them.
            // Users can still open historical sessions from the original ~/.grok
            // if needed. New sessions will live under this profile home.

            let profile = Profile(
                id: "default",
                name: "默认",
                homePath: dest.path,
                createdAt: Date()
            )
            config = AppConfig(
                version: AppConfig.currentVersion,
                activeProfileID: profile.id,
                profiles: [profile],
                showEmailInMenuBar: true,
                preferredTerminal: TerminalApp.terminal.rawValue
            )
            try saveConfig()
            try writeActiveEnv(for: profile)
            _ = ShellHook.ensureInstalled()
            statusMessage = "已从 ~/.grok 导入默认账号"
        } catch {
            lastError = "导入默认账号失败：\(error.localizedDescription)"
        }
    }

    private func slugify(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = name.lowercased().unicodeScalars.map { scalar -> Character in
            if allowed.contains(scalar) {
                return Character(scalar)
            }
            return "-"
        }
        var slug = String(scalars)
        while slug.contains("--") {
            slug = slug.replacingOccurrences(of: "--", with: "-")
        }
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if slug.isEmpty { slug = "profile" }
        return slug
    }
}

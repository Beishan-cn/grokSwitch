import AppKit
import Combine
import Foundation

@MainActor
final class ProfileStore: ObservableObject {
    @Published private(set) var config: AppConfig
    @Published private(set) var identities: [String: AccountIdentity] = [:]
    @Published private(set) var usages: [String: ProfileUsage] = [:]
    @Published private(set) var lastError: String?
    @Published private(set) var statusMessage: String?
    @Published private(set) var isRefreshingUsage = false

    /// When true, config file was unreadable; refuse writes that would overwrite it.
    private var configWriteBlocked = false

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

    /// Background refresh interval for credit usage.
    private static let usageRefreshInterval: TimeInterval = 10 * 60
    /// Treat a successful fetch as fresh for this long (skip re-fetch unless forced).
    private static let usageFreshness: TimeInterval = 5 * 60

    private var usageRefreshTask: Task<Void, Never>?
    private var usageRefreshGeneration: UInt64 = 0
    private var usageTimer: Timer?

    private enum ConfigLoadResult {
        case missing
        case loaded(AppConfig)
        case unreadable(Error)
    }

    init() {
        self.config = .empty
        bootstrapIfNeeded()
        reload()
        startUsageTimer()
    }

    deinit {
        usageTimer?.invalidate()
        usageRefreshTask?.cancel()
    }

    var activeProfile: Profile? {
        guard let id = config.activeProfileID else { return config.profiles.first }
        return config.profiles.first(where: { $0.id == id }) ?? config.profiles.first
    }

    /// Usage snapshot for the currently active profile (menu bar icon/title).
    var activeUsage: ProfileUsage? {
        guard let id = activeProfile?.id else { return nil }
        return usages[id]
    }

    var menuBarTitle: String {
        // Menu bar: brand icon + remaining only. Account name stays inside the dropdown.
        guard let profile = activeProfile else { return "" }

        if config.showUsageInMenuBar,
           let usage = usages[profile.id],
           let label = usage.remainingLabel,
           usage.status == .ready || usage.status == .loading || usage.status == .expired
        {
            return label
        }

        // No usage yet / disabled: keep the bar compact (icon-only when empty).
        if config.showEmailInMenuBar {
            return identities[profile.id]?.shortLabel ?? profile.name
        }
        return ""
    }

    /// Set a status line; optionally clear lastError.
    func noteStatus(_ message: String?, clearError: Bool = true) {
        statusMessage = message
        if clearError {
            lastError = nil
        }
    }

    func reload() {
        ensureDirectories()
        applySecurePermissionsBestEffort()

        switch loadConfig() {
        case .missing:
            configWriteBlocked = false
            config = .empty
            seedDefaultProfileFromExistingGrokHome()
        case let .loaded(cfg):
            configWriteBlocked = false
            var fixed = sanitizeLoadedConfig(cfg)
            // Heal dangling activeProfileID.
            if let active = fixed.activeProfileID,
               !fixed.profiles.contains(where: { $0.id == active })
            {
                fixed.activeProfileID = fixed.profiles.first?.id
                if let healed = try? commitConfigReturning(fixed) {
                    fixed = healed
                }
            }
            config = fixed
        case let .unreadable(error):
            configWriteBlocked = true
            // Keep in-memory empty/previous; never seed-overwrite a corrupt file.
            lastError = "读取配置失败：\(error.localizedDescription)。已保留原文件，未覆盖。请修复或删除 ~/.grokswitch/config.json 后点「刷新」。"
            statusMessage = nil
            refreshIdentities()
            return
        }

        refreshIdentities()
        if let active = activeProfile {
            do {
                try writeActiveEnv(for: active)
            } catch {
                lastError = "写入 active.env 失败：\(error.localizedDescription)"
            }
            reportHookResult(ShellHook.ensureInstalled())
        }
        refreshUsage(force: false)
    }

    func refreshIdentities() {
        var map: [String: AccountIdentity] = [:]
        for profile in config.profiles {
            map[profile.id] = AuthReader.identity(at: profile.authURL)
        }
        identities = map
    }

    /// Refresh Grok credit usage for every profile (parallel).
    /// - Parameter force: ignore freshness cache and re-fetch everything.
    func refreshUsage(force: Bool = true) {
        usageRefreshTask?.cancel()
        usageRefreshGeneration &+= 1
        let generation = usageRefreshGeneration
        usageRefreshTask = Task { [weak self] in
            await self?.performUsageRefresh(force: force, generation: generation)
        }
    }

    @discardableResult
    func switchTo(profileID: String) -> Bool {
        guard !configWriteBlocked else {
            lastError = "配置文件损坏，无法切换账号。请先修复 config.json。"
            return false
        }
        guard let profile = config.profiles.first(where: { $0.id == profileID }) else {
            lastError = "找不到账号配置"
            return false
        }
        guard Paths.isManagedProfileHome(profile.homePath) else {
            lastError = "账号路径非法，已拒绝切换"
            return false
        }

        var draft = config
        draft.activeProfileID = profile.id
        do {
            try commitConfig(draft)
            config = draft
            do {
                try writeActiveEnv(for: profile)
                lastError = nil
            } catch {
                lastError = "已切换账号配置，但 active.env 写入失败：\(error.localizedDescription)"
            }
            reportHookResult(ShellHook.ensureInstalled(), preferExistingError: lastError != nil)
            refreshIdentities()
            refreshUsage(force: false)
            statusMessage = "已切换到 \(profile.name)。新开终端生效。"
            return true
        } catch {
            lastError = "切换失败：\(error.localizedDescription)"
            return false
        }
    }

    /// Create a profile. When `activate` is true, set it active in the same commit.
    @discardableResult
    func addProfile(name: String, activate: Bool = false) -> Profile? {
        guard !configWriteBlocked else {
            lastError = "配置文件损坏，无法添加账号。"
            return nil
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            lastError = "名称不能为空"
            return nil
        }

        let slug = slugify(trimmed)
        var id = slug
        var n = 2
        while config.profiles.contains(where: { $0.id == id })
            || fm.fileExists(atPath: Paths.profileHome(id: id).path)
        {
            id = "\(slug)-\(n)"
            n += 1
        }

        let home = Paths.profileHome(id: id)
        var createdDirectory = false
        do {
            if !fm.fileExists(atPath: home.path) {
                try fm.createDirectory(at: home, withIntermediateDirectories: true)
                createdDirectory = true
                Paths.ensureSecureDirectory(home)
            }
            let profile = Profile(
                id: id,
                name: trimmed,
                homePath: home.path,
                createdAt: Date()
            )
            var draft = config
            draft.profiles.append(profile)
            let shouldActivate = activate || draft.activeProfileID == nil
            if shouldActivate {
                draft.activeProfileID = profile.id
            }

            try commitConfig(draft)
            config = draft

            if shouldActivate {
                do {
                    try writeActiveEnv(for: profile)
                } catch {
                    lastError = "已创建账号，但 active.env 写入失败：\(error.localizedDescription)"
                }
                reportHookResult(ShellHook.ensureInstalled(), preferExistingError: lastError != nil)
            }

            refreshIdentities()
            usages[profile.id] = .notLoggedIn()
            if lastError == nil {
                statusMessage = "已创建「\(trimmed)」。打开终端后运行 grok login。"
                lastError = nil
            } else {
                statusMessage = "已创建「\(trimmed)」"
            }
            return profile
        } catch {
            if createdDirectory {
                try? fm.removeItem(at: home)
            }
            lastError = "创建失败：\(error.localizedDescription)"
            return nil
        }
    }

    @discardableResult
    func renameProfile(id: String, name: String) -> Bool {
        guard !configWriteBlocked else {
            lastError = "配置文件损坏，无法重命名。"
            return false
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            lastError = "名称不能为空"
            return false
        }
        guard let index = config.profiles.firstIndex(where: { $0.id == id }) else {
            lastError = "找不到账号配置"
            return false
        }
        if config.profiles[index].name == trimmed {
            lastError = nil
            return true
        }
        var draft = config
        draft.profiles[index].name = trimmed
        do {
            try commitConfig(draft)
            config = draft
            statusMessage = "已重命名为「\(trimmed)」"
            lastError = nil
            return true
        } catch {
            lastError = "重命名失败：\(error.localizedDescription)"
            return false
        }
    }

    /// Remove a profile from config and delete its GROK_HOME directory.
    /// Refuses when it is the only remaining account.
    /// Returns true if the registry no longer contains the profile (disk config committed).
    @discardableResult
    func deleteProfile(id: String) -> Bool {
        guard !configWriteBlocked else {
            lastError = "配置文件损坏，无法删除账号。"
            return false
        }
        guard config.profiles.count > 1 else {
            lastError = "至少保留一个账号"
            return false
        }
        guard let index = config.profiles.firstIndex(where: { $0.id == id }) else {
            lastError = "找不到账号配置"
            return false
        }

        // Cancel in-flight usage so ghost writes cannot repopulate deleted keys.
        usageRefreshTask?.cancel()
        usageRefreshGeneration &+= 1

        let profile = config.profiles[index]
        let wasActive = config.activeProfileID == profile.id
        let homePath = profile.homePath
        let canDeleteHome = Paths.isManagedProfileHome(homePath)

        var draft = config
        draft.profiles.remove(at: index)
        if wasActive {
            draft.activeProfileID = draft.profiles.first?.id
        }

        do {
            try commitConfig(draft)
        } catch {
            lastError = "删除失败：\(error.localizedDescription)"
            return false
        }

        // Config is source of truth after successful save — do not roll memory back.
        config = draft
        identities.removeValue(forKey: id)
        usages.removeValue(forKey: id)
        // Drop any other orphan usage keys.
        let validIDs = Set(config.profiles.map(\.id))
        usages = usages.filter { validIDs.contains($0.key) }
        identities = identities.filter { validIDs.contains($0.key) }

        var warnings: [String] = []

        if wasActive, let fallback = activeProfile {
            do {
                try writeActiveEnv(for: fallback)
            } catch {
                warnings.append("active.env 写入失败：\(error.localizedDescription)")
            }
            if case let .failed(message) = ShellHook.ensureInstalled() {
                warnings.append(message)
            }
        }

        if canDeleteHome, fm.fileExists(atPath: profile.homeURL.path) {
            do {
                try fm.removeItem(at: profile.homeURL)
            } catch {
                warnings.append("本地目录删除失败：\(error.localizedDescription)")
            }
        } else if !canDeleteHome {
            warnings.append("homePath 不在托管目录内，已从列表移除但未删除磁盘目录")
        }

        if warnings.isEmpty {
            if wasActive, let fallback = activeProfile {
                statusMessage = "已删除「\(profile.name)」，已切换到 \(fallback.name)"
            } else {
                statusMessage = "已删除「\(profile.name)」"
            }
            lastError = nil
        } else {
            statusMessage = "已删除「\(profile.name)」"
            lastError = "账号已从配置移除，但：" + warnings.joined(separator: "；")
        }

        refreshUsage(force: false)
        return true
    }

    func openTerminal(for profile: Profile? = nil) {
        let target = profile ?? activeProfile
        guard let target else {
            lastError = "没有可用账号"
            return
        }
        guard Paths.isManagedProfileHome(target.homePath) else {
            lastError = "账号路径非法，已拒绝打开终端"
            return
        }
        let terminal = config.preferredTerminalApp
        let project = config.preferredProjectPath
        do {
            let outcome = try TerminalLauncher.open(
                profile: target,
                terminal: terminal,
                projectPath: project
            )
            applyLaunchOutcome(outcome, profile: target, terminal: terminal, projectPath: project)
        } catch {
            // Keep prior errors (e.g. env write from add/switch) and append launch failure.
            lastError = mergeError(
                existing: lastError,
                additional: "打开终端失败：\(error.localizedDescription)"
            )
        }
    }

    func setPreferredTerminal(_ terminal: TerminalApp) {
        var draft = config
        draft.preferredTerminal = terminal.rawValue
        do {
            try commitConfig(draft)
            config = draft
            statusMessage = "默认终端已设为 \(terminal.displayName)"
            lastError = nil
        } catch {
            lastError = "保存设置失败：\(error.localizedDescription)"
        }
    }

    /// Set preferred project path for `grok --cwd`. Pass `nil` to clear (no repo).
    func setPreferredProjectPath(_ path: String?) {
        let normalized: String?
        if let path, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            normalized = (path as NSString).expandingTildeInPath
        } else {
            normalized = nil
        }
        if let normalized {
            var isDir: ObjCBool = false
            if !fm.fileExists(atPath: normalized, isDirectory: &isDir) || !isDir.boolValue {
                lastError = "项目路径不存在或不是文件夹"
                return
            }
        }
        var draft = config
        draft.preferredProjectPath = normalized
        do {
            try commitConfig(draft)
            config = draft
            if let path = normalized {
                let name = (path as NSString).lastPathComponent
                statusMessage = "默认项目已设为 \(name)"
            } else {
                statusMessage = "已清除默认项目"
            }
            lastError = nil
        } catch {
            lastError = "保存设置失败：\(error.localizedDescription)"
        }
    }

    /// Set the parent directory whose subfolders are listed as project candidates.
    /// Pass `nil` to fall back to auto-detecting common names under `~`.
    func setProjectsScanRoot(_ path: String?) {
        let normalized: String?
        if let path, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            normalized = (path as NSString).expandingTildeInPath
        } else {
            normalized = nil
        }
        if let normalized {
            var isDir: ObjCBool = false
            if !fm.fileExists(atPath: normalized, isDirectory: &isDir) || !isDir.boolValue {
                lastError = "扫描目录不存在或不是文件夹"
                return
            }
        }
        var draft = config
        draft.projectsScanRoot = normalized
        do {
            try commitConfig(draft)
            config = draft
            if let path = normalized {
                statusMessage = "项目扫描目录已设为 \(ProjectScanner.displayPath(for: URL(fileURLWithPath: path)))"
            } else {
                let auto = ProjectScanner.displayRoot(configured: nil)
                statusMessage = "已恢复自动检测扫描目录（当前：\(auto)）"
            }
            lastError = nil
        } catch {
            lastError = "保存设置失败：\(error.localizedDescription)"
        }
    }

    func setShowEmailInMenuBar(_ value: Bool) {
        var draft = config
        draft.showEmailInMenuBar = value
        do {
            try commitConfig(draft)
            config = draft
            lastError = nil
        } catch {
            lastError = "保存设置失败：\(error.localizedDescription)"
        }
    }

    func setShowUsageInMenuBar(_ value: Bool) {
        var draft = config
        draft.showUsageInMenuBar = value
        do {
            try commitConfig(draft)
            config = draft
            lastError = nil
        } catch {
            lastError = "保存设置失败：\(error.localizedDescription)"
        }
    }

    // MARK: - Usage refresh

    private func startUsageTimer() {
        usageTimer?.invalidate()
        let timer = Timer(timeInterval: Self.usageRefreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshUsage(force: true)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        usageTimer = timer
    }

    private func performUsageRefresh(force: Bool, generation: UInt64) async {
        let profiles = config.profiles
        guard !profiles.isEmpty else { return }
        guard generation == usageRefreshGeneration else { return }

        isRefreshingUsage = true
        defer {
            if generation == usageRefreshGeneration {
                isRefreshingUsage = false
            }
        }

        for profile in profiles {
            guard generation == usageRefreshGeneration else { return }
            let current = usages[profile.id]
            let identity = identities[profile.id] ?? AuthReader.identity(at: profile.authURL)
            // Broken auth.json → failed (not “未登录”).
            if let issue = identity.authIssue {
                switch issue {
                case .notFound:
                    usages[profile.id] = .notLoggedIn()
                case .unreadable, .missingTokens:
                    usages[profile.id] = .failed(issue.usageFailureMessage)
                }
                continue
            }
            if !identity.isLoggedIn {
                usages[profile.id] = .notLoggedIn()
                continue
            }
            if identity.isExpired {
                usages[profile.id] = .expired()
                continue
            }
            if !force,
               let current,
               current.status == .ready,
               let fetchedAt = current.fetchedAt,
               Date().timeIntervalSince(fetchedAt) < Self.usageFreshness
            {
                continue
            }
            if current?.status != .ready {
                usages[profile.id] = .loading()
            }
        }

        await withTaskGroup(of: (String, ProfileUsage).self) { group in
            for profile in profiles {
                let identity = identities[profile.id] ?? AuthReader.identity(at: profile.authURL)
                // Skip fetch when auth file is missing/broken or session expired.
                if identity.authIssue != nil { continue }
                guard identity.isLoggedIn, !identity.isExpired else { continue }

                if !force,
                   let current = usages[profile.id],
                   current.status == .ready,
                   let fetchedAt = current.fetchedAt,
                   Date().timeIntervalSince(fetchedAt) < Self.usageFreshness
                {
                    continue
                }

                let authURL = profile.authURL
                let profileID = profile.id
                group.addTask {
                    let result = await UsageFetcher.fetch(authURL: authURL)
                    let usage: ProfileUsage
                    switch result {
                    case let .success(raw):
                        usage = .ready(usedPercent: raw.usedPercent, resetsAt: raw.resetsAt)
                    case let .failure(error):
                        usage = ProfileUsage.fromFetchError(error)
                    }
                    return (profileID, usage)
                }
            }

            for await (profileID, usage) in group {
                guard generation == usageRefreshGeneration, !Task.isCancelled else { break }
                guard config.profiles.contains(where: { $0.id == profileID }) else { continue }
                usages[profileID] = usage
            }
        }

        if generation == usageRefreshGeneration {
            objectWillChange.send()
        }
    }

    // MARK: - Private: config load / commit

    private func ensureDirectories() {
        Paths.ensureSecureDirectory(Paths.grokSwitchRoot)
        Paths.ensureSecureDirectory(Paths.profilesRoot)
    }

    private func applySecurePermissionsBestEffort() {
        Paths.ensureSecureDirectory(Paths.grokSwitchRoot)
        Paths.ensureSecureDirectory(Paths.profilesRoot)
        Paths.ensureSecureFile(Paths.configFile)
        Paths.ensureSecureFile(Paths.activeEnvFile)
        for profile in config.profiles {
            Paths.ensureSecureDirectory(profile.homeURL)
            Paths.ensureSecureFile(profile.authURL)
        }
    }

    private func loadConfig() -> ConfigLoadResult {
        guard fm.fileExists(atPath: Paths.configFile.path) else {
            return .missing
        }
        do {
            let data = try Data(contentsOf: Paths.configFile)
            var cfg = try decoder.decode(AppConfig.self, from: data)
            cfg.profiles = cfg.profiles.map { p in
                var copy = p
                copy.homePath = (p.homePath as NSString).expandingTildeInPath
                return copy
            }
            return .loaded(cfg)
        } catch {
            return .unreadable(error)
        }
    }

    /// Drop profiles whose homePath is outside the managed root; repair active id.
    private func sanitizeLoadedConfig(_ cfg: AppConfig) -> AppConfig {
        var next = cfg
        let before = next.profiles.count
        next.profiles = next.profiles.filter { Paths.isManagedProfileHome($0.homePath) }
        if next.profiles.count < before {
            lastError = "配置中存在非法 homePath，已忽略 \(before - next.profiles.count) 个账号"
        }
        if let active = next.activeProfileID,
           !next.profiles.contains(where: { $0.id == active })
        {
            next.activeProfileID = next.profiles.first?.id
        }
        return next
    }

    private func commitConfig(_ cfg: AppConfig) throws {
        _ = try commitConfigReturning(cfg)
    }

    @discardableResult
    private func commitConfigReturning(_ cfg: AppConfig) throws -> AppConfig {
        guard !configWriteBlocked else {
            throw NSError(
                domain: "GrokSwitch",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "配置文件损坏，拒绝写入以免覆盖"]
            )
        }
        ensureDirectories()
        let data = try encoder.encode(cfg)
        try data.write(to: Paths.configFile, options: .atomic)
        Paths.ensureSecureFile(Paths.configFile)
        return cfg
    }

    private func writeActiveEnv(for profile: Profile) throws {
        ensureDirectories()
        guard Paths.isManagedProfileHome(profile.homePath) else {
            throw NSError(
                domain: "GrokSwitch",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "homePath 不在托管 profiles 目录内"]
            )
        }
        let homePath = profile.homeURL.standardizedFileURL.path
        let content = """
        # Generated by GrokSwitch — do not edit by hand
        export GROK_HOME=\(ShellQuoting.shellSingleQuoted(homePath))

        """
        try content.write(to: Paths.activeEnvFile, atomically: true, encoding: .utf8)
        Paths.ensureSecureFile(Paths.activeEnvFile)
    }

    private func bootstrapIfNeeded() {
        ensureDirectories()
    }

    private func reportHookResult(_ result: ShellHook.InstallResult, preferExistingError: Bool = false) {
        if case let .failed(message) = result {
            if !preferExistingError || lastError == nil {
                lastError = message
            }
        }
    }

    private func applyLaunchOutcome(
        _ outcome: TerminalLauncher.LaunchOutcome,
        profile: Profile,
        terminal: TerminalApp,
        projectPath: String?
    ) {
        let projectName: String? = {
            guard let projectPath, !projectPath.isEmpty else { return nil }
            return (projectPath as NSString).lastPathComponent
        }()
        let successStatus: String = {
            if let projectName {
                return "已用 \(terminal.displayName) 打开：\(profile.name) · \(projectName)"
            }
            return "已用 \(terminal.displayName) 打开：\(profile.name)"
        }()
        switch outcome {
        case .launched:
            statusMessage = successStatus
            // Preserve prior lastError (e.g. active.env partial failure from confirmAdd / switch).
        case let .launchedWithWarning(warning):
            statusMessage = successStatus
            lastError = mergeError(existing: lastError, additional: warning)
        case let .bestEffort(message):
            statusMessage = message
            // Preserve prior lastError; best-effort is not a full clean success.
        }
    }

    /// Append a secondary warning without dropping an earlier failure message.
    private func mergeError(existing: String?, additional: String) -> String {
        guard let existing, !existing.isEmpty else { return additional }
        if existing.contains(additional) { return existing }
        return "\(existing)；\(additional)"
    }

    /// First-run: import current ~/.grok state into a "default" profile if auth exists.
    private func seedDefaultProfileFromExistingGrokHome() {
        let source = Paths.defaultGrokHome
        let auth = source.appendingPathComponent("auth.json")
        guard fm.fileExists(atPath: auth.path) else {
            let home = Paths.profileHome(id: "default")
            try? fm.createDirectory(at: home, withIntermediateDirectories: true)
            Paths.ensureSecureDirectory(home)
            let profile = Profile(
                id: "default",
                name: "默认",
                homePath: home.path,
                createdAt: Date()
            )
            let seeded = AppConfig(
                version: AppConfig.currentVersion,
                activeProfileID: profile.id,
                profiles: [profile],
                showEmailInMenuBar: false,
                showUsageInMenuBar: true,
                preferredTerminal: TerminalApp.terminal.rawValue
            )
            do {
                try commitConfig(seeded)
                config = seeded
                try writeActiveEnv(for: profile)
                reportHookResult(ShellHook.ensureInstalled())
            } catch {
                lastError = "创建默认账号失败：\(error.localizedDescription)"
            }
            return
        }

        let dest = Paths.profileHome(id: "default")
        do {
            if !fm.fileExists(atPath: dest.path) {
                try fm.createDirectory(at: dest, withIntermediateDirectories: true)
            }
            Paths.ensureSecureDirectory(dest)
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
                if name == "auth.json" {
                    Paths.ensureSecureFile(to)
                }
            }

            let profile = Profile(
                id: "default",
                name: "默认",
                homePath: dest.path,
                createdAt: Date()
            )
            let seeded = AppConfig(
                version: AppConfig.currentVersion,
                activeProfileID: profile.id,
                profiles: [profile],
                showEmailInMenuBar: false,
                showUsageInMenuBar: true,
                preferredTerminal: TerminalApp.terminal.rawValue
            )
            try commitConfig(seeded)
            config = seeded
            try writeActiveEnv(for: profile)
            reportHookResult(ShellHook.ensureInstalled())
            statusMessage = "已从 ~/.grok 导入默认账号"
            lastError = nil
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

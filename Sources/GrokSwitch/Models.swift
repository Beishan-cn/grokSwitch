import Foundation

struct Profile: Identifiable, Codable, Equatable, Hashable {
    var id: String
    var name: String
    var homePath: String
    var createdAt: Date

    var homeURL: URL {
        URL(fileURLWithPath: (homePath as NSString).expandingTildeInPath)
    }

    var authURL: URL {
        homeURL.appendingPathComponent("auth.json")
    }
}

struct AppConfig: Codable, Equatable {
    var version: Int
    var activeProfileID: String?
    var profiles: [Profile]
    var showEmailInMenuBar: Bool
    /// Show remaining credit % next to the active account in the menu bar title.
    var showUsageInMenuBar: Bool
    /// Preferred terminal app id (`TerminalApp.rawValue`). Defaults to Terminal.app.
    var preferredTerminal: String
    /// Absolute path of the preferred project directory to open Grok in (`--cwd`).
    /// Empty / nil means no project (open without a repo).
    var preferredProjectPath: String?
    /// Absolute path of the directory whose immediate subfolders are listed as project candidates.
    /// Empty / nil means auto-detect a common folder under `~` (Projects, Developer, Code, …).
    var projectsScanRoot: String?
    /// Recently used project absolute paths, most recent first. Used to sort project pickers.
    var recentProjectPaths: [String]

    static let currentVersion = 1
    /// Soft cap so config stays small and the picker stays usable.
    static let maxRecentProjects = 30

    static var empty: AppConfig {
        AppConfig(
            version: currentVersion,
            activeProfileID: nil,
            profiles: [],
            showEmailInMenuBar: false,
            showUsageInMenuBar: true,
            preferredTerminal: TerminalApp.terminal.rawValue,
            preferredProjectPath: nil,
            projectsScanRoot: nil,
            recentProjectPaths: []
        )
    }

    var preferredTerminalApp: TerminalApp {
        TerminalApp(rawValue: preferredTerminal) ?? .terminal
    }

    /// Display name for the preferred project, or a placeholder when unset.
    var preferredProjectDisplayName: String {
        guard let path = preferredProjectPath, !path.isEmpty else {
            return "未选择"
        }
        return (path as NSString).lastPathComponent
    }

    enum CodingKeys: String, CodingKey {
        case version, activeProfileID, profiles, showEmailInMenuBar, showUsageInMenuBar
        case preferredTerminal, preferredProjectPath, projectsScanRoot, recentProjectPaths
    }

    init(
        version: Int,
        activeProfileID: String?,
        profiles: [Profile],
        showEmailInMenuBar: Bool,
        showUsageInMenuBar: Bool = true,
        preferredTerminal: String = TerminalApp.terminal.rawValue,
        preferredProjectPath: String? = nil,
        projectsScanRoot: String? = nil,
        recentProjectPaths: [String] = []
    ) {
        self.version = version
        self.activeProfileID = activeProfileID
        self.profiles = profiles
        self.showEmailInMenuBar = showEmailInMenuBar
        self.showUsageInMenuBar = showUsageInMenuBar
        self.preferredTerminal = preferredTerminal
        self.preferredProjectPath = preferredProjectPath
        self.projectsScanRoot = projectsScanRoot
        self.recentProjectPaths = recentProjectPaths
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        activeProfileID = try c.decodeIfPresent(String.self, forKey: .activeProfileID)
        profiles = try c.decode([Profile].self, forKey: .profiles)
        // Match .empty / seed defaults: menu bar stays compact unless user opts in.
        showEmailInMenuBar = try c.decodeIfPresent(Bool.self, forKey: .showEmailInMenuBar) ?? false
        showUsageInMenuBar = try c.decodeIfPresent(Bool.self, forKey: .showUsageInMenuBar) ?? true
        preferredTerminal = try c.decodeIfPresent(String.self, forKey: .preferredTerminal)
            ?? TerminalApp.terminal.rawValue
        preferredProjectPath = try c.decodeIfPresent(String.self, forKey: .preferredProjectPath)
        projectsScanRoot = try c.decodeIfPresent(String.self, forKey: .projectsScanRoot)
        recentProjectPaths = try c.decodeIfPresent([String].self, forKey: .recentProjectPaths) ?? []
        // Migrate older configs: treat the saved default project as most-recently used.
        if recentProjectPaths.isEmpty,
           let preferred = preferredProjectPath,
           !preferred.isEmpty
        {
            recentProjectPaths = [preferred]
        }
    }
}

/// A project folder under the configured (or auto-detected) scan root.
struct ProjectFolder: Identifiable, Equatable, Hashable {
    var id: String { path }
    var name: String
    var path: String
}

enum ProjectScanner {
    /// Common parent-folder names under `~` (first existing wins when auto-detecting).
    /// Covers typical layouts across languages/locales without hardcoding one user's path.
    static let commonRootNames: [String] = [
        "Projects",
        "Developer",
        "Development",
        "Code",
        "Repos",
        "repos",
        "workspace",
        "Workspace",
        "src",
        "dev",
        "Sites",
        "项目",
        "代码",
    ]

    /// Resolve the directory to scan: configured path if valid, else auto-detect.
    static func resolveRoot(configured: String?) -> URL? {
        if let configured,
           let url = existingDirectory(expanding: configured)
        {
            return url
        }
        return autoDetectedRoot()
    }

    /// First existing common project parent under the home directory.
    static func autoDetectedRoot() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        for name in commonRootNames {
            let url = home.appendingPathComponent(name)
            if isDirectory(url) {
                return url
            }
        }
        return nil
    }

    /// Short display path (`~/Projects`, full path if outside home).
    static func displayPath(for url: URL?) -> String {
        guard let url else { return "未找到" }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = url.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    static func displayRoot(configured: String?) -> String {
        displayPath(for: resolveRoot(configured: configured))
    }

    /// Whether the scan root comes from user config (vs auto-detect).
    static func isUsingConfiguredRoot(_ configured: String?) -> Bool {
        guard let configured else { return false }
        return existingDirectory(expanding: configured) != nil
    }

    /// Soft cap so huge scan roots do not freeze the menu bar on the main thread.
    static let maxListedProjects = 400

    /// List immediate subdirectories under the resolved scan root (non-hidden, folders only).
    /// - Parameter recentPaths: absolute paths most-recent-first; those still under the scan root
    ///   appear first (in that order), then remaining folders A–Z by name.
    static func scan(configuredRoot: String? = nil, recentPaths: [String] = []) -> [ProjectFolder] {
        guard let root = resolveRoot(configured: configuredRoot) else {
            return []
        }
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isHiddenKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var folders: [ProjectFolder] = []
        for url in contents {
            guard isDirectory(url) else { continue }
            let name = url.lastPathComponent
            if name.hasPrefix(".") { continue }
            // Skip .app bundles as project candidates.
            if name.hasSuffix(".app") { continue }
            folders.append(ProjectFolder(name: name, path: url.path))
            if folders.count >= maxListedProjects { break }
        }
        return sort(folders, recentPaths: recentPaths)
    }

    /// Recent-first, then case-insensitive name A–Z.
    static func sort(_ folders: [ProjectFolder], recentPaths: [String]) -> [ProjectFolder] {
        var recentIndex: [String: Int] = [:]
        for (index, path) in recentPaths.enumerated() {
            let key = normalizePath(path)
            // Keep first occurrence (most recent); skip later duplicates.
            if recentIndex[key] == nil {
                recentIndex[key] = index
            }
        }
        return folders.sorted { lhs, rhs in
            let li = recentIndex[normalizePath(lhs.path)]
            let ri = recentIndex[normalizePath(rhs.path)]
            switch (li, ri) {
            case let (l?, r?):
                return l < r
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        }
    }

    /// Expand `~` and drop trailing slashes so stored vs scanned paths match.
    static func normalizePath(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        if expanded == "/" { return expanded }
        return expanded.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    // MARK: - Helpers

    private static func existingDirectory(expanding raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let path = (trimmed as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: path)
        return isDirectory(url) ? url : nil
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            return false
        }
        return isDir.boolValue
    }
}

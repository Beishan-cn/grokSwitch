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

    static let currentVersion = 1

    static var empty: AppConfig {
        AppConfig(
            version: currentVersion,
            activeProfileID: nil,
            profiles: [],
            showEmailInMenuBar: false,
            showUsageInMenuBar: true,
            preferredTerminal: TerminalApp.terminal.rawValue,
            preferredProjectPath: nil
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
        case preferredTerminal, preferredProjectPath
    }

    init(
        version: Int,
        activeProfileID: String?,
        profiles: [Profile],
        showEmailInMenuBar: Bool,
        showUsageInMenuBar: Bool = true,
        preferredTerminal: String = TerminalApp.terminal.rawValue,
        preferredProjectPath: String? = nil
    ) {
        self.version = version
        self.activeProfileID = activeProfileID
        self.profiles = profiles
        self.showEmailInMenuBar = showEmailInMenuBar
        self.showUsageInMenuBar = showUsageInMenuBar
        self.preferredTerminal = preferredTerminal
        self.preferredProjectPath = preferredProjectPath
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        activeProfileID = try c.decodeIfPresent(String.self, forKey: .activeProfileID)
        profiles = try c.decode([Profile].self, forKey: .profiles)
        showEmailInMenuBar = try c.decodeIfPresent(Bool.self, forKey: .showEmailInMenuBar) ?? true
        showUsageInMenuBar = try c.decodeIfPresent(Bool.self, forKey: .showUsageInMenuBar) ?? true
        preferredTerminal = try c.decodeIfPresent(String.self, forKey: .preferredTerminal)
            ?? TerminalApp.terminal.rawValue
        preferredProjectPath = try c.decodeIfPresent(String.self, forKey: .preferredProjectPath)
    }
}

/// A project folder under ~/Projects (or the configured scan root).
struct ProjectFolder: Identifiable, Equatable, Hashable {
    var id: String { path }
    var name: String
    var path: String
}

enum ProjectScanner {
    /// Root directory to scan for project folders.
    static var projectsRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Projects")
    }

    /// List immediate subdirectories under the projects root (non-hidden, folders only).
    static func scan() -> [ProjectFolder] {
        let root = projectsRoot
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isHiddenKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var folders: [ProjectFolder] = []
        for url in contents {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
                continue
            }
            // Skip common non-project junk if any
            let name = url.lastPathComponent
            if name.hasPrefix(".") { continue }
            folders.append(ProjectFolder(name: name, path: url.path))
        }
        return folders.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }
}

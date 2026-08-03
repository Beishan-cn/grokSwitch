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
    /// Preferred terminal app id (`TerminalApp.rawValue`). Defaults to Terminal.app.
    var preferredTerminal: String

    static let currentVersion = 1

    static var empty: AppConfig {
        AppConfig(
            version: currentVersion,
            activeProfileID: nil,
            profiles: [],
            showEmailInMenuBar: true,
            preferredTerminal: TerminalApp.terminal.rawValue
        )
    }

    var preferredTerminalApp: TerminalApp {
        TerminalApp(rawValue: preferredTerminal) ?? .terminal
    }

    enum CodingKeys: String, CodingKey {
        case version, activeProfileID, profiles, showEmailInMenuBar, preferredTerminal
    }

    init(
        version: Int,
        activeProfileID: String?,
        profiles: [Profile],
        showEmailInMenuBar: Bool,
        preferredTerminal: String = TerminalApp.terminal.rawValue
    ) {
        self.version = version
        self.activeProfileID = activeProfileID
        self.profiles = profiles
        self.showEmailInMenuBar = showEmailInMenuBar
        self.preferredTerminal = preferredTerminal
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        activeProfileID = try c.decodeIfPresent(String.self, forKey: .activeProfileID)
        profiles = try c.decode([Profile].self, forKey: .profiles)
        showEmailInMenuBar = try c.decodeIfPresent(Bool.self, forKey: .showEmailInMenuBar) ?? true
        preferredTerminal = try c.decodeIfPresent(String.self, forKey: .preferredTerminal)
            ?? TerminalApp.terminal.rawValue
    }
}

struct AccountIdentity: Equatable {
    var email: String?
    var displayName: String?
    var userID: String?
    var isLoggedIn: Bool

    var shortLabel: String {
        if let email, !email.isEmpty {
            let local = email.split(separator: "@").first.map(String.init) ?? email
            return local
        }
        if let displayName, !displayName.isEmpty {
            return displayName
        }
        return "未登录"
    }

    var detailLabel: String {
        if let email, !email.isEmpty {
            if let displayName, !displayName.isEmpty {
                return "\(displayName) · \(email)"
            }
            return email
        }
        if let displayName, !displayName.isEmpty {
            return displayName
        }
        return "未登录（运行 grok login）"
    }
}

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

    static let currentVersion = 1

    static var empty: AppConfig {
        AppConfig(
            version: currentVersion,
            activeProfileID: nil,
            profiles: [],
            showEmailInMenuBar: true
        )
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

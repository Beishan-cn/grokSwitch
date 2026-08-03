import Foundation

/// Credentials + identity extracted from a profile's `auth.json`.
struct GrokCredentials: Equatable, Sendable {
    var accessToken: String
    var refreshToken: String?
    var email: String?
    var displayName: String?
    var userID: String?
    var teamID: String?
    var principalType: String?
    var authMode: String?
    var expiresAt: Date?
    var scope: String

    var isExpired: Bool {
        guard let expiresAt else { return false }
        // Small leeway so we don't fire a doomed request in the last few seconds.
        return Date() >= expiresAt.addingTimeInterval(-30)
    }

    var isTeamPrincipal: Bool {
        principalType?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare("team") == .orderedSame
    }

    var isLoggedIn: Bool {
        !accessToken.isEmpty
    }
}

struct AccountIdentity: Equatable {
    var email: String?
    var displayName: String?
    var userID: String?
    var isLoggedIn: Bool
    var isExpired: Bool
    var isTeamPrincipal: Bool

    init(
        email: String? = nil,
        displayName: String? = nil,
        userID: String? = nil,
        isLoggedIn: Bool = false,
        isExpired: Bool = false,
        isTeamPrincipal: Bool = false
    ) {
        self.email = email
        self.displayName = displayName
        self.userID = userID
        self.isLoggedIn = isLoggedIn
        self.isExpired = isExpired
        self.isTeamPrincipal = isTeamPrincipal
    }

    init(credentials: GrokCredentials) {
        self.email = credentials.email
        self.displayName = credentials.displayName
        self.userID = credentials.userID
        self.isLoggedIn = credentials.isLoggedIn
        self.isExpired = credentials.isExpired
        self.isTeamPrincipal = credentials.isTeamPrincipal
    }

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

enum AuthReader {
    enum Error: LocalizedError {
        case notFound
        case decodeFailed(String)
        case missingTokens

        var errorDescription: String? {
            switch self {
            case .notFound:
                return "auth.json 不存在"
            case let .decodeFailed(message):
                return "解析 auth.json 失败：\(message)"
            case .missingTokens:
                return "auth.json 中没有可用 token"
            }
        }
    }

    /// SuperGrok OIDC scope prefix used by `grok login`.
    static let oidcScopePrefix = "https://auth.x.ai::"
    /// Legacy session scope.
    static let legacySessionScope = "https://accounts.x.ai/sign-in"

    /// Read non-secret identity fields from a profile's auth.json.
    static func identity(at authURL: URL) -> AccountIdentity {
        do {
            let credentials = try credentials(at: authURL)
            return AccountIdentity(credentials: credentials)
        } catch {
            return AccountIdentity()
        }
    }

    /// Full credentials (including access token) for billing calls.
    static func credentials(at authURL: URL) throws -> GrokCredentials {
        guard FileManager.default.fileExists(atPath: authURL.path) else {
            throw Error.notFound
        }
        let data = try Data(contentsOf: authURL)
        return try parse(data: data)
    }

    static func parse(data: Data) throws -> GrokCredentials {
        let raw: Any
        do {
            raw = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw Error.decodeFailed(error.localizedDescription)
        }
        guard let root = raw as? [String: Any] else {
            throw Error.decodeFailed("根节点不是对象")
        }

        guard let (scope, entry) = selectPreferredEntry(in: root) else {
            throw Error.missingTokens
        }
        guard let key = entry["key"] as? String, !key.isEmpty else {
            throw Error.missingTokens
        }

        let first = (entry["first_name"] as? String)?.nilIfEmpty
        let last = (entry["last_name"] as? String)?.nilIfEmpty
        let nameParts = [first, last].compactMap { $0 }
        let displayName = nameParts.isEmpty ? nil : nameParts.joined(separator: "")

        return GrokCredentials(
            accessToken: key,
            refreshToken: (entry["refresh_token"] as? String)?.nilIfEmpty,
            email: (entry["email"] as? String)?.nilIfEmpty,
            displayName: displayName,
            userID: (entry["user_id"] as? String)?.nilIfEmpty
                ?? (entry["principal_id"] as? String)?.nilIfEmpty,
            teamID: (entry["team_id"] as? String)?.nilIfEmpty,
            principalType: (entry["principal_type"] as? String)?.nilIfEmpty,
            authMode: (entry["auth_mode"] as? String)?.nilIfEmpty,
            expiresAt: parseDate(entry["expires_at"]),
            scope: scope
        )
    }

    private static func selectPreferredEntry(in root: [String: Any]) -> (scope: String, entry: [String: Any])? {
        var oidcCandidate: (String, [String: Any])?
        var legacyCandidate: (String, [String: Any])?
        var otherCandidate: (String, [String: Any])?

        for (scope, value) in root {
            guard let entry = value as? [String: Any] else { continue }
            // Only accept entries that carry a usable bearer token.
            guard let key = entry["key"] as? String, !key.isEmpty else { continue }
            if scope.hasPrefix(oidcScopePrefix) {
                oidcCandidate = (scope, entry)
            } else if scope == legacySessionScope || scope.contains("/sign-in") {
                legacyCandidate = (scope, entry)
            } else if otherCandidate == nil {
                otherCandidate = (scope, entry)
            }
        }
        return oidcCandidate ?? legacyCandidate ?? otherCandidate
    }

    private static func parseDate(_ raw: Any?) -> Date? {
        guard let value = raw as? String, !value.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

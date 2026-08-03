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

/// Why identity is not usable when `isLoggedIn == false` and auth.json is present.
enum AccountAuthIssue: Equatable, Sendable {
    /// File missing — true “not logged in”.
    case notFound
    /// File exists but JSON/parse failed.
    case unreadable(String)
    /// File exists and parses, but no usable bearer token entry.
    case missingTokens

    var usageFailureMessage: String {
        switch self {
        case .notFound:
            return "未登录：请运行 grok login"
        case let .unreadable(message):
            return "auth.json 无法解析：\(message)"
        case .missingTokens:
            return "auth.json 中没有可用 token"
        }
    }

    var detailLabel: String {
        switch self {
        case .notFound:
            return "未登录（运行 grok login）"
        case .unreadable:
            return "auth.json 损坏或无法解析"
        case .missingTokens:
            return "未登录（无可用 token，运行 grok login）"
        }
    }
}

struct AccountIdentity: Equatable {
    var email: String?
    var displayName: String?
    var userID: String?
    var isLoggedIn: Bool
    var isExpired: Bool
    var isTeamPrincipal: Bool
    /// Set when credentials could not be loaded. Distinguishes missing file vs broken auth.json.
    var authIssue: AccountAuthIssue?

    init(
        email: String? = nil,
        displayName: String? = nil,
        userID: String? = nil,
        isLoggedIn: Bool = false,
        isExpired: Bool = false,
        isTeamPrincipal: Bool = false,
        authIssue: AccountAuthIssue? = nil
    ) {
        self.email = email
        self.displayName = displayName
        self.userID = userID
        self.isLoggedIn = isLoggedIn
        self.isExpired = isExpired
        self.isTeamPrincipal = isTeamPrincipal
        self.authIssue = authIssue
    }

    init(credentials: GrokCredentials) {
        self.email = credentials.email
        self.displayName = credentials.displayName
        self.userID = credentials.userID
        self.isLoggedIn = credentials.isLoggedIn
        self.isExpired = credentials.isExpired
        self.isTeamPrincipal = credentials.isTeamPrincipal
        self.authIssue = nil
    }

    /// auth.json exists but is broken (not merely “never logged in”).
    var hasBrokenAuthFile: Bool {
        if case .unreadable = authIssue { return true }
        return false
    }

    var shortLabel: String {
        if let email, !email.isEmpty {
            let local = email.split(separator: "@").first.map(String.init) ?? email
            return local
        }
        if let displayName, !displayName.isEmpty {
            return displayName
        }
        if case .unreadable = authIssue {
            return "凭证损坏"
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
        if let authIssue {
            return authIssue.detailLabel
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
    /// Distinguishes missing file vs present-but-broken credentials.
    static func identity(at authURL: URL) -> AccountIdentity {
        do {
            let credentials = try credentials(at: authURL)
            return AccountIdentity(credentials: credentials)
        } catch Error.notFound {
            return AccountIdentity(authIssue: .notFound)
        } catch let Error.decodeFailed(message) {
            return AccountIdentity(authIssue: .unreadable(message))
        } catch Error.missingTokens {
            return AccountIdentity(authIssue: .missingTokens)
        } catch {
            // File likely exists but read/IO failed — treat as unreadable, not “never logged in”.
            return AccountIdentity(authIssue: .unreadable(error.localizedDescription))
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
        let displayName = nameParts.isEmpty ? nil : nameParts.joined(separator: " ")

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
        struct Candidate {
            var scope: String
            var entry: [String: Any]
            var rank: Int // 0 OIDC, 1 legacy, 2 other
            var expiresAt: Date?
            var isExpired: Bool
        }

        var candidates: [Candidate] = []
        for (scope, value) in root {
            guard let entry = value as? [String: Any] else { continue }
            // Only accept entries that carry a usable bearer token.
            guard let key = entry["key"] as? String, !key.isEmpty else { continue }
            let rank: Int
            if scope.hasPrefix(oidcScopePrefix) {
                rank = 0
            } else if scope == legacySessionScope || scope.contains("/sign-in") {
                rank = 1
            } else {
                rank = 2
            }
            let expiresAt = parseDate(entry["expires_at"])
            let expired: Bool
            if let expiresAt {
                expired = Date() >= expiresAt.addingTimeInterval(-30)
            } else {
                expired = false // unknown expiry ≠ expired
            }
            candidates.append(Candidate(
                scope: scope,
                entry: entry,
                rank: rank,
                expiresAt: expiresAt,
                isExpired: expired
            ))
        }
        guard !candidates.isEmpty else { return nil }

        // Prefer non-expired, then OIDC > legacy > other, then latest expiresAt.
        let sorted = candidates.sorted { lhs, rhs in
            if lhs.isExpired != rhs.isExpired {
                return !lhs.isExpired && rhs.isExpired
            }
            if lhs.rank != rhs.rank {
                return lhs.rank < rhs.rank
            }
            switch (lhs.expiresAt, rhs.expiresAt) {
            case let (l?, r?):
                return l > r
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                return false
            }
        }
        let best = sorted[0]
        return (best.scope, best.entry)
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

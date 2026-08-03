import Foundation

/// Per-profile Grok credit usage for menu / status bar display.
struct ProfileUsage: Equatable, Sendable {
    enum Status: Equatable, Sendable {
        /// Not fetched yet.
        case idle
        case loading
        case ready
        case failed(String)
        case notLoggedIn
        case expired
        case teamUnsupported
    }

    var status: Status = .idle
    /// 0…100 used percent when known.
    var usedPercent: Double?
    var resetsAt: Date?
    var fetchedAt: Date?
    var errorMessage: String?

    var remainingPercent: Double? {
        guard let usedPercent else { return nil }
        return max(0, min(100, 100 - usedPercent))
    }

    /// Compact label for menu bar / row trailing, e.g. `99%` remaining.
    var remainingLabel: String? {
        switch status {
        case .loading:
            return "…"
        case .notLoggedIn:
            return nil
        case .expired:
            return "过期"
        case .teamUnsupported:
            return "团队"
        case .failed:
            return "—"
        case .idle:
            return nil
        case .ready:
            guard let remainingPercent else { return "—" }
            return Self.formatPercent(remainingPercent)
        }
    }

    /// Profile-row subtitle under the identity: reset time or status only (no percent —
    /// percent lives on the row trailing label to avoid duplication).
    var rowSecondaryLabel: String? {
        switch status {
        case .loading:
            return "查询中…"
        case .notLoggedIn:
            return nil
        case .expired:
            return "登录过期"
        case .teamUnsupported:
            return "团队不可用"
        case let .failed(message):
            return message
        case .idle:
            return nil
        case .ready:
            return resetShortLabel
        }
    }

    var resetShortLabel: String? {
        guard let resetsAt else { return nil }
        let now = Date()
        guard resetsAt > now else { return "已重置" }
        let seconds = resetsAt.timeIntervalSince(now)
        if seconds < 3600 {
            let mins = max(1, Int(seconds / 60))
            return "\(mins)m 后重置"
        }
        // Under 1 day: hours only (e.g. `18h 后重置`)
        if seconds < 86400 {
            let hours = max(1, Int(seconds / 3600))
            return "\(hours)h 后重置"
        }
        // 1 day+: days + remaining hours (e.g. `6d 5h 后重置`)
        let totalHours = Int(seconds / 3600)
        let days = totalHours / 24
        let hours = totalHours % 24
        if hours == 0 {
            return "\(days)d 后重置"
        }
        return "\(days)d \(hours)h 后重置"
    }

    /// Color hint: green plenty / orange mid / red low.
    var severity: UsageSeverity {
        guard status == .ready, let remaining = remainingPercent else {
            switch status {
            case .expired, .failed:
                return .unknown
            default:
                return .unknown
            }
        }
        if remaining <= 10 { return .critical }
        if remaining <= 25 { return .warning }
        return .ok
    }

    static func formatPercent(_ value: Double) -> String {
        let clamped = max(0, min(100, value))
        if abs(clamped - clamped.rounded()) < 0.05 {
            return "\(Int(clamped.rounded()))%"
        }
        return String(format: "%.1f%%", clamped)
    }

    static func loading() -> ProfileUsage {
        ProfileUsage(status: .loading)
    }

    static func notLoggedIn() -> ProfileUsage {
        ProfileUsage(status: .notLoggedIn)
    }

    static func expired() -> ProfileUsage {
        ProfileUsage(status: .expired, errorMessage: "登录已过期")
    }

    static func teamUnsupported() -> ProfileUsage {
        ProfileUsage(status: .teamUnsupported, errorMessage: "团队账号暂不支持查询用量")
    }

    static func failed(_ message: String) -> ProfileUsage {
        ProfileUsage(status: .failed(message), errorMessage: message)
    }

    static func ready(usedPercent: Double, resetsAt: Date?, fetchedAt: Date = Date()) -> ProfileUsage {
        ProfileUsage(
            status: .ready,
            usedPercent: usedPercent,
            resetsAt: resetsAt,
            fetchedAt: fetchedAt
        )
    }

    static func fromFetchError(_ error: UsageFetcher.FetchError) -> ProfileUsage {
        switch error {
        case .missingCredentials:
            return .notLoggedIn()
        case .expiredCredentials:
            return .expired()
        case .teamUsageUnsupported:
            return .teamUnsupported()
        case .requestFailed(status: 401, _), .requestFailed(status: 403, _):
            return .expired()
        case let .rpcFailed(status, message)
            where status == 16 || UsageFetcher.FetchError.isAuthRPC(status: status, message: message):
            return .expired()
        default:
            return .failed(error.errorDescription ?? "查询失败")
        }
    }
}

enum UsageSeverity: Equatable {
    case ok
    case warning
    case critical
    case unknown
}

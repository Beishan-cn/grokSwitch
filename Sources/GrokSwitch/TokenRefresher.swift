import Darwin
import Foundation

/// Cross-process advisory lock for `auth.json`, compatible with Grok CLI's `auth.json.lock`
/// content format (`pid:unix_ts`) and flock mutual exclusion.
enum AuthFileLock {
    /// Default wait budget when another process holds the lock (CLI mid-refresh).
    static let defaultTimeout: TimeInterval = 2.5
    private static let retryIntervalNanos: UInt64 = 50_000_000 // 50ms

    enum LockError: Error {
        case timeout
        case openFailed(Int32)
    }

    /// Run `body` while holding an exclusive flock on `authURL` + `.lock`.
    static func withLock<T>(
        authURL: URL,
        timeout: TimeInterval = defaultTimeout,
        body: () async throws -> T
    ) async throws -> T {
        let lockURL = lockURL(for: authURL)
        let path = lockURL.path
        let fd = open(path, O_RDWR | O_CREAT, 0o600)
        guard fd >= 0 else {
            throw LockError.openFailed(errno)
        }
        defer {
            _ = flock(fd, LOCK_UN)
            close(fd)
        }

        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 {
                break
            }
            if errno != EWOULDBLOCK, errno != EAGAIN {
                throw LockError.openFailed(errno)
            }
            if Date() >= deadline {
                throw LockError.timeout
            }
            try await Task.sleep(nanoseconds: retryIntervalNanos)
        }

        // Advertise holder in CLI-compatible form (best-effort).
        let stamp = "\(getpid()):\(Int(Date().timeIntervalSince1970))"
        if let data = stamp.data(using: .utf8) {
            _ = ftruncate(fd, 0)
            _ = lseek(fd, 0, SEEK_SET)
            _ = data.withUnsafeBytes { raw -> Int in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return write(fd, base, data.count)
            }
            _ = fsync(fd)
        }

        return try await body()
    }

    static func lockURL(for authURL: URL) -> URL {
        URL(fileURLWithPath: authURL.path + ".lock")
    }
}

/// Silent OIDC access-token refresh for profile `auth.json` files.
///
/// Risk controls:
/// - Only standard `refresh_token` grant against whitelisted `auth.x.ai`
/// - At most one IdP HTTP call per `ensureFresh`
/// - Early window ~5 minutes; no independent high-frequency timer
/// - flock + in-process serialisation; adopt sibling on lock timeout
/// - permanent failures remembered until auth.json identity changes
enum TokenRefresher {
    enum Outcome: Equatable, Sendable {
        case alreadyFresh
        case refreshed
        case adoptedSibling
        case skippedNoRefreshToken
        case skippedNotOIDC
        case skippedLocked
        case permanentFailure(String)
        case transientFailure(String)
    }

    private static let allowedIssuerHost = "auth.x.ai"
    private static let httpTimeout: TimeInterval = 10
    private static let fallbackExpiresIn: TimeInterval = GrokCredentials.defaultAccessTokenLifetime

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = httpTimeout
        config.timeoutIntervalForResource = httpTimeout
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    /// Serialises in-process refresh and remembers permanent failures per file identity.
    private static let gate = RefreshGate()

    /// Ensure access token is outside the early-refresh window when silent refresh is possible.
    static func ensureFresh(authURL: URL) async -> Outcome {
        await gate.ensureFresh(authURL: authURL)
    }

    // MARK: - Gate

    private actor RefreshGate {
        private struct FileIdentity: Equatable {
            var modified: Date?
            var size: UInt64
        }

        private struct InflightEntry {
            var id: UUID
            var task: Task<TokenRefresher.Outcome, Never>
        }

        /// path → file identity at the time of permanent failure
        private var permanent: [String: FileIdentity] = [:]
        /// In-flight refresh per path so concurrent usage tasks share one attempt.
        private var inflight: [String: InflightEntry] = [:]

        func ensureFresh(authURL: URL) async -> TokenRefresher.Outcome {
            let path = authURL.path
            let identity = Self.fileIdentity(at: authURL)

            if let remembered = permanent[path], remembered == identity {
                return .permanentFailure("登录已失效，请重新 grok login")
            }
            if permanent[path] != nil, permanent[path] != identity {
                permanent.removeValue(forKey: path)
            }

            if let existing = inflight[path] {
                return await existing.task.value
            }

            // Detached work survives waiter cancellation (RT refresh must not abort mid-flight).
            // A separate monitor always clears `inflight` when this generation finishes, so a
            // cancelled waiter cannot leave a sticky stale Outcome.
            let id = UUID()
            let task = Task.detached(priority: .userInitiated) {
                await TokenRefresher.performEnsureFresh(authURL: authURL)
            }
            inflight[path] = InflightEntry(id: id, task: task)
            Task {
                let outcome = await task.value
                self.finish(path: path, id: id, authURL: authURL, outcome: outcome)
            }
            return await task.value
        }

        /// Clear coalescing state for this generation only (ignore late finish after a newer attempt).
        private func finish(
            path: String,
            id: UUID,
            authURL: URL,
            outcome: TokenRefresher.Outcome
        ) {
            guard inflight[path]?.id == id else { return }
            inflight.removeValue(forKey: path)
            if case .permanentFailure = outcome {
                permanent[path] = Self.fileIdentity(at: authURL)
            }
        }

        private static func fileIdentity(at url: URL) -> FileIdentity {
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let modified = attrs?[.modificationDate] as? Date
            let size = (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
            return FileIdentity(modified: modified, size: size)
        }
    }

    // MARK: - Core (runs off MainActor)

    private static func performEnsureFresh(authURL: URL) async -> Outcome {
        let beforeKey = (try? AuthReader.credentials(at: authURL))?.accessToken

        do {
            return try await AuthFileLock.withLock(authURL: authURL) {
                let credentials: GrokCredentials
                do {
                    credentials = try AuthReader.credentials(at: authURL)
                } catch {
                    return .transientFailure("无法读取 auth.json")
                }

                if !credentials.needsRefresh {
                    if let beforeKey, beforeKey != credentials.accessToken {
                        return .adoptedSibling
                    }
                    return .alreadyFresh
                }

                guard credentials.canSilentRefresh else {
                    if credentials.refreshToken == nil {
                        return .skippedNoRefreshToken
                    }
                    return .skippedNotOIDC
                }

                guard let issuer = credentials.oidcIssuer,
                      let clientID = credentials.oidcClientID,
                      let refreshToken = credentials.refreshToken,
                      let tokenURL = tokenEndpoint(issuer: issuer)
                else {
                    return .skippedNotOIDC
                }

                // Hold lock across HTTP + write to avoid refresh-token double-spend with CLI.
                switch await refreshOnce(tokenURL: tokenURL, clientID: clientID, refreshToken: refreshToken) {
                case let .success(tokens):
                    do {
                        try writeTokens(
                            authURL: authURL,
                            scope: credentials.scope,
                            accessToken: tokens.accessToken,
                            refreshToken: tokens.refreshToken,
                            expiresAt: tokens.expiresAt
                        )
                        return .refreshed
                    } catch {
                        // IdP may have rotated the refresh token; disk still has the old one.
                        return .transientFailure(
                            "刷新成功但写入失败，请重试；若持续失败请重新 grok login"
                        )
                    }
                case let .permanent(message):
                    return .permanentFailure(message)
                case let .transient(message):
                    return .transientFailure(message)
                }
            }
        } catch AuthFileLock.LockError.timeout {
            if let after = try? AuthReader.credentials(at: authURL) {
                if let beforeKey, beforeKey != after.accessToken, !after.needsRefresh {
                    return .adoptedSibling
                }
                if !after.needsRefresh {
                    return .alreadyFresh
                }
            }
            return .skippedLocked
        } catch is CancellationError {
            // Lock wait cancelled: treat like lock skip (caller may retry later).
            return .skippedLocked
        } catch {
            return .transientFailure("获取 auth 锁失败")
        }
    }

    private static func tokenEndpoint(issuer: String) -> URL? {
        var base = issuer.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") {
            base.removeLast()
        }
        guard let url = URL(string: base + "/oauth2/token"),
              let host = url.host?.lowercased(),
              host == allowedIssuerHost,
              url.scheme?.lowercased() == "https"
        else {
            return nil
        }
        return url
    }

    private enum RefreshHTTPResult {
        case success(Tokens)
        case permanent(String)
        case transient(String)
    }

    private struct Tokens {
        var accessToken: String
        var refreshToken: String?
        var expiresAt: Date
    }

    private static func refreshOnce(
        tokenURL: URL,
        clientID: String,
        refreshToken: String
    ) async -> RefreshHTTPResult {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = httpTimeout

        let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=?"))
        let encodedRT = refreshToken.addingPercentEncoding(withAllowedCharacters: allowed) ?? refreshToken
        let encodedClient = clientID.addingPercentEncoding(withAllowedCharacters: allowed) ?? clientID
        let body = "grant_type=refresh_token&refresh_token=\(encodedRT)&client_id=\(encodedClient)"
        request.httpBody = body.data(using: .utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            return .transient("刷新登录态已取消")
        } catch {
            return .transient(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            return .transient("刷新登录态无有效响应")
        }

        if http.statusCode == 200 {
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let access = json["access_token"] as? String,
                  !access.isEmpty
            else {
                return .transient("刷新响应缺少 access_token")
            }
            let newRT = (json["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let expiresIn: TimeInterval
            if let n = json["expires_in"] as? Double {
                expiresIn = n
            } else if let n = json["expires_in"] as? Int {
                expiresIn = TimeInterval(n)
            } else if let s = json["expires_in"] as? String, let n = Double(s) {
                expiresIn = n
            } else {
                expiresIn = fallbackExpiresIn
            }
            let expiresAt = Date().addingTimeInterval(max(60, expiresIn))
            return .success(Tokens(accessToken: access, refreshToken: newRT, expiresAt: expiresAt))
        }

        let errorCode: String
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            errorCode = (json["error"] as? String) ?? ""
        } else {
            errorCode = ""
        }
        let lower = errorCode.lowercased()
        let isInvalidGrant = lower == "invalid_grant"
            || lower.contains("invalid_grant")
            || lower.contains("revoked")
        if (400 ... 499).contains(http.statusCode), isInvalidGrant {
            return .permanent("登录已失效，请重新 grok login")
        }
        return .transient("刷新登录态失败 HTTP \(http.statusCode)")
    }

    private static func writeTokens(
        authURL: URL,
        scope: String,
        accessToken: String,
        refreshToken: String?,
        expiresAt: Date
    ) throws {
        let data = try Data(contentsOf: authURL)
        let raw = try JSONSerialization.jsonObject(with: data)
        guard var root = raw as? [String: Any] else {
            throw AuthReader.Error.decodeFailed("根节点不是对象")
        }
        guard var entry = root[scope] as? [String: Any] else {
            throw AuthReader.Error.missingTokens
        }
        entry["key"] = accessToken
        if let refreshToken, !refreshToken.isEmpty {
            entry["refresh_token"] = refreshToken
        }
        entry["expires_at"] = AuthReader.formatDate(expiresAt)
        root[scope] = entry

        let out = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys]
        )
        try out.write(to: authURL, options: .atomic)
        Paths.ensureSecureFile(authURL, permissions: 0o600)
        Paths.ensureSecureFile(AuthFileLock.lockURL(for: authURL), permissions: 0o600)
    }
}

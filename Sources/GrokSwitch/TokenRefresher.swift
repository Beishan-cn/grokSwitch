import Darwin
import Foundation

/// Cross-process advisory lock for `auth.json`, compatible with Grok CLI's `auth.json.lock`
/// content format (`pid:unix_ts`) and flock mutual exclusion.
enum AuthFileLock {
    /// Default wait budget when another process holds the lock (CLI mid-refresh).
    static let defaultTimeout: TimeInterval = 2.5
    private static let retryInterval: useconds_t = 50_000 // 50ms

    enum LockError: Error {
        case timeout
        case openFailed(Int32)
    }

    /// Run `body` while holding an exclusive flock on `authURL` + `.lock`.
    static func withLock<T>(
        authURL: URL,
        timeout: TimeInterval = defaultTimeout,
        body: () throws -> T
    ) throws -> T {
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
            usleep(retryInterval)
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

        return try body()
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

        /// path → file identity at the time of permanent failure
        private var permanent: [String: FileIdentity] = [:]
        /// In-flight refresh per path so concurrent usage tasks share one attempt.
        private var inflight: [String: Task<TokenRefresher.Outcome, Never>] = [:]

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
                return await existing.value
            }

            let task = Task.detached(priority: .userInitiated) {
                TokenRefresher.performEnsureFresh(authURL: authURL)
            }
            inflight[path] = task
            let outcome = await task.value
            inflight[path] = nil

            if case .permanentFailure = outcome {
                permanent[path] = Self.fileIdentity(at: authURL)
            }
            return outcome
        }

        private static func fileIdentity(at url: URL) -> FileIdentity {
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let modified = attrs?[.modificationDate] as? Date
            let size = (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
            return FileIdentity(modified: modified, size: size)
        }
    }

    // MARK: - Core (runs off MainActor)

    private static func performEnsureFresh(authURL: URL) -> Outcome {
        let beforeKey = (try? AuthReader.credentials(at: authURL))?.accessToken

        do {
            return try AuthFileLock.withLock(authURL: authURL) {
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
                switch refreshOnce(tokenURL: tokenURL, clientID: clientID, refreshToken: refreshToken) {
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
                        return .transientFailure("写入 auth.json 失败")
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
    ) -> RefreshHTTPResult {
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

        let semaphore = DispatchSemaphore(value: 0)
        var data: Data?
        var response: URLResponse?
        var error: Error?

        let task = session.dataTask(with: request) { d, r, e in
            data = d
            response = r
            error = e
            semaphore.signal()
        }
        task.resume()
        let waitResult = semaphore.wait(timeout: .now() + httpTimeout + 2)
        if waitResult == .timedOut {
            task.cancel()
            return .transient("刷新登录态超时")
        }

        if let error {
            return .transient(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            return .transient("刷新登录态无有效响应")
        }
        let bodyData = data ?? Data()

        if http.statusCode == 200 {
            guard let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
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

        var errorCode = ""
        if let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] {
            errorCode = (json["error"] as? String) ?? ""
        }
        let lower = errorCode.lowercased()
        if http.statusCode == 400 || http.statusCode == 401 {
            if lower == "invalid_grant"
                || lower.contains("invalid_grant")
                || lower.contains("revoked")
            {
                return .permanent("登录已失效，请重新 grok login")
            }
        }
        if (400 ... 499).contains(http.statusCode), lower == "invalid_grant" {
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

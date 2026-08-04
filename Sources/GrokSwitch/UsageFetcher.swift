import Foundation

/// Fetches Grok Build credit usage via grok.com's gRPC-web billing endpoint.
/// Ported from CodexBar's `GrokWebBillingFetcher` approach:
/// `POST https://grok.com/grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig`
enum UsageFetcher {
    static let endpoint = URL(string: "https://grok.com/grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig")!
    private static let timeout: TimeInterval = 15

    enum FetchError: LocalizedError, Equatable, Sendable {
        case missingCredentials
        case expiredCredentials
        case authParseFailed(String)
        case emptyResponse
        case invalidResponse
        case truncatedResponse
        case requestFailed(status: Int, body: String)
        case rpcFailed(status: Int, message: String)
        case teamUsageUnsupported
        case parseFailed
        case network(String)

        var errorDescription: String? {
            switch self {
            case .missingCredentials:
                return "未登录：请运行 grok login"
            case .expiredCredentials:
                return "登录已过期：请重新 grok login"
            case let .authParseFailed(message):
                return "auth.json 无法解析：\(message)"
            case .emptyResponse:
                return "用量接口返回空数据"
            case .invalidResponse:
                return "用量接口响应无效"
            case .truncatedResponse:
                return "用量响应被截断"
            case let .requestFailed(status, _):
                if status == 401 || status == 403 {
                    return "认证失败：请重新 grok login"
                }
                // Do not surface raw body snippets in the menu UI.
                return "用量请求失败 HTTP \(status)"
            case let .rpcFailed(status, message):
                if status == 16 || Self.isAuthRPC(status: status, message: message) {
                    return "认证失败：请重新 grok login"
                }
                return "用量 RPC 失败 (\(status)): \(message)"
            case .teamUsageUnsupported:
                return "团队账号暂不支持查询用量"
            case .parseFailed:
                return "无法解析用量数据"
            case let .network(message):
                return "网络错误：\(message)"
            }
        }

        static func isAuthRPC(status: Int, message: String) -> Bool {
            if status == 16 { return true }
            guard status == 7 else { return false }
            let lower = message.lowercased()
            return lower.contains("bad-credentials")
                || lower.contains("unauthenticated")
                || (lower.contains("oauth2") && lower.contains("could not be validated"))
                || (lower.contains("access token")
                    && (lower.contains("invalid")
                        || lower.contains("expired")
                        || lower.contains("could not be validated")))
        }

        static func isTeamBillingUnavailable(status: Int, message: String) -> Bool {
            guard status == 9 else { return false }
            let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return normalized == "no personal team" || normalized == "no personal team."
        }
    }

    struct RawUsage: Equatable, Sendable {
        var usedPercent: Double
        var resetsAt: Date?
    }

    /// Ephemeral session: no shared URL cache / cookies for bearer traffic.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    /// Fetch usage for a profile's `auth.json`.
    static func fetch(authURL: URL) async -> Result<RawUsage, FetchError> {
        let credentials: GrokCredentials
        do {
            credentials = try AuthReader.credentials(at: authURL)
        } catch AuthReader.Error.notFound {
            return .failure(.missingCredentials)
        } catch AuthReader.Error.missingTokens {
            return .failure(.missingCredentials)
        } catch let AuthReader.Error.decodeFailed(message) {
            return .failure(.authParseFailed(message))
        } catch {
            return .failure(.authParseFailed(error.localizedDescription))
        }

        if credentials.isExpired {
            // Caller (ProfileStore) should have already tried ensureFresh; keep as hard fail.
            return .failure(.expiredCredentials)
        }

        do {
            let raw = try await fetch(accessToken: credentials.accessToken, principalType: credentials.principalType)
            return .success(raw)
        } catch let error as FetchError {
            // Single 401/auth retry: one ensureFresh + one re-fetch (no loops).
            if Self.isAuthFetchError(error) {
                let outcome = await TokenRefresher.ensureFresh(authURL: authURL)
                switch outcome {
                case .refreshed, .alreadyFresh, .adoptedSibling:
                    do {
                        let fresh = try AuthReader.credentials(at: authURL)
                        if !fresh.isExpired {
                            let raw = try await fetch(
                                accessToken: fresh.accessToken,
                                principalType: fresh.principalType
                            )
                            return .success(raw)
                        }
                    } catch let retryError as FetchError {
                        return .failure(retryError)
                    } catch {
                        return .failure(.network(error.localizedDescription))
                    }
                case .permanentFailure:
                    return .failure(.expiredCredentials)
                default:
                    break
                }
            }
            return .failure(error)
        } catch {
            return .failure(.network(error.localizedDescription))
        }
    }

    private static func isAuthFetchError(_ error: FetchError) -> Bool {
        switch error {
        case .requestFailed(status: 401, _), .requestFailed(status: 403, _):
            return true
        case let .rpcFailed(status, message):
            return status == 16 || FetchError.isAuthRPC(status: status, message: message)
        case .expiredCredentials:
            return true
        default:
            return false
        }
    }

    static func fetch(accessToken: String, principalType: String? = nil) async throws -> RawUsage {
        do {
            return try await fetchOnce(accessToken: accessToken)
        } catch {
            if shouldRetry(error) {
                do {
                    return try await fetchOnce(accessToken: accessToken)
                } catch {
                    throw classify(error, principalType: principalType)
                }
            }
            throw classify(error, principalType: principalType)
        }
    }

    // MARK: - Network

    private static func fetchOnce(accessToken: String) async throws -> RawUsage {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        // Empty gRPC-web data frame (flags=0, length=0).
        request.httpBody = Data([0x00, 0x00, 0x00, 0x00, 0x00])
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("https://grok.com", forHTTPHeaderField: "Origin")
        request.setValue("https://grok.com/?_s=usage", forHTTPHeaderField: "Referer")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("application/grpc-web+proto", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "x-grpc-web")
        request.setValue("connect-es/2.1.1", forHTTPHeaderField: "x-user-agent")
        request.setValue("GrokSwitch", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw FetchError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw FetchError.invalidResponse
        }
        guard http.statusCode == 200 else {
            let body = String(data: data.prefix(400), encoding: .utf8) ?? ""
            throw FetchError.requestFailed(status: http.statusCode, body: body)
        }

        try validateGRPCStatusFields(grpcHeaderFields(from: http.allHeaderFields))
        try validateGRPCWebTrailers(data)
        return try parseGRPCWebResponse(data)
    }

    private static func classify(_ error: Error, principalType: String?) -> Error {
        if let fetchError = error as? FetchError,
           case let .rpcFailed(status, message) = fetchError,
           principalType?.trimmingCharacters(in: .whitespacesAndNewlines)
               .caseInsensitiveCompare("team") == .orderedSame,
           FetchError.isTeamBillingUnavailable(status: status, message: message)
        {
            return FetchError.teamUsageUnsupported
        }
        return error
    }

    private static func shouldRetry(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            return urlError.code == .timedOut || urlError.code == .networkConnectionLost
        }
        guard let error = error as? FetchError else { return false }
        switch error {
        case let .requestFailed(status, body):
            if [408, 502, 503, 504].contains(status) { return true }
            return body.localizedCaseInsensitiveContains("timeout")
                || body.localizedCaseInsensitiveContains("deadline")
        case let .rpcFailed(status, message):
            if status == 4 { return true }
            guard status == 1 else { return false }
            return message.localizedCaseInsensitiveContains("timeout")
                || message.localizedCaseInsensitiveContains("deadline")
                || message.localizedCaseInsensitiveContains("expired")
        case .network:
            return true
        default:
            return false
        }
    }

    // MARK: - gRPC-web framing

    /// Heuristic parse of GetGrokCreditsConfig gRPC-web body.
    /// Percent: prefer finite fixed32 floats in [0,100] whose path ends with field 1 and starts with [1,…].
    /// Reset: prefer path [1,5,1] unix seconds; allow ~120s past grace for clock skew.
    static func parseGRPCWebResponse(_ data: Data, now: Date = Date()) throws -> RawUsage {
        if data.isEmpty { throw FetchError.emptyResponse }

        let frameResult = grpcWebDataFrames(from: data)
        var payloads = frameResult.frames.filter { !$0.isEmpty }
        if payloads.isEmpty, looksLikeProtobufPayload(data) {
            payloads = [data]
        }
        if payloads.isEmpty {
            if frameResult.truncated {
                throw FetchError.truncatedResponse
            }
            throw FetchError.emptyResponse
        }

        var scan = ProtobufScan()
        for payload in payloads {
            scan.merge(scanProtobuf(payload, depth: 0))
        }

        let percentCandidates = scan.fixed32Fields.filter { field in
            field.path.last == 1
                && field.path.first == 1
                && field.value.isFinite
                && field.value >= 0
                && field.value <= 100
        }
        let parsedPercent = percentCandidates
            .min { lhs, rhs in
                lhs.path.count == rhs.path.count ? lhs.order < rhs.order : lhs.path.count < rhs.path.count
            }
            .map { Double($0.value) }

        let resetFields = scan.varintFields.compactMap { field -> (path: [UInt64], date: Date)? in
            let raw = field.value
            guard raw >= 1_700_000_000, raw <= 2_100_000_000 else { return nil }
            return (field.path, Date(timeIntervalSince1970: TimeInterval(raw)))
        }
        // Allow slight past timestamps (clock skew) so UI can show “已重置”.
        let grace: TimeInterval = 120
        let usableResetFields = resetFields.filter { $0.date > now.addingTimeInterval(-grace) }
        let preferredReset = usableResetFields
            .filter { $0.path == [1, 5, 1] }
            .map(\.date)
            .min()
        let reset = preferredReset ?? usableResetFields.map(\.date).min()

        let hasUsagePeriod = scan.varintFields.contains { field in
            field.path.starts(with: [1, 6])
                || (field.path == [1, 8, 1] && (field.value == 1 || field.value == 2))
        }
        // Base noUsageYet on “no percent candidate”, not “no fixed32 at all”.
        let noUsageYet = parsedPercent == nil
            && percentCandidates.isEmpty
            && reset != nil
            && hasUsagePeriod

        guard let percent = parsedPercent ?? (noUsageYet ? 0 : nil) else {
            throw FetchError.parseFailed
        }
        return RawUsage(usedPercent: percent, resetsAt: reset)
    }

    private static func looksLikeProtobufPayload(_ data: Data) -> Bool {
        guard let first = data.first else { return false }
        let fieldNumber = first >> 3
        let wireType = first & 0x07
        return fieldNumber > 0 && (wireType == 0 || wireType == 1 || wireType == 2 || wireType == 5)
    }

    private struct FrameParseResult {
        var frames: [Data]
        var truncated: Bool
    }

    /// Collect complete data frames. On incomplete trailing header/body, keep frames
    /// already parsed (do not discard them as empty).
    private static func grpcWebDataFrames(from data: Data) -> FrameParseResult {
        let bytes = [UInt8](data)
        var frames: [Data] = []
        var index = 0
        var truncated = false
        let maxFrameLength = 4 * 1024 * 1024
        while index < bytes.count {
            guard index + 5 <= bytes.count else {
                truncated = true
                break
            }
            let flags = bytes[index]
            let length = (Int(bytes[index + 1]) << 24)
                | (Int(bytes[index + 2]) << 16)
                | (Int(bytes[index + 3]) << 8)
                | Int(bytes[index + 4])
            let start = index + 5
            if length < 0 || length > maxFrameLength {
                truncated = true
                break
            }
            let end = start + length
            guard end <= bytes.count else {
                truncated = true
                break
            }
            if flags & 0x80 == 0, length > 0 {
                frames.append(Data(bytes[start..<end]))
            }
            index = end
        }
        return FrameParseResult(frames: frames, truncated: truncated)
    }

    private static func validateGRPCWebTrailers(_ data: Data) throws {
        try validateGRPCStatusFields(grpcWebTrailerFields(from: data))
    }

    private static func validateGRPCStatusFields(_ fields: [String: String]) throws {
        guard let rawStatus = fields["grpc-status"],
              let status = Int(rawStatus),
              status != 0
        else {
            return
        }
        throw FetchError.rpcFailed(status: status, message: fields["grpc-message"] ?? "")
    }

    private static func grpcHeaderFields(from headers: [AnyHashable: Any]) -> [String: String] {
        var fields: [String: String] = [:]
        for (key, value) in headers {
            let normalizedKey = String(describing: key)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard normalizedKey.hasPrefix("grpc-") else { continue }
            fields[normalizedKey] = String(describing: value)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .removingPercentEncoding ?? ""
        }
        return fields
    }

    private static func grpcWebTrailerFields(from data: Data) -> [String: String] {
        let bytes = [UInt8](data)
        var fields: [String: String] = [:]
        var index = 0
        while index + 5 <= bytes.count {
            let flags = bytes[index]
            let length = (Int(bytes[index + 1]) << 24)
                | (Int(bytes[index + 2]) << 16)
                | (Int(bytes[index + 3]) << 8)
                | Int(bytes[index + 4])
            let start = index + 5
            let end = start + length
            guard length >= 0, end <= bytes.count else { break }
            if flags & 0x80 != 0, let text = String(data: Data(bytes[start..<end]), encoding: .utf8) {
                for line in text.components(separatedBy: .newlines) where !line.isEmpty {
                    guard let separator = line.firstIndex(of: ":") else { continue }
                    let key = line[..<separator]
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased()
                    let value = line[line.index(after: separator)...]
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .removingPercentEncoding ?? ""
                    fields[key] = value
                }
            }
            index = end
        }
        return fields
    }

    // MARK: - Protobuf scan

    private struct ProtobufScan {
        struct Fixed32Field {
            var path: [UInt64]
            var value: Float
            var order: Int
        }

        struct VarintField {
            var path: [UInt64]
            var value: UInt64
        }

        var fixed32Fields: [Fixed32Field] = []
        var varintFields: [VarintField] = []

        mutating func merge(_ other: ProtobufScan) {
            fixed32Fields.append(contentsOf: other.fixed32Fields)
            varintFields.append(contentsOf: other.varintFields)
        }
    }

    private static func scanProtobuf(_ data: Data, depth: Int) -> ProtobufScan {
        scanProtobuf(data, depth: depth, path: [], order: 0).scan
    }

    private static func scanProtobuf(
        _ data: Data,
        depth: Int,
        path: [UInt64],
        order: Int
    ) -> (scan: ProtobufScan, order: Int) {
        let bytes = [UInt8](data)
        var scan = ProtobufScan()
        var index = 0
        var nextOrder = order

        while index < bytes.count {
            let fieldStart = index
            guard let key = readVarint(bytes, index: &index), key != 0 else {
                index = fieldStart + 1
                continue
            }
            let fieldNumber = key >> 3
            let wireType = key & 0x07
            let fieldPath = path + [fieldNumber]

            switch wireType {
            case 0:
                if let value = readVarint(bytes, index: &index) {
                    scan.varintFields.append(ProtobufScan.VarintField(path: fieldPath, value: value))
                } else {
                    index = fieldStart + 1
                }
            case 1:
                guard index + 8 <= bytes.count else { return (scan, nextOrder) }
                index += 8
            case 2:
                guard let length = readVarint(bytes, index: &index),
                      length <= UInt64(bytes.count - index)
                else {
                    index = fieldStart + 1
                    continue
                }
                let start = index
                let end = index + Int(length)
                if depth < 4 {
                    let nested = scanProtobuf(
                        Data(bytes[start..<end]),
                        depth: depth + 1,
                        path: fieldPath,
                        order: nextOrder
                    )
                    scan.merge(nested.scan)
                    nextOrder = nested.order
                }
                index = end
            case 5:
                guard index + 4 <= bytes.count else { return (scan, nextOrder) }
                let bitPattern = UInt32(bytes[index])
                    | (UInt32(bytes[index + 1]) << 8)
                    | (UInt32(bytes[index + 2]) << 16)
                    | (UInt32(bytes[index + 3]) << 24)
                scan.fixed32Fields.append(ProtobufScan.Fixed32Field(
                    path: fieldPath,
                    value: Float(bitPattern: bitPattern),
                    order: nextOrder
                ))
                nextOrder += 1
                index += 4
            default:
                index = fieldStart + 1
            }
        }

        return (scan, nextOrder)
    }

    private static func readVarint(_ bytes: [UInt8], index: inout Int) -> UInt64? {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        while index < bytes.count, shift < 64 {
            let byte = bytes[index]
            index += 1
            value |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return value }
            shift += 7
        }
        return nil
    }
}

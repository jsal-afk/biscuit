import CoreFoundation
import Foundation

struct NativeUsageWindow: Equatable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case primary
        case secondary

        var localizedTitle: String {
            BiscuitLocalization.string(rawValue.capitalized)
        }
    }

    let kind: Kind
    let usedPercent: Double
    let resetsAt: Date?

    var remainingPercent: Double { min(100, max(0, 100 - usedPercent)) }
}

struct NativeUsageSnapshot: Equatable, Sendable {
    let windows: [NativeUsageWindow]

    func displayText(now: Date = Date()) -> String {
        guard !windows.isEmpty else { return BiscuitLocalization.string("No usage information") }
        return windows.map { window in
            let remaining = BiscuitLocalization.format("%.0f%% left", arguments: [window.remainingPercent])
            guard let reset = window.resetsAt else {
                return BiscuitLocalization.format("%@ · %@", arguments: [window.kind.localizedTitle, remaining])
            }
            let duration = Self.duration(until: reset, now: now)
            return BiscuitLocalization.format("%@ · %@ · resets in %@", arguments: [window.kind.localizedTitle, remaining, duration])
        }.joined(separator: "\n")
    }

    private static func duration(until date: Date, now: Date) -> String {
        let totalMinutes = max(0, Int(ceil(date.timeIntervalSince(now) / 60)))
        let days = totalMinutes / 1_440
        let hours = (totalMinutes % 1_440) / 60
        let minutes = totalMinutes % 60
        if days > 0, hours > 0 {
            return BiscuitLocalization.format("%d d %d h", arguments: [days, hours])
        }
        if days > 0 {
            return BiscuitLocalization.format("%d d", arguments: [days])
        }
        if hours > 0, minutes > 0 {
            return BiscuitLocalization.format("%d h %d min", arguments: [hours, minutes])
        }
        if hours > 0 {
            return BiscuitLocalization.format("%d h", arguments: [hours])
        }
        return BiscuitLocalization.format("%d min", arguments: [minutes])
    }
}

struct NativeUsageHTTPResponse: Sendable {
    let statusCode: Int
    let url: URL?
    let data: Data
}

protocol NativeUsageTransport: Sendable {
    func get(_ request: URLRequest) async throws -> NativeUsageHTTPResponse
}

final class NativeURLSessionUsageTransport: NativeUsageTransport, @unchecked Sendable {
    func get(_ request: URLRequest) async throws -> NativeUsageHTTPResponse {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 30
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: NativeUsageRedirectPolicy(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw NativeUsageError.invalidHTTPResponse
        }
        var data = Data()
        data.reserveCapacity(1_024)
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < NativeUsage.maximumResponseBytes else {
                throw NativeUsageError.responseTooLarge
            }
            data.append(byte)
        }
        return NativeUsageHTTPResponse(statusCode: response.statusCode, url: response.url, data: data)
    }
}

enum NativeUsageError: LocalizedError, Sendable {
    case missingAccess(NativeProvider)
    case invalidHTTPResponse
    case responseTooLarge
    case rejected(NativeProvider, Int)
    case malformed(NativeProvider)
    case timeout(NativeProvider)
    case transportFailure(NativeProvider)

    var errorDescription: String? {
        switch self {
        case .missingAccess(let provider):
            return BiscuitLocalization.format("No current %@ subscription session is available.", arguments: [provider.title])
        case .invalidHTTPResponse:
            return BiscuitLocalization.string("The usage service returned an invalid HTTP response.")
        case .responseTooLarge:
            return BiscuitLocalization.string("The usage service returned a response that was too large to process.")
        case .rejected(let provider, let status):
            return BiscuitLocalization.format("The %@ usage service rejected the request (HTTP %d).", arguments: [provider.title, status])
        case .malformed(let provider):
            return BiscuitLocalization.format("The %@ usage service returned unsupported or incomplete usage data.", arguments: [provider.title])
        case .timeout(let provider):
            return BiscuitLocalization.format("The %@ usage request timed out. Check the network and try again.", arguments: [provider.title])
        case .transportFailure(let provider):
            return BiscuitLocalization.format("Could not retrieve %@ usage. Check the network and try again.", arguments: [provider.title])
        }
    }
}

enum NativeUsage {
    static let chatGPTEndpoint = URL(string: "https://chatgpt.com/backend-api/codex/usage")!
    static let claudeEndpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let maximumResponseBytes = 64 * 1_024

    static func request(provider: NativeProvider, access: SubscriptionAccess) throws -> URLRequest {
        guard !access.accessToken.isEmpty, !containsNewline(access.accessToken) else {
            throw NativeUsageError.missingAccess(provider)
        }
        let endpoint: URL
        switch provider {
        case .chatgpt:
            guard let accountID = access.accountID, !accountID.isEmpty, !containsNewline(accountID) else {
                throw NativeUsageError.missingAccess(provider)
            }
            endpoint = chatGPTEndpoint
        case .claude:
            endpoint = claudeEndpoint
        }

        var request = URLRequest(url: endpoint, timeoutInterval: 30)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue("Bearer \(access.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(NativeHTTPIdentity.userAgent, forHTTPHeaderField: "User-Agent")
        if provider == .chatgpt {
            request.setValue(access.accountID, forHTTPHeaderField: "ChatGPT-Account-ID")
        } else {
            request.setValue(NativeClaudeOAuthProtocol.messagesBeta, forHTTPHeaderField: "anthropic-beta")
        }
        return request
    }

    static func fetch(
        provider: NativeProvider,
        access: SubscriptionAccess,
        transport: NativeUsageTransport = NativeURLSessionUsageTransport()
    ) async throws -> NativeUsageSnapshot {
        let request = try request(provider: provider, access: access)
        do {
            let response = try await transport.get(request)
            guard let responseURL = response.url,
                  origin(responseURL) == origin(request.url) else {
                throw NativeUsageError.invalidHTTPResponse
            }
            guard (200..<300).contains(response.statusCode) else {
                throw NativeUsageError.rejected(provider, response.statusCode)
            }
            guard response.data.count <= maximumResponseBytes else { throw NativeUsageError.responseTooLarge }
            return try parse(provider: provider, data: response.data)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .timedOut {
            throw NativeUsageError.timeout(provider)
        } catch let error as URLError where error.code == .cancelled && Task.isCancelled {
            throw CancellationError()
        } catch let error as NativeUsageError {
            throw error
        } catch {
            throw NativeUsageError.transportFailure(provider)
        }
    }

    static func parse(provider: NativeProvider, data: Data) throws -> NativeUsageSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NativeUsageError.malformed(provider)
        }
        let windows: [NativeUsageWindow]
        switch provider {
        case .chatgpt:
            guard let rateLimitValue = root["rate_limit"], !(rateLimitValue is NSNull) else {
                return NativeUsageSnapshot(windows: [])
            }
            guard let rateLimit = rateLimitValue as? [String: Any] else {
                throw NativeUsageError.malformed(provider)
            }
            windows = try [
                parseWindow(rateLimit["primary_window"], provider: provider, kind: .primary,
                            percentKey: "used_percent", resetKey: "reset_at"),
                parseWindow(rateLimit["secondary_window"], provider: provider, kind: .secondary,
                            percentKey: "used_percent", resetKey: "reset_at")
            ].compactMap { $0 }
        case .claude:
            windows = try [
                parseWindow(root["five_hour"], provider: provider, kind: .primary,
                            percentKey: "utilization", resetKey: "resets_at"),
                parseWindow(root["seven_day"], provider: provider, kind: .secondary,
                            percentKey: "utilization", resetKey: "resets_at")
            ].compactMap { $0 }
            guard !windows.isEmpty else { throw NativeUsageError.malformed(provider) }
        }
        return NativeUsageSnapshot(windows: windows)
    }

    private static func parseWindow(
        _ value: Any?,
        provider: NativeProvider,
        kind: NativeUsageWindow.Kind,
        percentKey: String,
        resetKey: String
    ) throws -> NativeUsageWindow? {
        guard let value, !(value is NSNull) else { return nil }
        guard let object = value as? [String: Any],
              let usedPercent = percentage(object[percentKey]) else {
            throw NativeUsageError.malformed(provider)
        }
        return NativeUsageWindow(kind: kind, usedPercent: usedPercent, resetsAt: resetDate(object[resetKey]))
    }

    private static func containsNewline(_ string: String) -> Bool {
        string.rangeOfCharacter(from: .newlines) != nil
    }

    private static let fractionalISO8601 = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let standardISO8601 = Date.ISO8601FormatStyle()

    private static func percentage(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let result = number.doubleValue
        return result.isFinite && result >= 0 ? result : nil
    }

    private static func resetDate(_ value: Any?) -> Date? {
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            let timestamp = number.doubleValue
            guard timestamp.isFinite, (-62_135_596_800...253_402_300_799).contains(timestamp) else { return nil }
            return Date(timeIntervalSince1970: timestamp)
        }
        guard let string = value as? String else { return nil }
        if let date = try? fractionalISO8601.parse(string) { return date }
        return try? standardISO8601.parse(string)
    }

    fileprivate static func origin(_ url: URL?) -> String? {
        guard let url, let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else { return nil }
        let port = url.port ?? (scheme == "https" ? 443 : 80)
        return "\(scheme)://\(host):\(port)"
    }
}

private final class NativeUsageRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard NativeUsage.origin(response.url) == NativeUsage.origin(request.url) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

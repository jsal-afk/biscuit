import Foundation

enum NativeReasoningEffort: String, CaseIterable, Identifiable {
    case low
    case medium
    case high

    static let preferenceKey = "language.native.reasoningEffort"
    static let defaultValue: Self = .low

    var id: String { rawValue }

    var title: String {
        let key: String
        switch self {
        case .low: key = "Low (fastest)"
        case .medium: key = "Medium"
        case .high: key = "High"
        }
        return BiscuitLocalization.string(key)
    }

    static func selected(from defaults: UserDefaults = BiscuitPreferences.defaults) -> Self {
        guard let value = defaults.string(forKey: preferenceKey),
              let effort = Self(rawValue: value) else { return defaultValue }
        return effort
    }
}

// Public model IDs for which Anthropic documents Messages API effort support.
// Keep unsupported selectable models (for example Haiku 4.5) out of the effort
// field rather than making an otherwise-valid request fail.
enum NativeClaudeModelCapabilities {
    private static let effortModels: Set<String> = [
        "claude-fable-5-1", "claude-mythos-5-1", "claude-fable-5", "claude-mythos-5",
        "claude-mythos-preview", "claude-opus-5-5", "claude-opus-5", "claude-sonnet-5-5",
        "claude-sonnet-5", "claude-haiku-5-5", "claude-opus-4-8", "claude-opus-4-7",
        "claude-opus-4-6", "claude-sonnet-4-6", "claude-opus-4-5-20251101"
    ]

    static func supportsReasoningEffort(model: String) -> Bool {
        effortModels.contains(model)
    }
}

enum NativeChatGPTModelCapabilities {
    static func supportsReasoningEffort(model: String) -> Bool {
        let normalized = model.lowercased()
        return ["gpt-5", "gpt-6"].contains {
            normalized == $0 || normalized.hasPrefix($0 + ".") || normalized.hasPrefix($0 + "-")
        }
    }
}

enum NativeReasoningEffortPayload {
    static func supports(provider: NativeProvider, model: String) -> Bool {
        switch provider {
        case .chatgpt:
            return NativeChatGPTModelCapabilities.supportsReasoningEffort(model: model)
        case .claude:
            return NativeClaudeModelCapabilities.supportsReasoningEffort(model: model)
        }
    }
}

/// Direct native subscription transports. These endpoints are provider-controlled
/// compatibility surfaces; source-level protocol matches do not guarantee third-party access.
enum NativeSubscription {
    static let chatGPTEndpoint = URL(string: "https://chatgpt.com/backend-api/codex/responses")!
    static let claudeEndpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    static let defaultChatGPTModelID = "gpt-6.1-sol"
    static let defaultClaudeModelID = "claude-sonnet-5-5"
    static let chatGPTModelPreferenceKey = "language.chatgpt.modelID"
    static let claudeModelPreferenceKey = "language.claude.modelID"

    private static let requestTimeout: TimeInterval = 120
    private static let resourceTimeout: TimeInterval = 180
    private static let maximumErrorBodyBytes = 16 * 1024

    /// `onText` receives accumulated assistant text as genuine text deltas arrive.
    static func stream(
        provider: NativeProvider = .chatgpt,
        text: String,
        instructions: String,
        model: String,
        reasoningEffort: NativeReasoningEffort = .defaultValue,
        onText: @escaping @Sendable (String) -> Void,
        beforeRequest: @escaping @MainActor () throws -> Void = {}
    ) async throws -> String {
        guard !text.isEmpty, !instructions.isEmpty,
              !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw StreamError.invalidRequest(provider)
        }
        try Task.checkCancellation()

        let access = try await NativeAccountController.shared.access(provider: provider)
        try Task.checkCancellation()
        guard !access.accessToken.isEmpty, !access.accessToken.containsNewline else {
            throw StreamError.missingAccess(provider)
        }
        var chatGPTAccountID: String?
        if provider == .chatgpt {
            guard let accountID = access.accountID, !accountID.isEmpty, !accountID.containsNewline else {
                throw StreamError.missingAccess(provider)
            }
            chatGPTAccountID = accountID
        }

        let endpoint = endpoint(for: provider)
        var request = URLRequest(url: endpoint, timeoutInterval: requestTimeout)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.setValue("Bearer \(access.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(NativeHTTPIdentity.userAgent, forHTTPHeaderField: "User-Agent")
        if let chatGPTAccountID {
            request.setValue(chatGPTAccountID, forHTTPHeaderField: "ChatGPT-Account-ID")
        } else {
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            request.setValue(NativeClaudeOAuthProtocol.messagesBeta, forHTTPHeaderField: "anthropic-beta")
        }
        request.httpBody = try makeRequestBody(provider: provider, text: text, instructions: instructions,
                                               model: model, reasoningEffort: reasoningEffort)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        let redirectPolicy = SameOriginRedirectPolicy()
        let session = URLSession(configuration: configuration, delegate: redirectPolicy, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        do {
            return try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try await beforeRequest()
                let (bytes, response) = try await session.bytes(for: request)
                guard let response = response as? HTTPURLResponse else {
                    throw StreamError.invalidHTTPResponse(provider)
                }
                guard (200..<300).contains(response.statusCode) else {
                    let body = try await readErrorBody(bytes)
                    let failure = httpFailure(provider: provider, statusCode: response.statusCode,
                                              retryAfter: response.value(forHTTPHeaderField: "Retry-After"),
                                              body: body, accessToken: access.accessToken)
                    if response.statusCode == 401 {
                        await NativeAccountController.shared.invalidateAccess(provider: provider, usedToken: access.accessToken)
                    }
                    throw failure
                }
                if let mimeType = response.mimeType?.lowercased(), !mimeType.contains("text/event-stream") {
                    throw StreamError.unexpectedContentType(provider)
                }

                var parser = NativeResponseStreamParser(provider: provider)
                for try await byte in bytes {
                    try Task.checkCancellation()
                    try parser.append(byte, onText: onText)
                    if parser.isComplete { return try parser.finish() }
                }
                return try parser.finish()
            } onCancel: {
                session.invalidateAndCancel()
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .timedOut {
            throw StreamError.timeout(provider)
        } catch let error as URLError where error.code == .cancelled && Task.isCancelled {
            throw CancellationError()
        } catch {
            throw error
        }
    }

    /// Fixture boundary for checking wire bodies without account access or network activity.
    static func makeRequestBody(
        provider: NativeProvider = .chatgpt,
        text: String,
        instructions: String,
        model: String,
        reasoningEffort: NativeReasoningEffort = .defaultValue
    ) throws -> Data {
        var body: [String: Any]
        switch provider {
        case .chatgpt:
            body = [
                "model": model,
                "stream": true,
                "store": false,
                "instructions": instructions,
                "input": [[
                    "role": "user",
                    "content": [["type": "input_text", "text": text]]
                ]],
                "tools": [],
                "tool_choice": "none",
                "parallel_tool_calls": false
            ]
            if NativeReasoningEffortPayload.supports(provider: provider, model: model) {
                body["reasoning"] = ["effort": reasoningEffort.rawValue]
            }
        case .claude:
            body = [
                "model": model,
                "max_tokens": 4096,
                "stream": true,
                "system": instructions,
                "messages": [["role": "user", "content": text]]
            ]
            if NativeReasoningEffortPayload.supports(provider: provider, model: model) {
                body["output_config"] = ["effort": reasoningEffort.rawValue]
            }
        }
        return try JSONSerialization.data(withJSONObject: body)
    }

    /// Fixture boundary for HTTP error mapping; server bodies are bounded and credential-redacted.
    static func httpFailure(
        provider: NativeProvider = .chatgpt,
        statusCode: Int,
        retryAfter: String? = nil,
        body: Data = Data(),
        accessToken: String = ""
    ) -> HTTPFailure {
        HTTPFailure(provider: provider, statusCode: statusCode,
                    retryAfter: retryDelay(from: retryAfter), detail: serverMessage(from: body, accessToken: accessToken))
    }

    struct HTTPFailure: LocalizedError {
        let provider: NativeProvider
        let statusCode: Int
        let retryAfter: String?
        let detail: String?

        var errorDescription: String? {
            let providerName = provider == .chatgpt ? "ChatGPT" : "Claude"
            let base: String
            switch statusCode {
            case 301...399:
                base = BiscuitLocalization.format("%@ redirected the subscription request. Biscuit stopped rather than forwarding account credentials to another origin.", arguments: [providerName])
            case 401:
                base = BiscuitLocalization.format("The %@ subscription session expired or was rejected. Open %@ Account Settings and reconnect your account.", arguments: [providerName, providerName])
            case 403:
                base = BiscuitLocalization.format("The %@ account is not authorized for this subscription request. Check the signed-in account and plan access.", arguments: [providerName])
            case 408, 504:
                base = BiscuitLocalization.format("The %@ subscription request timed out. Check the network and try again.", arguments: [providerName])
            case 429:
                if let retryAfter {
                    base = BiscuitLocalization.format("The %@ account is rate-limited or has reached an account usage limit. Retry after %@.", arguments: [providerName, retryAfter])
                } else {
                    base = BiscuitLocalization.format("The %@ account is rate-limited or has reached an account usage limit. Wait before retrying.", arguments: [providerName])
                }
            case 500...599:
                base = BiscuitLocalization.format("The %@ service returned HTTP %d. Try again later.", arguments: [providerName, statusCode])
            default:
                base = BiscuitLocalization.format("The %@ service rejected the request (HTTP %d). Check the model ID and account access.", arguments: [providerName, statusCode])
            }
            return detail.map { BiscuitLocalization.format("%@ Details: %@", arguments: [base, $0]) } ?? base
        }
    }

    fileprivate enum StreamError: LocalizedError {
        case invalidRequest(NativeProvider)
        case missingAccess(NativeProvider)
        case invalidHTTPResponse(NativeProvider)
        case unexpectedContentType(NativeProvider)
        case timeout(NativeProvider)
        case malformedEvent(NativeProvider)
        case oversizedEvent(NativeProvider)
        case unfinishedEvent(NativeProvider)
        case unfinishedResponse(NativeProvider)
        case emptyResponse(NativeProvider)
        case providerFailed(NativeProvider, String)
        case incompleteResponse(NativeProvider, String)

        var errorDescription: String? {
            let provider: NativeProvider
            switch self {
            case .invalidRequest(let value), .missingAccess(let value), .invalidHTTPResponse(let value),
                 .unexpectedContentType(let value), .timeout(let value), .malformedEvent(let value),
                 .oversizedEvent(let value), .unfinishedEvent(let value), .unfinishedResponse(let value),
                 .emptyResponse(let value), .providerFailed(let value, _), .incompleteResponse(let value, _):
                provider = value
            }
            let name = provider == .chatgpt ? "ChatGPT" : "Claude"
            switch self {
            case .invalidRequest:
                return BiscuitLocalization.format("The %@ request needs source text, instructions, and a public model ID.", arguments: [name])
            case .missingAccess:
                return BiscuitLocalization.format("No current %@ subscription session is available. Open %@ Account Settings and sign in; biscuit does not fall back to a CLI or API key.", arguments: [name, name])
            case .invalidHTTPResponse:
                return BiscuitLocalization.format("The %@ service returned an invalid HTTP response.", arguments: [name])
            case .unexpectedContentType:
                return BiscuitLocalization.format("The %@ service did not return a server-sent event stream. Try again later.", arguments: [name])
            case .timeout:
                return BiscuitLocalization.format("The %@ subscription request timed out. Check the network and try again.", arguments: [name])
            case .malformedEvent:
                return BiscuitLocalization.format("The %@ service returned malformed streaming data. No complete answer was received.", arguments: [name])
            case .oversizedEvent:
                return BiscuitLocalization.format("The %@ service returned an unexpectedly large streaming event.", arguments: [name])
            case .unfinishedEvent:
                return BiscuitLocalization.format("The %@ stream ended in the middle of an event. The partial answer is incomplete.", arguments: [name])
            case .unfinishedResponse:
                return BiscuitLocalization.format("The %@ stream ended before a terminal completion event. The partial answer is incomplete.", arguments: [name])
            case .emptyResponse:
                return BiscuitLocalization.format("The %@ service completed without an answer. Check the model ID and try again.", arguments: [name])
            case .providerFailed(_, let message):
                return BiscuitLocalization.format("%@ response failed: %@", arguments: [name, message])
            case .incompleteResponse(_, let reason):
                return BiscuitLocalization.format("%@ response was incomplete: %@", arguments: [name, reason])
            }
        }
    }

    private static func endpoint(for provider: NativeProvider) -> URL {
        provider == .chatgpt ? chatGPTEndpoint : claudeEndpoint
    }

    private static func readErrorBody(_ bytes: URLSession.AsyncBytes) async throws -> Data {
        var body = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            body.append(byte)
            if body.count >= maximumErrorBodyBytes { break }
        }
        return body
    }

    private static func serverMessage(from data: Data, accessToken: String) -> String? {
        guard !data.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let error = object["error"] as? [String: Any]
        guard let message = error?["message"] as? String ?? object["message"] as? String else { return nil }
        var safe = message.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if !accessToken.isEmpty { safe = safe.replacingOccurrences(of: accessToken, with: "[redacted]") }
        return String(safe.prefix(512)).isEmpty ? nil : String(safe.prefix(512))
    }

    private static func retryDelay(from value: String?) -> String? {
        guard let value else { return nil }
        if let seconds = Double(value), seconds.isFinite, seconds >= 0,
           let wholeSeconds = Int(exactly: ceil(seconds)) {
            return BiscuitLocalization.format("%d seconds", arguments: [wholeSeconds])
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: value) else { return nil }
        guard let seconds = Int(exactly: ceil(max(0, date.timeIntervalSinceNow))) else { return nil }
        return BiscuitLocalization.format("%d seconds", arguments: [seconds])
    }

    private static func origin(of url: URL?) -> String? {
        guard let url, let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else { return nil }
        let port = url.port ?? (scheme == "https" ? 443 : 80)
        return "\(scheme)://\(host):\(port)"
    }

    private final class SameOriginRedirectPolicy: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            guard NativeSubscription.origin(of: response.url) == NativeSubscription.origin(of: request.url) else {
                completionHandler(nil)
                return
            }
            completionHandler(request)
        }
    }
}

private extension String {
    var containsNewline: Bool { rangeOfCharacter(from: .newlines) != nil }
}
enum NativeSSEError: Error {
    case malformedEvent
    case oversizedEvent
    case unfinishedEvent
}

/// Minimal SSE framing parser. It retains raw bytes until a complete UTF-8 line is available,
/// so UTF-8 scalars may safely span arbitrary URLSession chunks.
struct NativeSSEEvent: Equatable {
    let name: String
    let data: String
}

struct NativeSSEParser {
    private static let maximumEventBytes = 8 * 1024 * 1024
    private var line = Data()
    private var eventName: String?
    private var dataLines: [String] = []
    private var eventBytes = 0
    private var skipNextLF = false

    mutating func append(_ byte: UInt8) throws -> NativeSSEEvent? {
        if skipNextLF {
            skipNextLF = false
            if byte == 10 { return nil }
        }
        if byte == 13 {
            skipNextLF = true
            return try consumeLine()
        }
        if byte == 10 { return try consumeLine() }
        line.append(byte)
        guard line.count <= Self.maximumEventBytes else { throw NativeSSEError.oversizedEvent }
        return nil
    }

    mutating func finish() throws {
        guard line.isEmpty, eventName == nil, dataLines.isEmpty else {
            throw NativeSSEError.unfinishedEvent
        }
    }

    private mutating func consumeLine() throws -> NativeSSEEvent? {
        if line.isEmpty {
            defer { eventName = nil; dataLines.removeAll(keepingCapacity: true); eventBytes = 0 }
            guard !dataLines.isEmpty else { return nil }
            return NativeSSEEvent(name: eventName ?? "message", data: dataLines.joined(separator: "\n"))
        }
        guard let value = String(data: line, encoding: .utf8) else {
            throw NativeSSEError.malformedEvent
        }
        line.removeAll(keepingCapacity: true)
        guard !value.hasPrefix(":") else { return nil }
        let separator = value.firstIndex(of: ":")
        let field = separator.map { String(value[..<$0]) } ?? value
        var fieldValue = separator.map { String(value[value.index(after: $0)...]) } ?? ""
        if fieldValue.first == " " { fieldValue.removeFirst() }
        switch field {
        case "event": eventName = fieldValue
        case "data":
            eventBytes += fieldValue.utf8.count
            guard eventBytes <= Self.maximumEventBytes else { throw NativeSSEError.oversizedEvent }
            dataLines.append(fieldValue)
        default: break
        }
        return nil
    }
}

/// Provider-specific event decoder. It emits only assistant text, never reasoning or tool data.
struct NativeResponseStreamParser {
    private let provider: NativeProvider
    private var framing = NativeSSEParser()
    private var claudeStopReason: String?
    private(set) var output = ""
    private(set) var isComplete = false

    init(provider: NativeProvider = .chatgpt) { self.provider = provider }

    mutating func append(_ byte: UInt8, onText: (String) -> Void) throws {
        let event: NativeSSEEvent?
        do { event = try framing.append(byte) } catch { throw providerError(for: error) }
        guard let event else { return }
        try consume(event, onText: onText)
    }

    mutating func append(_ data: Data, onText: (String) -> Void) throws {
        for byte in data { try append(byte, onText: onText) }
    }

    mutating func finish() throws -> String {
        do { try framing.finish() } catch { throw providerError(for: error) }
        guard isComplete else { throw NativeSubscription.StreamError.unfinishedResponse(provider) }
        guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NativeSubscription.StreamError.emptyResponse(provider)
        }
        return output
    }

    private mutating func consume(_ event: NativeSSEEvent, onText: (String) -> Void) throws {
        guard let object = try? JSONSerialization.jsonObject(with: Data(event.data.utf8)) as? [String: Any] else {
            throw NativeSubscription.StreamError.malformedEvent(provider)
        }
        if provider == .chatgpt {
            try consumeChatGPT(event.name, object: object, onText: onText)
        } else {
            try consumeClaude(event.name, object: object, onText: onText)
        }
    }

    private mutating func consumeChatGPT(_ eventName: String, object: [String: Any], onText: (String) -> Void) throws {
        let type = eventName == "message" ? (object["type"] as? String ?? eventName) : eventName
        switch type {
        case "response.output_text.delta":
            guard let delta = object["delta"] as? String else { throw NativeSubscription.StreamError.malformedEvent(provider) }
            appendText(delta, onText: onText)
        case "response.output_text.done":
            if output.isEmpty, let final = object["text"] as? String { appendText(final, onText: onText) }
        case "response.completed":
            let response = object["response"] as? [String: Any] ?? object
            if let final = Self.chatGPTOutputText(from: response), final != output {
                output = final
                onText(output)
            }
            guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw NativeSubscription.StreamError.emptyResponse(provider)
            }
            isComplete = true
        case "response.failed", "error":
            let response = object["response"] as? [String: Any] ?? object
            let error = response["error"] as? [String: Any] ?? object["error"] as? [String: Any]
            let message = Self.boundedMessage(error?["message"] as? String ?? object["message"] as? String ?? BiscuitLocalization.string("The provider returned an error."))
            throw NativeSubscription.StreamError.providerFailed(provider, message)
        case "response.incomplete":
            let response = object["response"] as? [String: Any] ?? object
            let details = response["incomplete_details"] as? [String: Any]
            let reason = Self.boundedMessage(details?["reason"] as? String ?? BiscuitLocalization.string("The provider stopped before completing the response."))
            throw NativeSubscription.StreamError.incompleteResponse(provider, reason)
        default:
            break
        }
    }

    private mutating func consumeClaude(_ eventName: String, object: [String: Any], onText: (String) -> Void) throws {
        switch eventName {
        case "content_block_delta":
            if let delta = object["delta"] as? [String: Any], delta["type"] as? String == "text_delta" {
                guard let text = delta["text"] as? String else { throw NativeSubscription.StreamError.malformedEvent(provider) }
                appendText(text, onText: onText)
            }
        case "message_delta":
            let delta = object["delta"] as? [String: Any]
            claudeStopReason = delta?["stop_reason"] as? String
        case "message_stop":
            if claudeStopReason == "max_tokens" {
                throw NativeSubscription.StreamError.incompleteResponse(provider, BiscuitLocalization.string("the output token limit was reached"))
            }
            guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw NativeSubscription.StreamError.emptyResponse(provider)
            }
            isComplete = true
        case "error":
            let error = object["error"] as? [String: Any]
            let message = Self.boundedMessage(error?["message"] as? String ?? object["message"] as? String ?? BiscuitLocalization.string("The provider returned an error."))
            throw NativeSubscription.StreamError.providerFailed(provider, message)
        default:
            break
        }
    }

    private mutating func appendText(_ text: String, onText: (String) -> Void) {
        guard !text.isEmpty else { return }
        output.append(contentsOf: text)
        onText(output)
    }

    private func providerError(for error: Error) -> Error {
        guard let framingError = error as? NativeSSEError else { return error }
        switch framingError {
        case .unfinishedEvent: return NativeSubscription.StreamError.unfinishedEvent(provider)
        case .malformedEvent: return NativeSubscription.StreamError.malformedEvent(provider)
        case .oversizedEvent: return NativeSubscription.StreamError.oversizedEvent(provider)
        }
    }

    private static func chatGPTOutputText(from response: [String: Any]) -> String? {
        if let text = response["output_text"] as? String { return text }
        guard let items = response["output"] as? [[String: Any]] else { return nil }
        var result = ""
        for item in items where item["type"] as? String == "message" {
            guard let content = item["content"] as? [[String: Any]] else { continue }
            for block in content where block["type"] as? String == "output_text" {
                if let text = block["text"] as? String { result.append(contentsOf: text) }
            }
        }
        return result.isEmpty ? nil : result
    }

    private static func boundedMessage(_ message: String) -> String {
        let normalized = message.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return String(normalized.prefix(512))
    }
}

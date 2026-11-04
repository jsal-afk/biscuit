import Foundation

/// Local protocol checks only: never credentials, login, networking, or model output acceptance.
enum SubscriptionSmoke {
    struct Failure: Error, CustomStringConvertible { let description: String }

    static func run() throws { try runNonClaude() }

    static func runNonClaude() throws {
        func require(_ condition: Bool, _ message: String) throws {
            if !condition { throw Failure(description: message) }
        }
        func rejects(_ message: String, _ operation: () throws -> Void) throws {
            do { try operation() } catch { return }
            throw Failure(description: message)
        }
        func event(_ name: String, _ json: String) -> String { "event: \(name)\r\ndata: \(json)\r\n\r\n" }

        var framing = NativeSSEParser()
        var events: [NativeSSEEvent] = []
        for byte in Data(": keepalive\r\nevent: text\r\ndata: 한\r\ndata: 글\r\n\r\n".utf8) {
            if let value = try framing.append(byte) { events.append(value) }
        }
        try framing.finish()
        try require(events == [NativeSSEEvent(name: "text", data: "한\n글")], "Split UTF-8, CRLF, comments, and multiline data must preserve one complete SSE event.")

        var chat = NativeResponseStreamParser(provider: .chatgpt)
        var updates: [String] = []
        let chatWire = event("response.reasoning_text.delta", #"{"delta":"hidden reasoning"}"#)
            + event("response.output_text.delta", #"{"delta":"안녕"}"#)
            + event("response.output_text.delta", #"{"delta":" world"}"#)
            + event("response.output_text.done", #"{"text":"안녕 world"}"#)
            + event("response.completed", #"{"response":{"output":[{"type":"message","content":[{"type":"output_text","text":"안녕 world"}]}]}}"#)
        try chat.append(Data(chatWire.utf8)) { updates.append($0) }
        try require(try chat.finish() == "안녕 world", "Responses stream must preserve text and exclude reasoning.")
        try require(updates == ["안녕", "안녕 world"], "Done/completed events must not duplicate streamed text.")

        var truncated = NativeResponseStreamParser()
        try truncated.append(Data(event("response.output_text.delta", #"{"delta":"partial"}"#).utf8)) { _ in }
        try rejects("A disconnected stream must never report a partial answer as complete.") { _ = try truncated.finish() }
        var failed = NativeResponseStreamParser()
        try rejects("Provider error events must fail even after text was emitted.") {
            try failed.append(Data((event("response.output_text.delta", #"{"delta":"partial"}"#)
                + event("response.failed", #"{"response":{"error":{"message":"fixture failure"}}}"#)).utf8)) { _ in }
        }

        let token = "synthetic-not-a-real-credential"
        let body = try JSONSerialization.data(withJSONObject: ["error": ["message": "rejected \(token)"]])
        let limit = NativeSubscription.httpFailure(statusCode: 429, retryAfter: "1e300", body: body, accessToken: token)
        try require(limit.statusCode == 429 && limit.retryAfter == nil, "An out-of-range Retry-After must not crash the app or invent a delay.")
        try require(!(limit.localizedDescription.contains(token)), "Provider error details must redact the current access token.")
    }

    static func claudeBehaviorChecksCompileOnly() throws {
        func require(_ condition: Bool, _ message: String) throws {
            if !condition { throw Failure(description: message) }
        }
        func rejects(_ message: String, _ operation: () throws -> Void) throws {
            do { try operation() } catch { return }
            throw Failure(description: message)
        }
        func event(_ name: String, _ json: String) -> String { "event: \(name)\r\ndata: \(json)\r\n\r\n" }

        var claude = NativeResponseStreamParser(provider: .claude)
        let claudeText = event("content_block_delta", #"{"delta":{"type":"thinking_delta","thinking":"hidden"}}"#)
            + event("content_block_delta", #"{"delta":{"type":"text_delta","text":"bonjour"}}"#)
        try claude.append(Data((claudeText
            + event("message_delta", #"{"delta":{"stop_reason":"end_turn"}}"#)
            + event("message_stop", #"{"type":"message_stop"}"#)).utf8)) { _ in }
        try require(try claude.finish() == "bonjour", "Messages stream must expose text only and require message_stop.")
        var limited = NativeResponseStreamParser(provider: .claude)
        try rejects("Output-limit completion is incomplete, not a successful lesson.") {
            try limited.append(Data((claudeText
                + event("message_delta", #"{"delta":{"stop_reason":"max_tokens"}}"#)
                + event("message_stop", #"{"type":"message_stop"}"#)).utf8)) { _ in }
        }
    }
}

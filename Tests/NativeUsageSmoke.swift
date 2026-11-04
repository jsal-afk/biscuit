import Foundation

/// Synthetic ChatGPT-only transport coverage. Never reads an account store or contacts a provider.
enum NativeUsageSmoke {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    private final class FixtureTransport: NativeUsageTransport, @unchecked Sendable {
        let response: NativeUsageHTTPResponse

        init(response: NativeUsageHTTPResponse) {
            self.response = response
        }

        func get(_ request: URLRequest) async throws -> NativeUsageHTTPResponse {
            response
        }
    }

    static func run() async throws {
        func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw Failure(description: message) }
        }

        let reset = 1_800_000_000.0
        let fixture = try JSONSerialization.data(withJSONObject: [
            "plan_type": "plus",
            "rate_limit": [
                "primary_window": ["used_percent": 29.5, "reset_at": reset],
                "secondary_window": ["used_percent": 81, "reset_at": NSNull()]
            ]
        ])
        let transport = FixtureTransport(response: NativeUsageHTTPResponse(
            statusCode: 200, url: NativeUsage.chatGPTEndpoint, data: fixture
        ))
        let token = "synthetic-usage-access-token"
        let access = SubscriptionAccess(accessToken: token, accountID: "synthetic-account-id")
        let snapshot = try await NativeUsage.fetch(provider: .chatgpt, access: access, transport: transport)

        try require(snapshot.windows.count == 2, "Both available native ChatGPT quota windows must be retained.")
        try require(snapshot.windows[0].kind == .primary && abs(snapshot.windows[0].remainingPercent - 70.5) < 0.001,
                    "Remaining usage must be derived from used_percent without confusing the two values.")
        try require(snapshot.windows[0].resetsAt == Date(timeIntervalSince1970: reset),
                    "Epoch reset_at values must be retained exactly.")
        try require(snapshot.windows[1].kind == .secondary && snapshot.windows[1].resetsAt == nil,
                    "An absent secondary reset must remain unknown rather than be fabricated.")


        let chatBody = try NativeSubscription.makeRequestBody(
            provider: .chatgpt,
            text: "public fixture",
            instructions: "translate the public fixture",
            model: NativeSubscription.defaultChatGPTModelID,
            reasoningEffort: .high
        )
        let chatObject = try JSONSerialization.jsonObject(with: chatBody) as? [String: Any]
        let currentModelEntry = MeasurementEntry(
            operation: .translation, outcome: .failed, provider: "chatgpt",
            model: NativeSubscription.defaultChatGPTModelID)
        let historicalModelEntry = MeasurementEntry(
            operation: .translation, outcome: .failed, provider: "chatgpt",
            model: "gpt-5.3-codex")
        try require(currentModelEntry.modelProvenance == .nativeBuiltIn
                    && historicalModelEntry.modelProvenance == .nativeBuiltIn,
                    "Current and retained historical native ChatGPT model identifiers must keep native provenance.")
        let reasoning = chatObject?["reasoning"] as? [String: String]
        try require(reasoning?["effort"] == "high",
                    "The selected reasoning effort must be sent in the native ChatGPT Responses request.")
        let unsupportedChatBody = try NativeSubscription.makeRequestBody(
            provider: .chatgpt,
            text: "public fixture",
            instructions: "translate the public fixture",
            model: "gpt-4.1",
            reasoningEffort: .high
        )
        let unsupportedChatObject = try JSONSerialization.jsonObject(with: unsupportedChatBody) as? [String: Any]
        try require(unsupportedChatObject?["reasoning"] == nil,
                    "The native ChatGPT request must omit effort for unrecognized non-reasoning models.")

        let absentRateLimit = try JSONSerialization.data(withJSONObject: ["plan_type": "plus"])
        let nullRateLimit = try JSONSerialization.data(withJSONObject: [
            "plan_type": "plus",
            "rate_limit": NSNull()
        ])
        let missingWindows = try JSONSerialization.data(withJSONObject: ["rate_limit": [String: Any]()])
        let nullWindows = try JSONSerialization.data(withJSONObject: [
            "rate_limit": [
                "primary_window": NSNull(),
                "secondary_window": NSNull()
            ]
        ])
        for fixture in [absentRateLimit, nullRateLimit, missingWindows, nullWindows] {
            let noUsage = try NativeUsage.parse(provider: .chatgpt, data: fixture)
            try require(noUsage.windows.isEmpty && !noUsage.displayText().isEmpty,
                        "Absent or null native ChatGPT quota windows must remain an honest no-usage state.")
        }

        for invalidValue in [true as Any, "29" as Any] {
            let invalidFixture = try JSONSerialization.data(withJSONObject: [
                "rate_limit": ["primary_window": ["used_percent": invalidValue]]
            ])
            do {
                _ = try NativeUsage.parse(provider: .chatgpt, data: invalidFixture)
                throw Failure(description: "Malformed numeric quota data must not be reported as a percentage.")
            } catch NativeUsageError.malformed(.chatgpt) { }
        }
    }
}

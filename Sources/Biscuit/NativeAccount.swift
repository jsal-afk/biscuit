// OAuth callback validation and grant encoding adapted from OpenAI Codex (Apache-2.0).
// Copyright 2025 OpenAI. Modified for Swift, AppKit and biscuit-owned storage.
// Pin, modification details, LICENSE and NOTICE: Resources/Notices/OpenAICodex/.

import AppKit
import CryptoKit
import Foundation
import Network
import Security
import UniformTypeIdentifiers

// Access handles are not serializable; descriptions intentionally redact secrets.
struct SubscriptionAccess: CustomStringConvertible, CustomDebugStringConvertible, Sendable {
    let accessToken: String
    let accountID: String?

    var description: String { "SubscriptionAccess(accessToken: [redacted], accountID: [provider-owned])" }
    var debugDescription: String { description }
}

enum NativeProvider: String, CaseIterable, Sendable {
    case chatgpt
    case claude

    var title: String { self == .chatgpt ? "ChatGPT" : "Claude" }
}

enum NativeSecureStoreOperation: String {
    case update
    case add
    case read
    case delete
}

enum NativeAccountError: LocalizedError {
    case cancelled
    case callbackUnavailable
    case callbackStateMismatch
    case callbackMissingCode
    case providerDenied
    case signInTimedOut
    case invalidProviderResponse
    case providerRejected(Int)
    case transportFailed
    case refreshRequired
    case missingAccountID
    case codexUnavailable
    case codexUnsupportedAuth
    case codexExpired
    case codexMalformedFile
    case codexFileTokenRejected
    case claudeSignInRequired
    case claudeRefreshRequired
#if BISCUIT_NATIVE_ACCOUNT_QA
    case claudeDisabledInQACandidate
    case taskBrowserUnavailable
    case taskCallbackUnavailable
#endif
    case secureStore(operation: NativeSecureStoreOperation, status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .cancelled: return BiscuitLocalization.string("Sign-in was cancelled.")
        case .callbackUnavailable: return BiscuitLocalization.string("The local sign-in callback could not start. Paste the full redirect URL, or the provider's code#state response, to finish manually.")
        case .callbackStateMismatch: return BiscuitLocalization.string("The sign-in response did not match this request. Start sign-in again.")
        case .callbackMissingCode: return BiscuitLocalization.string("The sign-in response did not contain an authorization code.")
        case .providerDenied: return BiscuitLocalization.string("The provider denied sign-in.")
        case .signInTimedOut: return BiscuitLocalization.string("Sign-in timed out. Start again when ready.")
        case .invalidProviderResponse: return BiscuitLocalization.string("The provider returned an invalid authentication response.")
        case .providerRejected(let status):
            if status == 429 { return BiscuitLocalization.string("The provider is rate limiting authentication. Wait before trying again.") }
            if status == 401 || status == 403 { return BiscuitLocalization.string("The provider rejected authentication. Sign in again or check the selected account.") }
            return BiscuitLocalization.format("The provider authentication request failed (HTTP %d).", arguments: [status])
        case .transportFailed: return BiscuitLocalization.string("The provider could not be reached. Check the network and try again.")
        case .refreshRequired: return BiscuitLocalization.string("The biscuit-owned ChatGPT session expired and cannot be refreshed. Sign in again.")
        case .missingAccountID: return BiscuitLocalization.string("ChatGPT did not provide the workspace account identifier required for native requests.")
        case .codexUnavailable: return BiscuitLocalization.string("The Codex app-server could not be started or did not answer. Select the installed Codex executable, or use file-only auth.json mode.")
        case .codexUnsupportedAuth: return BiscuitLocalization.string("Codex did not return a ChatGPT-managed OAuth access token. Select a ChatGPT account in Codex and reconnect.")
        case .codexExpired: return BiscuitLocalization.string("This Codex auth.json access token is expired or has no verifiable expiry. Reconnect Codex; biscuit never refreshes an imported token.")
        case .codexMalformedFile: return BiscuitLocalization.string("The selected Codex auth.json does not contain a supported ChatGPT OAuth session.")
        case .codexFileTokenRejected: return BiscuitLocalization.string("The selected Codex auth.json token was rejected. biscuit will not refresh it; reconnect Codex or select app-server mode.")
        case .claudeSignInRequired: return BiscuitLocalization.string("Sign in to Claude in biscuit before using native Claude requests.")
        case .claudeRefreshRequired: return BiscuitLocalization.string("The biscuit-owned Claude session expired or was rejected and cannot be refreshed. Sign in again.")
#if BISCUIT_NATIVE_ACCOUNT_QA
        case .claudeDisabledInQACandidate: return "Claude is disabled in the native-account QA candidate."
        case .taskBrowserUnavailable: return "The task-owned browser page could not be confirmed; sign-in was stopped."
        case .taskCallbackUnavailable: return "The task sign-in callback listener could not start; sign-in was stopped."
#endif
        case .secureStore(let operation, let status):
            return BiscuitLocalization.format("biscuit Keychain %1$@ failed (Security status %2$d).", arguments: [operation.rawValue, status])
        }
    }
}

struct NativePKCE {
    let verifier: String
    let challenge: String
    let state: String
}

struct NativeOAuthCredential: Codable, CustomStringConvertible, CustomDebugStringConvertible {
    let accessToken: String
    let refreshToken: String?
    let accountID: String
    let expiresAt: Date

    var description: String { "NativeOAuthCredential(<redacted>)" }
    var debugDescription: String { description }
}

struct ClaudeOAuthCredential: Codable, CustomStringConvertible, CustomDebugStringConvertible {
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date

    var description: String { "ClaudeOAuthCredential(<redacted>)" }
    var debugDescription: String { description }
}

struct NativeDeviceCode {
    let deviceAuthID: String
    let userCode: String
    let interval: TimeInterval
    let verificationURL: URL
}

struct NativeDeviceGrant {
    let authorizationCode: String
    let codeChallenge: String
    let codeVerifier: String
}

enum NativeAccountProtocol {
    static let openAIClientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    static let openAITokenEndpoint = URL(string: "https://auth.openai.com/oauth/token")!
    static let deviceCodeEndpoint = URL(string: "https://auth.openai.com/api/accounts/deviceauth/usercode")!
    static let devicePollEndpoint = URL(string: "https://auth.openai.com/api/accounts/deviceauth/token")!
    static let deviceVerificationURL = URL(string: "https://auth.openai.com/codex/device")!
    static let deviceCallbackURL = "https://auth.openai.com/deviceauth/callback"
    static let authorizationScope = "openid profile email offline_access api.connectors.read api.connectors.invoke"

    static func makePKCE(verifier: String, state: String) -> NativePKCE {
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString
        return NativePKCE(verifier: verifier, challenge: challenge, state: state)
    }

    static func randomPKCE() throws -> NativePKCE {
        func randomValue() throws -> String {
            var bytes = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
                throw NativeAccountError.invalidProviderResponse
            }
            return Data(bytes).base64URLEncodedString
        }
        return makePKCE(verifier: try randomValue(), state: try randomValue())
    }

    static func authorizationURL(pkce: NativePKCE, redirectURI: String, endpoint: URL = URL(string: "https://auth.openai.com/oauth/authorize")!) throws -> URL {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: openAIClientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: authorizationScope),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: pkce.state),
            URLQueryItem(name: "id_token_add_organizations", value: "true"),
            URLQueryItem(name: "codex_cli_simplified_flow", value: "true"),
            URLQueryItem(name: "originator", value: "biscuit")
        ]
        guard let url = components?.url else { throw NativeAccountError.invalidProviderResponse }
        return url
    }

    // Adapted from login/src/oauth/authorization.rs: validate state before consuming
    // either a provider error or a code. Keep biscuit's stricter duplicate rejection.
    static func callbackCode(_ raw: String, expectedState: String) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw NativeAccountError.callbackMissingCode }
        if var components = URLComponents(string: value),
           let scheme = components.scheme, scheme == "http" || scheme == "https" {
            // Rust Url::query_pairs uses form decoding: '+' is space, '%2B' is '+'.
            components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%20")
            let items = components.queryItems ?? []
            let states = items.filter { $0.name == "state" }
            guard states.count == 1, let state = states[0].value,
                  constantTimeEqual(state, expectedState) else {
                throw NativeAccountError.callbackStateMismatch
            }
            if items.contains(where: { $0.name == "error" }) {
                throw NativeAccountError.providerDenied
            }
            let codes = items.filter { $0.name == "code" }
            guard codes.count == 1, let code = codes[0].value, !code.isEmpty else {
                throw NativeAccountError.callbackMissingCode
            }
            return code
        }
        // Retain biscuit's manual callback UI without weakening state validation.
        let parts = value.split(separator: "#", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[1].isEmpty else { throw NativeAccountError.callbackMissingCode }
        guard constantTimeEqual(String(parts[1]), expectedState) else { throw NativeAccountError.callbackStateMismatch }
        guard !parts[0].isEmpty else { throw NativeAccountError.callbackMissingCode }
        return String(parts[0])
    }

    // Adapted from OAuthClient::exchange_code / refresh in login/src/oauth/client.rs.
    // Grants own their encoding; transport, storage and recovery remain with the caller.
    static func authorizationCodeBody(code: String, redirectURI: String, verifier: String) -> Data {
        let parameters = [
            ("grant_type", "authorization_code"), ("client_id", openAIClientID),
            ("code", code), ("redirect_uri", redirectURI), ("code_verifier", verifier)
        ]
        return Data(parameters.map { formEncode($0.0) + "=" + formEncode($0.1) }.joined(separator: "&").utf8)
    }

    static func refreshBody(refreshToken: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token", "client_id": openAIClientID, "refresh_token": refreshToken
        ])
    }

    private static let formAllowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789*-._")

    private static func formEncode(_ value: String) -> String {
        // Match url::form_urlencoded, not URLComponents' generic query encoding.
        value.addingPercentEncoding(withAllowedCharacters: formAllowed)!.replacingOccurrences(of: "%20", with: "+")
    }

    static func deviceCode(from data: Data, verificationURL: URL = deviceVerificationURL) throws -> NativeDeviceCode {
        guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let deviceID = value["device_auth_id"] as? String, !deviceID.isEmpty,
              let userCode = (value["user_code"] as? String ?? value["usercode"] as? String), !userCode.isEmpty
        else { throw NativeAccountError.invalidProviderResponse }
        let interval: TimeInterval
        if let raw = value["interval"] {
            // Codex device_code_auth.rs trims and parses unsigned integer seconds.
            // Never poll faster than requested by capping the provider's interval.
            let seconds: UInt64?
            if let string = raw as? String {
                seconds = UInt64(string.trimmingCharacters(in: .whitespacesAndNewlines))
            } else if let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
                seconds = UInt64(number.stringValue)
            } else {
                seconds = nil
            }
            guard let seconds else { throw NativeAccountError.invalidProviderResponse }
            interval = max(TimeInterval(seconds), 1)
        } else {
            interval = 5
        }
        return NativeDeviceCode(deviceAuthID: deviceID, userCode: userCode, interval: interval, verificationURL: verificationURL)
    }

    static func deviceGrant(from data: Data) throws -> NativeDeviceGrant {
        guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = value["authorization_code"] as? String, !code.isEmpty,
              let challenge = value["code_challenge"] as? String, !challenge.isEmpty,
              let verifier = value["code_verifier"] as? String, !verifier.isEmpty
        else { throw NativeAccountError.invalidProviderResponse }
        let expected = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString
        guard constantTimeEqual(expected, challenge) else { throw NativeAccountError.invalidProviderResponse }
        return NativeDeviceGrant(authorizationCode: code, codeChallenge: challenge, codeVerifier: verifier)
    }

    static func oauthCredential(from data: Data, previousRefreshToken: String? = nil, now: Date = Date()) throws -> NativeOAuthCredential {
        guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = value["access_token"] as? String, !access.isEmpty,
              let lifetime = (value["expires_in"] as? NSNumber)?.doubleValue,
              lifetime.isFinite, lifetime > 0, lifetime <= 31_536_000
        else { throw NativeAccountError.invalidProviderResponse }
        let refresh = (value["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? previousRefreshToken
        let idToken = value["id_token"] as? String ?? ""
        let accountID = accountID(fromJWT: idToken) ?? accountID(fromJWT: access) ?? value["account_id"] as? String
        guard let accountID, !accountID.isEmpty else { throw NativeAccountError.missingAccountID }
        return NativeOAuthCredential(accessToken: access, refreshToken: refresh, accountID: accountID, expiresAt: now.addingTimeInterval(lifetime))
    }

    static func accountID(fromJWT token: String) -> String? {
        guard let payload = jwtPayload(token),
              let auth = payload["https://api.openai.com/auth"] as? [String: Any],
              let account = auth["chatgpt_account_id"] as? String,
              !account.isEmpty, account.trimmingCharacters(in: .whitespacesAndNewlines) == account else { return nil }
        return account
    }

    static func jwtExpiry(from token: String) -> Date? {
        guard let payload = jwtPayload(token), let expiry = payload["exp"] as? NSNumber,
              expiry.doubleValue.isFinite else { return nil }
        return Date(timeIntervalSince1970: expiry.doubleValue)
    }

    static func codexFileAccess(from data: Data, now: Date = Date()) throws -> SubscriptionAccess {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NativeAccountError.codexMalformedFile
        }
        if let rawMode = root["auth_mode"], !(rawMode is NSNull) {
            guard let mode = rawMode as? String, mode == "chatgpt" else { throw NativeAccountError.codexUnsupportedAuth }
        } else {
            let hasOtherAuth =
                (root["personal_access_token"] != nil && !(root["personal_access_token"] is NSNull)) ||
                (root["bedrock_api_key"] != nil && !(root["bedrock_api_key"] is NSNull)) ||
                (root["bedrock_access_keys"] != nil && !(root["bedrock_access_keys"] is NSNull)) ||
                (root["OPENAI_API_KEY"] != nil && !(root["OPENAI_API_KEY"] is NSNull))
            guard !hasOtherAuth else { throw NativeAccountError.codexUnsupportedAuth }
        }
        guard let tokens = root["tokens"] as? [String: Any] else { throw NativeAccountError.codexUnsupportedAuth }
        guard let access = tokens["access_token"] as? String, !access.isEmpty else {
            throw NativeAccountError.codexMalformedFile
        }
        guard let expiry = jwtExpiry(from: access), expiry.timeIntervalSince(now) > 30 else {
            throw NativeAccountError.codexExpired
        }
        let account = (root["account_id"] as? String) ?? (tokens["account_id"] as? String) ?? accountID(fromJWT: access)
        guard let account, !account.isEmpty else { throw NativeAccountError.missingAccountID }
        return SubscriptionAccess(accessToken: access, accountID: account)
    }

    static func codexAppServerAccess(from data: Data) throws -> SubscriptionAccess {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [String: Any],
              result["authMethod"] as? String == "chatgpt",
              let access = result["authToken"] as? String, !access.isEmpty else {
            throw NativeAccountError.codexUnsupportedAuth
        }
        guard let account = accountID(fromJWT: access) else { throw NativeAccountError.missingAccountID }
        return SubscriptionAccess(accessToken: access, accountID: account)
    }


    static func constantTimeEqual(_ left: String, _ right: String) -> Bool {
        let a = Array(left.utf8), b = Array(right.utf8)
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for index in a.indices { difference |= a[index] ^ b[index] }
        return difference == 0
    }

    private static func jwtPayload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, !parts[1].isEmpty,
              let data = Data(base64URLString: String(parts[1])),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json
    }
}
enum NativeClaudeOAuthProtocol {
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let signInScopes = [
        "user:profile",
        "user:inference",
        "user:sessions:claude_code",
        "user:mcp_servers",
        "user:file_upload"
    ]
    static let scope = signInScopes.joined(separator: " ")
    static let messagesBeta = "oauth-2025-04-20"
    static let tokenEndpoint = URL(string: "https://platform.claude.com/v1/oauth/token")!
    static let authorizationEndpoint = URL(string: "https://claude.ai/oauth/authorize")!
    static let manualCallback = URL(string: "https://platform.claude.com/oauth/code/callback")!

    static func randomPKCE() throws -> NativePKCE {
        try NativeAccountProtocol.randomPKCE()
    }

    static func authorizationURL(
        pkce: NativePKCE,
        redirectURI: String,
        endpoint: URL = authorizationEndpoint
    ) throws -> URL {
        guard endpoint.scheme?.lowercased() == "https", endpoint.user == nil, endpoint.password == nil,
              !redirectURI.isEmpty else { throw NativeAccountError.invalidProviderResponse }
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw NativeAccountError.invalidProviderResponse
        }
        components.queryItems = (components.queryItems ?? []) + [
            URLQueryItem(name: "code", value: "true"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: pkce.state)
        ]
        guard let url = components.url else { throw NativeAccountError.invalidProviderResponse }
        return url
    }

    static func callbackCode(_ raw: String, expectedState: String, redirectURI: String) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw NativeAccountError.callbackMissingCode }

        if !value.contains("://") {
            let parts = value.split(separator: "#", omittingEmptySubsequences: false)
            guard parts.count == 2, isOpaque(String(parts[0])), isOpaque(String(parts[1])) else {
                throw NativeAccountError.callbackMissingCode
            }
            let state = String(parts[1])
            guard NativeAccountProtocol.constantTimeEqual(state, expectedState) else {
                throw NativeAccountError.callbackStateMismatch
            }
            return String(parts[0])
        }

        guard let callback = URLComponents(string: value),
              let expected = URLComponents(string: redirectURI),
              let expectedScheme = expected.scheme?.lowercased(),
              let expectedHost = expected.host?.lowercased(),
              !expectedHost.isEmpty,
              expected.query == nil, expected.fragment == nil,
              callback.scheme?.lowercased() == expectedScheme,
              callback.host?.lowercased() == expectedHost,
              callback.port == expected.port,
              callback.percentEncodedPath == expected.percentEncodedPath,
              callback.user == nil, callback.password == nil, callback.fragment == nil,
              expected.user == nil, expected.password == nil,
              let items = callback.queryItems else {
            throw NativeAccountError.callbackStateMismatch
        }
        let names = items.map(\.name)
        guard Set(names).count == names.count else { throw NativeAccountError.invalidProviderResponse }
        let states = items.filter { $0.name == "state" }
        let codes = items.filter { $0.name == "code" }
        let errors = items.filter { $0.name == "error" }
        guard states.count == 1, let state = states[0].value, isOpaque(state),
              NativeAccountProtocol.constantTimeEqual(state, expectedState) else {
            throw NativeAccountError.callbackStateMismatch
        }
        if !errors.isEmpty {
            guard errors.count == 1, let error = errors[0].value, isOpaque(error) else {
                throw NativeAccountError.invalidProviderResponse
            }
            throw NativeAccountError.providerDenied
        }
        guard codes.count == 1, let code = codes[0].value, isOpaque(code) else {
            throw NativeAccountError.callbackMissingCode
        }
        return code
    }

    static func authorizationCodeBody(code: String, redirectURI: String, verifier: String, state: String) throws -> Data {
        guard isOpaque(code), isOpaque(verifier), isOpaque(state), !redirectURI.isEmpty else {
            throw NativeAccountError.invalidProviderResponse
        }
        return try JSONSerialization.data(withJSONObject: [
            "grant_type": "authorization_code",
            "client_id": clientID,
            "code": code,
            "redirect_uri": redirectURI,
            "code_verifier": verifier,
            "state": state
        ])
    }

    static func refreshBody(refreshToken: String) throws -> Data {
        guard isOpaque(refreshToken) else { throw NativeAccountError.invalidProviderResponse }
        return try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
            "scope": scope
        ])
    }

    static func credential(
        from data: Data,
        previousRefreshToken: String? = nil,
        now: Date = Date()
    ) throws -> ClaudeOAuthCredential {
        guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = value["access_token"] as? String, isOpaque(access),
              let lifetime = (value["expires_in"] as? NSNumber)?.doubleValue,
              lifetime.isFinite, lifetime > 0, lifetime <= 31_536_000 else {
            throw NativeAccountError.invalidProviderResponse
        }
        let refresh: String?
        if let raw = value["refresh_token"], !(raw is NSNull) {
            guard let token = raw as? String else { throw NativeAccountError.invalidProviderResponse }
            if token.isEmpty {
                refresh = previousRefreshToken
            } else {
                guard isOpaque(token) else { throw NativeAccountError.invalidProviderResponse }
                refresh = token
            }
        } else {
            refresh = previousRefreshToken
        }
        if let refresh, !isOpaque(refresh) { throw NativeAccountError.invalidProviderResponse }
        return ClaudeOAuthCredential(accessToken: access, refreshToken: refresh, expiresAt: now.addingTimeInterval(lifetime))
    }

    private static func isOpaque(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 16_384
            && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}

struct NativeAccountEndpoints {
    let authorization: URL
    let token: URL
    let deviceCode: URL
    let devicePoll: URL
    let deviceVerification: URL
    let deviceCallback: String

    static let openAI = NativeAccountEndpoints(
        authorization: URL(string: "https://auth.openai.com/oauth/authorize")!,
        token: NativeAccountProtocol.openAITokenEndpoint,
        deviceCode: NativeAccountProtocol.deviceCodeEndpoint,
        devicePoll: NativeAccountProtocol.devicePollEndpoint,
        deviceVerification: NativeAccountProtocol.deviceVerificationURL,
        deviceCallback: NativeAccountProtocol.deviceCallbackURL
    )
}
struct NativeClaudeAccountEndpoints {
    let authorization: URL
    let token: URL
    let manualCallback: URL

    static let standard = NativeClaudeAccountEndpoints(
        authorization: NativeClaudeOAuthProtocol.authorizationEndpoint,
        token: NativeClaudeOAuthProtocol.tokenEndpoint,
        manualCallback: NativeClaudeOAuthProtocol.manualCallback
    )
}

enum NativeHTTPIdentity {
    static var userAgent: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        return "biscuit/\(version)"
    }
}

enum NativeAccountSettingsKey {
    static let codexMode = "account.codex.mode"
    static let codexFile = "account.codex.file"
    static let codexExecutable = "account.codex.executable"
    static let chatGPTSession = "chatgpt.oauth"
    static let claudeSession = "claude.oauth"
    static let claudeKeychainService = "org.biscuit.app.native-account.claude"
#if BISCUIT_NATIVE_ACCOUNT_QA
    static let qaBundleIdentifier = "org.biscuit.qa.nativeaccount.chromium.20261103"
    static let qaKeychainService = "org.biscuit.qa.native-account.chromium.20261103.task-only"
    static let qaPreferencesSuite = "org.biscuit.qa.nativeaccount.chromium.preferences.20261103"
#endif
}

extension Data {
    var base64URLEncodedString: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLString: String) {
        var value = base64URLString.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        if value.count % 4 != 0 { value += String(repeating: "=", count: 4 - value.count % 4) }
        self.init(base64Encoded: value)
    }
}

protocol NativeSecretStore: Sendable {
    func read(_ key: String) throws -> Data?
    func contains(_ key: String) throws -> Bool
    func write(_ data: Data, for key: String) throws
    func delete(_ key: String) throws
}

struct NativeKeychainBackend {
    let copyMatching: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>) -> OSStatus
    let update: (CFDictionary, CFDictionary) -> OSStatus
    let add: (CFDictionary) -> OSStatus
    let delete: (CFDictionary) -> OSStatus

    static let security = NativeKeychainBackend(
        copyMatching: { SecItemCopyMatching($0, $1) },
        update: { SecItemUpdate($0, $1) },
        add: { SecItemAdd($0, nil) },
        delete: { SecItemDelete($0) }
    )
}


final class NativeKeychainStore: NativeSecretStore, @unchecked Sendable {
    private let service: String
    private let backend: NativeKeychainBackend

    init(service: String = "org.biscuit.app.native-account", backend: NativeKeychainBackend = .security) {
        self.service = service
        self.backend = backend
    }

    func read(_ key: String) throws -> Data? {
        var query = baseQuery(key)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = backend.copyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw NativeAccountError.secureStore(operation: .read, status: status) }
        return result as? Data
    }
    func contains(_ key: String) throws -> Bool {
        var query = baseQuery(key)
        query[kSecReturnAttributes] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = backend.copyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else { throw NativeAccountError.secureStore(operation: .read, status: status) }
        return true
    }

    func write(_ data: Data, for key: String) throws {
        let query = baseQuery(key)
        // The default macOS ACL trusts the creator; rewriting an ACL prompts on every refresh.
        let attributes: [CFString: Any] = [kSecValueData: data]
        let status = backend.update(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw NativeAccountError.secureStore(operation: .update, status: status) }
        var add = query
        add.merge(attributes) { _, replacement in replacement }
        let inserted = backend.add(add as CFDictionary)
        guard inserted == errSecSuccess else { throw NativeAccountError.secureStore(operation: .add, status: inserted) }
    }


    func delete(_ key: String) throws {
        let status = backend.delete(baseQuery(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw NativeAccountError.secureStore(operation: .delete, status: status) }
    }

    private func baseQuery(_ key: String) -> [CFString: Any] {
        // Use the login Keychain for ad-hoc releases; its ACL is bound to this executable.
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: key, kSecUseDataProtectionKeychain: false]
    }

}

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

protocol NativeAccountHTTPTransport: Sendable {
    func post(_ url: URL, body: Data, contentType: String, timeout: TimeInterval) async throws -> Data
}


final class NativeURLSessionTransport: NativeAccountHTTPTransport, @unchecked Sendable {
    private let session: URLSession

    init() {
        session = URLSession(configuration: .ephemeral, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }

    func post(_ url: URL, body: Data, contentType: String, timeout: TimeInterval = 30) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(NativeHTTPIdentity.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = body
        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw NativeAccountError.transportFailed }
            guard (200..<300).contains(response.statusCode) else { throw NativeAccountError.providerRejected(response.statusCode) }
            return data
        } catch let error as NativeAccountError { throw error }
        catch is CancellationError { throw CancellationError() }
        catch { throw NativeAccountError.transportFailed }
    }
}

@MainActor
private final class OAuthCallbackServer {
    private let queue = DispatchQueue(label: "org.biscuit.app.oauth-callback")
    private var listener: NWListener?
    private var onCode: ((Result<String, Error>) -> Void)?
    private var callbackPath = "/auth/callback"
    private var callbackHost = "127.0.0.1"
    private var validator: ((String, String, String) throws -> String)?
    private var startAttempt: UUID?
    private var startContinuation: CheckedContinuation<Void, Error>?

    func start(
        state: String,
        callbackPath: String = "/auth/callback",
        callbackHost: String = "127.0.0.1",
        fixedPorts: [UInt16]? = [1455, 1457],
        validator: ((String, String, String) throws -> String)? = nil,
        onCode: @escaping (Result<String, Error>) -> Void
    ) async -> URL? {
        let candidatePorts: [UInt16?] = fixedPorts?.map { Optional($0) } ?? [nil]
        for portValue in candidatePorts {
            do {
                let parameters = NWParameters.tcp
                let port = portValue.flatMap { NWEndpoint.Port(rawValue: $0) } ?? .any
                parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port)
                let listener = try NWListener(using: parameters)
                self.listener = listener
                self.onCode = onCode
                self.callbackPath = callbackPath
                self.callbackHost = callbackHost
                self.validator = validator
                listener.newConnectionHandler = { [weak self] connection in
                    Task { @MainActor [weak self] in self?.receive(connection, state: state) }
                }
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    let attempt = UUID()
                    startAttempt = attempt
                    startContinuation = continuation
                    listener.stateUpdateHandler = { [weak self] state in
                        Task { @MainActor [weak self] in self?.completeStart(state, attempt: attempt) }
                    }
                    listener.start(queue: queue)
                }
                guard let boundPort = listener.port?.rawValue else {
                    listener.cancel()
                    self.listener = nil
                    return nil
                }
                return URL(string: "http://\(callbackHost):\(boundPort)\(callbackPath)")
            } catch {
                listener?.cancel()
                listener = nil
                self.onCode = nil
                self.validator = nil
            }
        }
        return nil
    }

    private func completeStart(_ state: NWListener.State, attempt: UUID) {
        guard startAttempt == attempt, let continuation = startContinuation else { return }
        switch state {
        case .ready:
            startAttempt = nil
            startContinuation = nil
            continuation.resume()
        case .failed, .cancelled:
            startAttempt = nil
            startContinuation = nil
            continuation.resume(throwing: NativeAccountError.callbackUnavailable)
        default: break
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        onCode = nil
        validator = nil
    }

    private func receive(_ connection: NWConnection, state: String) {
        connection.start(queue: queue)
        read(connection, data: Data(), state: state)
    }

    private func read(_ connection: NWConnection, data: Data, state: String) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] received, _, complete, error in
            let combined = data + (received ?? Data())
            let failed = complete || error != nil
            Task { @MainActor [weak self] in self?.handle(connection, data: combined, state: state, failed: failed) }
        }
    }

    private func handle(_ connection: NWConnection, data: Data, state: String, failed: Bool) {
        if let range = data.range(of: Data("\r\n\r\n".utf8)) {
            guard let header = String(data: data[..<range.lowerBound], encoding: .utf8),
                  let line = header.components(separatedBy: "\r\n").first else {
                reply(connection, code: 400, message: "Invalid sign-in callback.")
                return
            }
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count == 3, parts[0] == "GET", parts[2].hasPrefix("HTTP/1."),
                  parts[1].hasPrefix("/"), !parts[1].hasPrefix("//"),
                  let port = listener?.port?.rawValue,
                  let url = URL(string: "http://\(callbackHost):\(port)\(parts[1])"),
                  url.path == callbackPath else {
                reply(connection, code: 400, message: "Invalid sign-in callback.")
                return
            }
            do {
                let code: String
                if let validator {
                    code = try validator(url.absoluteString, state, "http://\(callbackHost):\(port)\(callbackPath)")
                } else {
                    code = try NativeAccountProtocol.callbackCode(url.absoluteString, expectedState: state)
                }
                reply(connection, code: 200, message: "Sign-in complete. You may close this window.")
                onCode?(.success(code))
            } catch NativeAccountError.callbackStateMismatch {
                reply(connection, code: 400, message: "Sign-in response did not match this request.")
            } catch {
                reply(connection, code: 400, message: "Sign-in could not be completed.")
                onCode?(.failure(error))
            }
        } else if data.count >= 16_384 || failed {
            reply(connection, code: 400, message: "Invalid sign-in callback.")
        } else {
            read(connection, data: data, state: state)
        }
    }

    private func reply(_ connection: NWConnection, code: Int, message: String) {
        let body = Data("<!doctype html><html><body><p>\(message)</p></body></html>".utf8)
        let reason = code == 200 ? "OK" : code == 404 ? "Not Found" : "Bad Request"
        let header = "HTTP/1.1 \(code) \(reason)\r\nContent-Type: text/html; charset=utf-8\r\nConnection: close\r\nContent-Length: \(body.count)\r\n\r\n"
        connection.send(content: Data(header.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }
}
@MainActor
final class NativeAccountController {
    static let shared: NativeAccountController = {
#if BISCUIT_NATIVE_ACCOUNT_QA
        let store = NativeKeychainStore(service: NativeAccountSettingsKey.qaKeychainService)
        let environment = ProcessInfo.processInfo.environment
        let openURL = NativeAccountQABrowserOpener.makeOpenURL(
            bindingFileURL: environment["BISCUIT_NATIVE_ACCOUNT_QA_BINDING"].map { URL(fileURLWithPath: $0) },
            expectedProfilePath: environment["BISCUIT_NATIVE_ACCOUNT_QA_PROFILE"],
            expectedBrowserPath: environment["BISCUIT_NATIVE_ACCOUNT_QA_BROWSER"],
            expectedBrowserVersion: environment["BISCUIT_NATIVE_ACCOUNT_QA_BROWSER_VERSION"],
            clientID: NativeAccountProtocol.openAIClientID,
            scope: NativeAccountProtocol.authorizationScope
        )
        return NativeAccountController(store: store, claudeStore: store, defaults: BiscuitPreferences.defaults, openURL: openURL)
#else
        return NativeAccountController()
#endif
    }()

    private let store: NativeSecretStore
    private let claudeStore: NativeSecretStore
    private let transport: NativeAccountHTTPTransport
    private let endpoints: NativeAccountEndpoints
    private let claudeEndpoints: NativeClaudeAccountEndpoints
    private let defaults: UserDefaults
    private let openURL: (URL) -> Bool
    private let codexModeKey = NativeAccountSettingsKey.codexMode
    private let codexFileKey = NativeAccountSettingsKey.codexFile
    private let codexExecutableKey = NativeAccountSettingsKey.codexExecutable
    private let oauthRecordKey = NativeAccountSettingsKey.chatGPTSession
    private let claudeOAuthRecordKey = NativeAccountSettingsKey.claudeSession
    private var window: NSWindow?
    private var selectedProvider: NativeProvider = .chatgpt
    private var statusLabel: NSTextField?
    private var providerPopup: NSPopUpButton?
    private var manualField: NSTextField?
    private var manualSubmit: NSButton?
    private var deviceCodeLabel: NSTextField?
    private var loginTask: Task<Void, Never>?
    private var deviceTask: Task<Void, Never>?
    private var claudeLoginTask: Task<Void, Never>?
    private var pendingOAuth: (generation: UUID, pkce: NativePKCE, redirect: String, server: OAuthCallbackServer?, continuation: CheckedContinuation<String, Error>?, timeout: Task<Void, Never>?)?
    private var pendingClaudeOAuth: (generation: UUID, pkce: NativePKCE, redirect: String, server: OAuthCallbackServer?, continuation: CheckedContinuation<String, Error>?, timeout: Task<Void, Never>?)?
    private var deviceCode: String?
    private var accessTasks: [NativeProvider: (UUID, UUID, Task<SubscriptionAccess, Error>)] = [:]
    private var accountGeneration: [NativeProvider: UUID] = [:]
    private var credentialGeneration = UUID()
    private var claudeCredentialGeneration = UUID()
    private var forceChatGPTRefresh = false
    private var forceClaudeRefresh = false
    private var rejectedChatGPTToken: String?
    private var rejectedClaudeToken: String?
    private var rejectedCodexFileToken: String?
    private var appViews: [NSView] = []
    private var claudeViews: [NSView] = []
    private var statusText = "Choose an account provider. Sign-in starts only when you request it."
    private var claudeStatusText: String?

    init(
        store: NativeSecretStore? = nil,
        claudeStore: NativeSecretStore? = nil,
        transport: NativeAccountHTTPTransport = NativeURLSessionTransport(),
        endpoints: NativeAccountEndpoints = .openAI,
        claudeEndpoints: NativeClaudeAccountEndpoints = .standard,
        defaults: UserDefaults = BiscuitPreferences.defaults,
        openURL: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }
    ) {
        let resolvedStore: NativeSecretStore
        if let store {
            resolvedStore = store
        } else {
#if BISCUIT_NATIVE_ACCOUNT_QA
            resolvedStore = NativeKeychainStore(service: NativeAccountSettingsKey.qaKeychainService)
#else
            resolvedStore = NativeKeychainStore()
#endif
        }
        let resolvedClaudeStore: NativeSecretStore
        if let claudeStore {
            resolvedClaudeStore = claudeStore
        } else {
#if BISCUIT_NATIVE_ACCOUNT_QA
            resolvedClaudeStore = resolvedStore
#else
            if resolvedStore is NativeKeychainStore {
                resolvedClaudeStore = NativeKeychainStore(service: NativeAccountSettingsKey.claudeKeychainService)
            } else {
                resolvedClaudeStore = resolvedStore
            }
#endif
        }
        self.store = resolvedStore
        self.claudeStore = resolvedClaudeStore
        self.transport = transport
        self.endpoints = endpoints
        self.claudeEndpoints = claudeEndpoints
        self.defaults = defaults
        self.openURL = openURL
    }

    func showSettings(provider: NativeProvider = .chatgpt) {
#if BISCUIT_NATIVE_ACCOUNT_QA
        guard provider == .chatgpt else { return }
#endif
        if selectedProvider != provider {
            cancelLogin(for: selectedProvider)
            selectedProvider = provider
        }
        if window == nil { buildWindow() }
        providerPopup?.selectItem(withTitle: provider.title)
        updateWindow()
        guard BiscuitPresentation.show(window) else { return }
        NSApp.activate(ignoringOtherApps: true)
    }

    func access(provider: NativeProvider = .chatgpt) async throws -> SubscriptionAccess {
#if BISCUIT_NATIVE_ACCOUNT_QA
        guard provider == .chatgpt else { throw NativeAccountError.claudeDisabledInQACandidate }
#endif
        try Task.checkCancellation()
        let generation = accountGeneration[provider] ?? UUID()
        accountGeneration[provider] = generation
        if let current = accessTasks[provider], current.1 == generation {
            let access = try await current.2.value
            try Task.checkCancellation()
            return access
        }
        let id = UUID()
        let credentialGeneration = provider == .claude ? claudeCredentialGeneration : self.credentialGeneration
        let task = Task { [weak self] () throws -> SubscriptionAccess in
            guard let self else { throw NativeAccountError.cancelled }
            let result = try await self.resolve(provider: provider, generation: generation, credentialGeneration: credentialGeneration)
            guard self.accountGeneration[provider] == generation else { throw NativeAccountError.cancelled }
            return result
        }
        accessTasks[provider] = (id, generation, task)
        defer { if accessTasks[provider]?.0 == id { accessTasks[provider] = nil } }
        let access = try await task.value
        try Task.checkCancellation()
        return access
    }

    func invalidateAccess(provider: NativeProvider = .chatgpt) {
        invalidateAccess(provider: provider, usedToken: nil)
    }

    func invalidateAccess(provider: NativeProvider, usedToken: String?) {
#if BISCUIT_NATIVE_ACCOUNT_QA
        guard provider == .chatgpt else { return }
        if let usedToken {
            guard let current = try? loadCredential(), current.accessToken == usedToken else { return }
            rejectedChatGPTToken = usedToken
            forceChatGPTRefresh = false
        } else {
            forceChatGPTRefresh = true
        }
#else
        if provider == .claude {
            if let usedToken {
                guard let current = try? loadClaudeCredential(), current.accessToken == usedToken else { return }
                rejectedClaudeToken = usedToken
                forceClaudeRefresh = false
            } else {
                forceClaudeRefresh = true
            }
            return
        }
        guard provider == .chatgpt else { return }
        switch defaults.string(forKey: codexModeKey) {
        case "app-server": return
        case "file-only":
            guard let usedToken, let current = try? codexFileAccess(), current.accessToken == usedToken else { return }
            rejectedCodexFileToken = usedToken
            return
        default: break
        }
        if let usedToken {
            guard let current = try? loadCredential(), current.accessToken == usedToken else { return }
            rejectedChatGPTToken = usedToken
            forceChatGPTRefresh = false
        } else {
            forceChatGPTRefresh = true
        }
#endif
    }
    private func cancelAccessTask(for provider: NativeProvider) {
        guard let active = accessTasks.removeValue(forKey: provider) else { return }
        active.2.cancel()
    }

    func disconnect(provider: NativeProvider = .chatgpt) {
#if BISCUIT_NATIVE_ACCOUNT_QA
        guard provider == .chatgpt else { return }
        cancelAccessTask(for: provider)
        signOutOwnedChatGPT()
#else
        cancelAccessTask(for: provider)
        switch provider {
        case .claude: disconnectClaude()
        case .chatgpt:
            if defaults.string(forKey: codexModeKey) == "app-server" || defaults.string(forKey: codexModeKey) == "file-only" {
                disconnectCodex()
            } else {
                signOutOwnedChatGPT()
            }
        }
#endif
    }

    func cancelLogin() {
        cancelLogin(for: selectedProvider)
    }

    private func cancelLogin(for provider: NativeProvider) {
        if provider == .claude {
            let active = claudeLoginTask != nil || pendingClaudeOAuth != nil
            claudeLoginTask?.cancel()
            claudeLoginTask = nil
            if active {
                accountGeneration[.claude] = UUID()
                claudeCredentialGeneration = UUID()
                claudeStatusText = "Claude sign-in was cancelled. Any saved session remains unchanged."
            }
            if let pending = pendingClaudeOAuth {
                pending.timeout?.cancel()
                pending.server?.stop()
                pending.continuation?.resume(throwing: NativeAccountError.cancelled)
            }
            pendingClaudeOAuth = nil
            updateWindow()
            return
        }
        let active = loginTask != nil || deviceTask != nil || pendingOAuth != nil
        loginTask?.cancel(); loginTask = nil
        deviceTask?.cancel(); deviceTask = nil
        if active {
            accountGeneration[.chatgpt] = UUID()
            credentialGeneration = UUID()
        }
        if let pending = pendingOAuth {
            pending.timeout?.cancel()
            pending.server?.stop()
            pending.continuation?.resume(throwing: NativeAccountError.cancelled)
        }
        pendingOAuth = nil
        deviceCode = nil
        updateWindow()
    }

    private func resolve(provider: NativeProvider, generation: UUID, credentialGeneration: UUID) async throws -> SubscriptionAccess {
        guard accountGeneration[provider] == generation else { throw NativeAccountError.cancelled }
        switch provider {
        case .claude:
#if BISCUIT_NATIVE_ACCOUNT_QA
            throw NativeAccountError.claudeDisabledInQACandidate
#else
            return try await appOwnedClaudeAccess(credentialGeneration: credentialGeneration)
#endif
        case .chatgpt:
#if BISCUIT_NATIVE_ACCOUNT_QA
            return try await appOwnedChatGPTAccess(credentialGeneration: credentialGeneration)
#else
            switch defaults.string(forKey: codexModeKey) {
            case "app-server": return try await CodexAppServerAccess.read(executable: codexExecutable())
            case "file-only":
                let access = try codexFileAccess()
                guard access.accessToken != rejectedCodexFileToken else { throw NativeAccountError.codexFileTokenRejected }
                rejectedCodexFileToken = nil
                return access
            default: return try await appOwnedChatGPTAccess(credentialGeneration: credentialGeneration)
            }
#endif
        }
    }
    private func codexFileAccess() throws -> SubscriptionAccess {
        guard let path = defaults.string(forKey: codexFileKey), !path.isEmpty else { throw NativeAccountError.codexMalformedFile }
        let data: Data
        do { data = try Data(contentsOf: URL(fileURLWithPath: path), options: [.mappedIfSafe]) }
        catch { throw NativeAccountError.codexMalformedFile }
        return try NativeAccountProtocol.codexFileAccess(from: data)
    }

    private func appOwnedChatGPTAccess(credentialGeneration: UUID) async throws -> SubscriptionAccess {
        let credential = try loadCredential()
        let forced = forceChatGPTRefresh || credential.accessToken == rejectedChatGPTToken
        if !forced, credential.expiresAt.timeIntervalSinceNow > 60 {
            return SubscriptionAccess(accessToken: credential.accessToken, accountID: credential.accountID)
        }
        guard let refresh = credential.refreshToken, !refresh.isEmpty else { throw NativeAccountError.refreshRequired }
        let body = try NativeAccountProtocol.refreshBody(refreshToken: refresh)
        let data: Data
        do {
            data = try await transport.post(endpoints.token, body: body, contentType: "application/json", timeout: 30)
        } catch NativeAccountError.transportFailed {
            guard self.credentialGeneration == credentialGeneration else { throw NativeAccountError.cancelled }
            guard !forced, credential.accessToken != rejectedChatGPTToken, credential.expiresAt > Date() else {
                throw NativeAccountError.transportFailed
            }
            return SubscriptionAccess(accessToken: credential.accessToken, accountID: credential.accountID)
        }
        let updated = try NativeAccountProtocol.oauthCredential(from: data, previousRefreshToken: refresh)
        guard self.credentialGeneration == credentialGeneration else { throw NativeAccountError.cancelled }
        try store.write(JSONEncoder().encode(updated), for: oauthRecordKey)
        forceChatGPTRefresh = false
        rejectedChatGPTToken = nil
        return SubscriptionAccess(accessToken: updated.accessToken, accountID: updated.accountID)
    }

    private func appOwnedClaudeAccess(credentialGeneration: UUID) async throws -> SubscriptionAccess {
        let credential = try loadClaudeCredential()
        let forced = forceClaudeRefresh || credential.accessToken == rejectedClaudeToken
        let timeRemaining = credential.expiresAt.timeIntervalSinceNow
        let refreshAvailable = credential.refreshToken.map { !$0.isEmpty } ?? false
        if !forced, timeRemaining > 0, (timeRemaining > 60 || !refreshAvailable) {
            return SubscriptionAccess(accessToken: credential.accessToken, accountID: nil)
        }
        guard let refresh = credential.refreshToken, !refresh.isEmpty else {
            throw NativeAccountError.claudeRefreshRequired
        }
        let body = try NativeClaudeOAuthProtocol.refreshBody(refreshToken: refresh)
        let data: Data
        do {
            data = try await transport.post(claudeEndpoints.token, body: body, contentType: "application/json", timeout: 30)
        } catch NativeAccountError.transportFailed {
            guard self.claudeCredentialGeneration == credentialGeneration else { throw NativeAccountError.cancelled }
            guard !forced, credential.accessToken != rejectedClaudeToken, credential.expiresAt > Date() else {
                throw NativeAccountError.transportFailed
            }
            return SubscriptionAccess(accessToken: credential.accessToken, accountID: nil)
        }
        try Task.checkCancellation()
        let updated = try NativeClaudeOAuthProtocol.credential(from: data, previousRefreshToken: refresh)
        guard self.claudeCredentialGeneration == credentialGeneration else { throw NativeAccountError.cancelled }
        try claudeStore.write(JSONEncoder().encode(updated), for: claudeOAuthRecordKey)
        forceClaudeRefresh = false
        rejectedClaudeToken = nil
        return SubscriptionAccess(accessToken: updated.accessToken, accountID: nil)
    }

    private func loadClaudeCredential() throws -> ClaudeOAuthCredential {
        guard let data = try claudeStore.read(claudeOAuthRecordKey),
              let credential = try? JSONDecoder().decode(ClaudeOAuthCredential.self, from: data),
              !credential.accessToken.isEmpty,
              credential.expiresAt.timeIntervalSince1970.isFinite else {
            throw NativeAccountError.claudeSignInRequired
        }
        return credential
    }

    private func checkClaudeLoginGeneration(_ generation: UUID) throws {
        try Task.checkCancellation()
        guard accountGeneration[.claude] == generation else { throw NativeAccountError.cancelled }
    }

    private func commitClaudeCredential(_ credential: ClaudeOAuthCredential, generation: UUID) throws {
        try checkClaudeLoginGeneration(generation)
        try claudeStore.write(JSONEncoder().encode(credential), for: claudeOAuthRecordKey)
        let committedGeneration = UUID()
        claudeCredentialGeneration = committedGeneration
        accountGeneration[.claude] = committedGeneration
        forceClaudeRefresh = false
        rejectedClaudeToken = nil
    }

    private func loadCredential() throws -> NativeOAuthCredential {
        guard let data = try store.read(oauthRecordKey), let credential = try? JSONDecoder().decode(NativeOAuthCredential.self, from: data) else {
            throw NativeAccountError.refreshRequired
        }
        return credential
    }

    private func checkLoginGeneration(_ generation: UUID) throws {
        try Task.checkCancellation()
        guard accountGeneration[.chatgpt] == generation else { throw NativeAccountError.cancelled }
    }

    private func commitOwnedCredential(_ credential: NativeOAuthCredential, generation: UUID) throws {
        try checkLoginGeneration(generation)
        try store.write(JSONEncoder().encode(credential), for: oauthRecordKey)
        defaults.set("owned", forKey: codexModeKey)
        let committedGeneration = UUID()
        credentialGeneration = committedGeneration
        accountGeneration[.chatgpt] = committedGeneration
        forceChatGPTRefresh = false
        rejectedChatGPTToken = nil
        rejectedCodexFileToken = nil
    }

    @discardableResult
    func beginBrowserLogin() -> Task<Void, Never>? {
#if BISCUIT_NATIVE_ACCOUNT_QA
        guard selectedProvider == .chatgpt else { return nil }
#endif
        switch selectedProvider {
        case .claude: return beginClaudeBrowserLogin()
        case .chatgpt: return beginChatGPTBrowserLogin()
        }
    }

    @discardableResult
    private func beginChatGPTBrowserLogin() -> Task<Void, Never>? {
        cancelLogin(for: .chatgpt)
        credentialGeneration = UUID()
        let generation = UUID()
        accountGeneration[.chatgpt] = generation
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runBrowserLogin(generation: generation)
        }
        loginTask = task
        return task
    }

    @discardableResult
    private func beginClaudeBrowserLogin() -> Task<Void, Never>? {
        cancelLogin(for: .claude)
        claudeCredentialGeneration = UUID()
        forceClaudeRefresh = false
        rejectedClaudeToken = nil
        let generation = UUID()
        accountGeneration[.claude] = generation
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runClaudeBrowserLogin(generation: generation)
        }
        claudeLoginTask = task
        return task
    }

    private func runBrowserLogin(generation: UUID) async {
        let server = OAuthCallbackServer()
        defer { server.stop() }
        do {
            let pkce = try NativeAccountProtocol.randomPKCE()
            let localURL = await server.start(state: pkce.state) { [weak self] result in
                Task { @MainActor [weak self] in self?.finishOAuth(result, generation: generation) }
            }
            try checkLoginGeneration(generation)
#if BISCUIT_NATIVE_ACCOUNT_QA
            guard let callbackURL = localURL else { throw NativeAccountError.taskCallbackUnavailable }
            let redirect = callbackURL.absoluteString
            statusText = "Waiting for ChatGPT sign-in in the task browser."
#else
            let redirect = localURL?.absoluteString ?? "http://127.0.0.1:1455/auth/callback"
            statusText = localURL == nil
                ? "The callback listener is unavailable. Complete sign-in, then paste its full redirect URL or code#state below."
                : "Waiting for ChatGPT sign-in in your browser."
#endif
            let authorization = try NativeAccountProtocol.authorizationURL(pkce: pkce, redirectURI: redirect, endpoint: endpoints.authorization)

            let code = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                let timeout = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: 600_000_000_000) }
                    catch { return }
                    guard !Task.isCancelled, let self,
                          self.accountGeneration[.chatgpt] == generation else { return }
                    self.finishOAuth(.failure(NativeAccountError.signInTimedOut), generation: generation)
                }
                pendingOAuth = (generation, pkce, redirect, localURL == nil ? nil : server, continuation, timeout)
                updateWindow()
                if !openURL(authorization) {
#if BISCUIT_NATIVE_ACCOUNT_QA
                    finishOAuth(.failure(NativeAccountError.taskBrowserUnavailable), generation: generation)
#else
                    statusText = BiscuitLocalization.format("The browser did not open. Copy this sign-in URL into a browser: %@", arguments: [authorization.absoluteString])
                    updateWindow()
#endif
                }
            }
            try checkLoginGeneration(generation)
            let body = NativeAccountProtocol.authorizationCodeBody(code: code, redirectURI: redirect, verifier: pkce.verifier)
            let data = try await transport.post(endpoints.token, body: body, contentType: "application/x-www-form-urlencoded", timeout: 30)
            try checkLoginGeneration(generation)
            let credential = try NativeAccountProtocol.oauthCredential(from: data)
            try commitOwnedCredential(credential, generation: generation)
            statusText = "ChatGPT is connected to biscuit's own secure session."
            loginTask = nil
            updateWindow()
        } catch {
            if accountGeneration[.chatgpt] == generation {
                if !Task.isCancelled { statusText = error.localizedDescription }
                loginTask = nil
                updateWindow()
            }
        }
    }

    private func runClaudeBrowserLogin(generation: UUID) async {
        let server = OAuthCallbackServer()
        defer { server.stop() }
        do {
            let pkce = try NativeClaudeOAuthProtocol.randomPKCE()
            let localURL = await server.start(
                state: pkce.state,
                callbackPath: "/callback",
                callbackHost: "localhost",
                fixedPorts: nil,
                validator: { raw, state, redirect in
                    try NativeClaudeOAuthProtocol.callbackCode(raw, expectedState: state, redirectURI: redirect)
                }
            ) { [weak self] result in
                Task { @MainActor [weak self] in self?.finishClaudeOAuth(result, generation: generation) }
            }
            try checkClaudeLoginGeneration(generation)
            let redirect = localURL?.absoluteString ?? claudeEndpoints.manualCallback.absoluteString
            let authorization = try NativeClaudeOAuthProtocol.authorizationURL(
                pkce: pkce,
                redirectURI: redirect,
                endpoint: claudeEndpoints.authorization
            )
            claudeStatusText = localURL == nil
                ? "The local callback listener is unavailable. Complete Claude sign-in, then paste the exact redirect URL or code#state below."
                : "Waiting for Claude sign-in in your browser."
            let code = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                let timeout = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: 600_000_000_000) }
                    catch { return }
                    guard !Task.isCancelled, let self,
                          self.accountGeneration[.claude] == generation else { return }
                    self.finishClaudeOAuth(.failure(NativeAccountError.signInTimedOut), generation: generation)
                }
                pendingClaudeOAuth = (generation, pkce, redirect, localURL == nil ? nil : server, continuation, timeout)
                updateWindow()
                if !openURL(authorization) {
                    claudeStatusText = BiscuitLocalization.format("The browser did not open. Copy this Claude sign-in URL into a browser: %@", arguments: [authorization.absoluteString])
                    updateWindow()
                }
            }
            try checkClaudeLoginGeneration(generation)
            let body = try NativeClaudeOAuthProtocol.authorizationCodeBody(
                code: code,
                redirectURI: redirect,
                verifier: pkce.verifier,
                state: pkce.state
            )
            let data = try await transport.post(claudeEndpoints.token, body: body, contentType: "application/json", timeout: 30)
            try checkClaudeLoginGeneration(generation)
            let credential = try NativeClaudeOAuthProtocol.credential(from: data)
            try commitClaudeCredential(credential, generation: generation)
            claudeStatusText = "Claude sign-in complete. Session stored securely."
            claudeLoginTask = nil
            updateWindow()
        } catch {
            if accountGeneration[.claude] == generation {
                if !Task.isCancelled { claudeStatusText = error.localizedDescription }
                claudeLoginTask = nil
                updateWindow()
            }
        }
    }

    private func finishClaudeOAuth(_ result: Result<String, Error>, generation: UUID) {
        guard accountGeneration[.claude] == generation,
              let pending = pendingClaudeOAuth, pending.generation == generation,
              let continuation = pending.continuation else { return }
        pendingClaudeOAuth = nil
        pending.timeout?.cancel()
        pending.server?.stop()
        continuation.resume(with: result)
        updateWindow()
    }

    private func finishOAuth(_ result: Result<String, Error>, generation: UUID) {
        guard accountGeneration[.chatgpt] == generation,
              let pending = pendingOAuth, pending.generation == generation,
              let continuation = pending.continuation else { return }
        pendingOAuth = nil
        pending.timeout?.cancel()
        pending.server?.stop()
        continuation.resume(with: result)
        updateWindow()
    }

    @objc private func submitManualCallback() {
#if BISCUIT_NATIVE_ACCOUNT_QA
        return
#else
        guard let raw = manualField?.stringValue else { return }
        switch selectedProvider {
        case .claude:
            guard let pending = pendingClaudeOAuth else { return }
            do {
                let code = try NativeClaudeOAuthProtocol.callbackCode(
                    raw,
                    expectedState: pending.pkce.state,
                    redirectURI: pending.redirect
                )
                finishClaudeOAuth(.success(code), generation: pending.generation)
            } catch {
                guard accountGeneration[.claude] == pending.generation,
                      pendingClaudeOAuth?.generation == pending.generation else { return }
                claudeStatusText = error.localizedDescription
                updateWindow()
            }
        case .chatgpt:
            guard let pending = pendingOAuth else { return }
            do {
                let code = try NativeAccountProtocol.callbackCode(raw, expectedState: pending.pkce.state)
                finishOAuth(.success(code), generation: pending.generation)
            } catch {
                guard accountGeneration[.chatgpt] == pending.generation,
                      pendingOAuth?.generation == pending.generation else { return }
                statusText = error.localizedDescription
                updateWindow()
            }
        }
#endif
    }

    @discardableResult
    func beginDeviceLogin() -> Task<Void, Never>? {
#if BISCUIT_NATIVE_ACCOUNT_QA
        return nil
#else
        guard selectedProvider == .chatgpt else { return nil }
        cancelLogin()
        credentialGeneration = UUID()
        let generation = UUID()
        accountGeneration[.chatgpt] = generation
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runDeviceLogin(generation: generation)
        }
        deviceTask = task
        return task
#endif
    }

    private func runDeviceLogin(generation: UUID) async {
        do {
            let issueBody = try JSONSerialization.data(withJSONObject: ["client_id": NativeAccountProtocol.openAIClientID])
            let issueData = try await transport.post(endpoints.deviceCode, body: issueBody, contentType: "application/json", timeout: 30)
            try checkLoginGeneration(generation)
            let device = try NativeAccountProtocol.deviceCode(from: issueData, verificationURL: endpoints.deviceVerification)
            try checkLoginGeneration(generation)
            deviceCode = device.userCode
            statusText = BiscuitLocalization.format("Enter code %@ at %@. This is the separate Codex device grant, not manual browser-code entry.", arguments: [device.userCode, device.verificationURL.absoluteString])
            updateWindow()
            if !openURL(device.verificationURL) {
                statusText += " " + BiscuitLocalization.string("The browser did not open; use the displayed address and code.")
                updateWindow()
            }
            let deadline = Date().addingTimeInterval(15 * 60)
            while Date() < deadline {
                try checkLoginGeneration(generation)
                let wait = min(device.interval, max(deadline.timeIntervalSinceNow, 0))
                try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                try checkLoginGeneration(generation)
                guard Date() < deadline else { throw NativeAccountError.signInTimedOut }
                let pollBody = try JSONSerialization.data(withJSONObject: ["device_auth_id": device.deviceAuthID, "user_code": device.userCode])
                let pollData: Data
                do {
                    pollData = try await transport.post(endpoints.devicePoll, body: pollBody, contentType: "application/json", timeout: 30)
                } catch NativeAccountError.providerRejected(let status) where status == 403 || status == 404 {
                    try checkLoginGeneration(generation)
                    continue
                }
                try checkLoginGeneration(generation)
                let grant = try NativeAccountProtocol.deviceGrant(from: pollData)
                let body = NativeAccountProtocol.authorizationCodeBody(
                    code: grant.authorizationCode, redirectURI: endpoints.deviceCallback, verifier: grant.codeVerifier
                )
                let tokenData = try await transport.post(endpoints.token, body: body, contentType: "application/x-www-form-urlencoded", timeout: 30)
                try checkLoginGeneration(generation)
                let credential = try NativeAccountProtocol.oauthCredential(from: tokenData)
                try commitOwnedCredential(credential, generation: generation)
                statusText = "ChatGPT is connected to biscuit's own secure session."
                deviceTask = nil
                deviceCode = nil
                updateWindow()
                return
            }
            throw NativeAccountError.signInTimedOut
        } catch {
            if accountGeneration[.chatgpt] == generation {
                if !Task.isCancelled { statusText = error.localizedDescription }
                deviceTask = nil
                deviceCode = nil
                updateWindow()
            }
        }
    }

    private func connectCodexAppServer() {
        cancelLogin(for: .chatgpt)
        let generation = UUID()
        accountGeneration[.chatgpt] = generation
        defaults.removeObject(forKey: codexFileKey)
        rejectedCodexFileToken = nil
        defaults.set("app-server", forKey: codexModeKey)
        statusText = "Checking Codex's current ChatGPT auth through its app-server…"
        updateWindow()
        verifyCodexConnection(generation: generation, success: "Codex connection verified. Codex remains credential owner; biscuit stores no Codex token.")
    }

    private func verifyCodexConnection(generation: UUID, success: String) {
        Task { [weak self] in
            guard let self else { return }
            do { _ = try await self.access(provider: .chatgpt) }
            catch {
                guard self.accountGeneration[.chatgpt] == generation else { return }
                self.statusText = error.localizedDescription
                self.updateWindow()
                return
            }
            guard self.accountGeneration[.chatgpt] == generation else { return }
            self.statusText = success
            self.updateWindow()
        }
    }

    private func chooseCodexExecutable() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = BiscuitLocalization.string("Choose the installed Codex CLI executable. biscuit stores only its path and asks it for current auth; it never calls Codex logout.")
        BiscuitLocalization.applyInterfaceDirection(to: panel)
        BiscuitPresentation.begin(panel, for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor [weak self] in
                guard let self, FileManager.default.isExecutableFile(atPath: url.path) else { return }
                self.defaults.set(url.path, forKey: self.codexExecutableKey)
                self.statusText = "Codex executable selected. Connect through its app-server to use the current Codex-owned session."
                self.updateWindow()
            }
        }
    }

    private func chooseCodexFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.message = BiscuitLocalization.string("Choose Codex auth.json. biscuit stores only the path and rereads an unexpired access token for each request; file reading never refreshes credentials.")
        BiscuitLocalization.applyInterfaceDirection(to: panel)
        BiscuitPresentation.begin(panel, for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.cancelLogin(for: .chatgpt)
                let generation = UUID()
                self.accountGeneration[.chatgpt] = generation
                self.defaults.set(url.path, forKey: self.codexFileKey)
                self.defaults.set("file-only", forKey: self.codexModeKey)
                self.rejectedCodexFileToken = nil
                self.statusText = "Checking the selected Codex auth.json without modifying it…"
                self.updateWindow()
                self.verifyCodexConnection(generation: generation, success: "Codex auth.json is selected read-only. biscuit rereads only an unexpired access token for each request.")
            }
        }
    }

    private func disconnectCodex() {
        cancelLogin(for: .chatgpt)
        accountGeneration[.chatgpt] = UUID()
        defaults.removeObject(forKey: codexModeKey)
        defaults.removeObject(forKey: codexFileKey)
        rejectedCodexFileToken = nil
        statusText = "Codex is disconnected from biscuit. Codex credentials and sign-in were not changed."
        updateWindow()
    }
    private func disconnectClaude() {
        cancelLogin(for: .claude)
        accountGeneration[.claude] = UUID()
        claudeCredentialGeneration = UUID()
        forceClaudeRefresh = false
        rejectedClaudeToken = nil
        do {
            try claudeStore.delete(claudeOAuthRecordKey)
            claudeStatusText = "The biscuit-owned Claude session was removed from its separate Keychain service."
        } catch {
            claudeStatusText = error.localizedDescription
        }
        updateWindow()
    }

    private func signOutOwnedChatGPT() {
        cancelLogin(for: .chatgpt)
        accountGeneration[.chatgpt] = UUID()
        credentialGeneration = UUID()
        do { try store.delete(oauthRecordKey) }
        catch { statusText = error.localizedDescription; updateWindow(); return }
        defaults.removeObject(forKey: codexModeKey)
        rejectedCodexFileToken = nil
        forceChatGPTRefresh = false
        rejectedChatGPTToken = nil
        statusText = "The biscuit-owned ChatGPT session was removed."
        updateWindow()
    }

    private func codexExecutable() -> URL? {
        if let path = defaults.string(forKey: codexExecutableKey), FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        let directories = (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
        for path in directories + ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"] {
            let url = URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent("codex")
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }

    @objc private func providerChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String, let provider = NativeProvider(rawValue: raw) else { return }
#if BISCUIT_NATIVE_ACCOUNT_QA
        guard provider == .chatgpt else { return }
#endif
        if selectedProvider != provider {
            cancelLogin(for: selectedProvider)
            selectedProvider = provider
        }
        updateWindow()
    }

    @objc private func browserAction() { beginBrowserLogin() }
    @objc private func deviceAction() { beginDeviceLogin() }
    @objc private func cancelAction() { cancelLogin() }
    @objc private func codexAction() { connectCodexAppServer() }
    @objc private func codexExecutableAction() { chooseCodexExecutable() }
    @objc private func codexFileAction() { chooseCodexFile() }
    @objc private func codexDisconnectAction() { disconnectCodex() }
    @objc private func signOutAction() { signOutOwnedChatGPT() }
    @objc private func claudeSignOutAction() { disconnect(provider: .claude) }

    @objc private func openDeviceURL() {
#if BISCUIT_NATIVE_ACCOUNT_QA
        _ = openURL(endpoints.deviceVerification)
#else
        _ = NSWorkspace.shared.open(endpoints.deviceVerification)
#endif
    }

    @objc private func copyDeviceCode() {
        guard let deviceCode else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(deviceCode, forType: .string)
    }

    private func buildWindow() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 660), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = BiscuitLocalization.string("biscuit Accounts")
        window.isReleasedWhenClosed = false
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 11
        root.translatesAutoresizingMaskIntoConstraints = false

        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
#if BISCUIT_NATIVE_ACCOUNT_QA
        popup.addItem(withTitle: NativeProvider.chatgpt.title)
        popup.lastItem?.representedObject = NativeProvider.chatgpt.rawValue
#else
        for provider in NativeProvider.allCases {
            popup.addItem(withTitle: provider.title)
            popup.lastItem?.representedObject = provider.rawValue
        }
#endif
        popup.target = self
        popup.action = #selector(providerChanged(_:))
        providerPopup = popup
        root.addArrangedSubview(popup)
        let status = NSTextField(wrappingLabelWithString: statusText)
        status.maximumNumberOfLines = 5
        status.textColor = .secondaryLabelColor
        statusLabel = status
        root.addArrangedSubview(status)

        let ownTitle = label("ChatGPT — biscuit-owned sign-in", bold: true)
        root.addArrangedSubview(ownTitle)
#if BISCUIT_NATIVE_ACCOUNT_QA
        let ownNote = label("Use OpenAI's public Codex PKCE flow. This QA candidate starts only through its task-owned browser page.")
#else
        let ownNote = label("Use OpenAI's public Codex PKCE protocol with biscuit branding. Credentials are stored only in biscuit's Keychain. Device-code login is a distinct provider flow.")
#endif
        ownNote.maximumNumberOfLines = 3
        root.addArrangedSubview(ownNote)
        let browser = button("Sign in with browser", #selector(browserAction))
        let cancel = button("Cancel sign-in", #selector(cancelAction))
#if BISCUIT_NATIVE_ACCOUNT_QA
        for view in [browser, cancel] as [NSView] { root.addArrangedSubview(view) }
#else
        let device = button("Sign in with device code", #selector(deviceAction))
        let manual = NSTextField(string: "")
        manual.placeholderString = BiscuitLocalization.string("Paste full redirect URL or code#state")
        manual.isHidden = true
        manualField = manual
        let submit = button("Complete manual sign-in", #selector(submitManualCallback))
        submit.isHidden = true
        manualSubmit = submit
        let deviceActions = NSStackView()
        deviceActions.orientation = .horizontal
        deviceActions.spacing = 8
        deviceActions.addArrangedSubview(button("Open verification page", #selector(openDeviceURL)))
        deviceActions.addArrangedSubview(button("Copy device code", #selector(copyDeviceCode)))
        let deviceText = NSTextField(labelWithString: "")
        deviceText.isHidden = true
        deviceCodeLabel = deviceText
        for view in [browser, device, cancel, manual, submit, deviceActions, deviceText] as [NSView] { root.addArrangedSubview(view) }
#endif

#if BISCUIT_NATIVE_ACCOUNT_QA
        let chatGPTSignOut = button("Sign out of biscuit's ChatGPT session", #selector(signOutAction))
        root.addArrangedSubview(chatGPTSignOut)
        appViews = [ownTitle, ownNote, browser, cancel, chatGPTSignOut]
#else
        let codexTitle = label("Connect an existing Codex session", bold: true)
        root.addArrangedSubview(codexTitle)
        let codexNote = label("Codex remains credential owner. App-server mode asks Codex for a current ChatGPT bearer and supported refresh on each request. File-only auth.json mode is read-only and cannot refresh expired access.")
        codexNote.maximumNumberOfLines = 4
        let codexConnect = button("Connect through Codex app-server", #selector(codexAction))
        let codexExecutable = button("Choose Codex CLI executable…", #selector(codexExecutableAction))
        let codexFile = button("Choose file-only Codex auth.json…", #selector(codexFileAction))
        let codexDisconnect = button("Disconnect Codex from biscuit", #selector(codexDisconnectAction))
        let chatGPTSignOut = button("Sign out of biscuit's ChatGPT session", #selector(signOutAction))
        for view in [codexConnect, codexExecutable, codexFile, codexDisconnect, chatGPTSignOut] {
            root.addArrangedSubview(view)
        }
        appViews = [ownTitle, ownNote, browser, device, cancel, deviceActions, deviceText, codexTitle, codexNote, codexConnect, codexExecutable, codexFile, codexDisconnect, chatGPTSignOut]
#endif

#if !BISCUIT_NATIVE_ACCOUNT_QA
        let claudeTitle = label("Claude — biscuit-owned subscription sign-in", bold: true)
        let claudeNote = label("Use browser PKCE sign-in for native Claude. OAuth tokens are stored only in biscuit's separate Keychain service. Biscuit never reads Claude Code credentials; remaining usage is retrieved only when you explicitly select Refresh.")
        claudeNote.maximumNumberOfLines = 4
        let claudeBrowser = button("Sign in with browser", #selector(browserAction))
        let claudeCancel = button("Cancel sign-in", #selector(cancelAction))
        let claudeSignOut = button("Sign out of biscuit's Claude session", #selector(claudeSignOutAction))
        for view in [claudeTitle, claudeNote, claudeBrowser, claudeCancel, claudeSignOut] {
            root.addArrangedSubview(view)
        }
        claudeViews = [claudeTitle, claudeNote, claudeBrowser, claudeCancel, claudeSignOut]
#endif
#if BISCUIT_NATIVE_ACCOUNT_QA
        let footer = label("Disconnect affects only biscuit's own ChatGPT session.")
#else
        let footer = label("Disconnect affects only biscuit's own session or selected Codex source pointer. biscuit never logs Codex out, edits its credentials, or inspects another app's source when the account window opens.")
#endif
        footer.maximumNumberOfLines = 4
        footer.textColor = .secondaryLabelColor
        root.addArrangedSubview(footer)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.documentView = root
        scroll.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = scroll
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor, constant: 18),
            root.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor, constant: -18),
            root.topAnchor.constraint(equalTo: scroll.contentView.topAnchor, constant: 18),
            root.bottomAnchor.constraint(equalTo: scroll.contentView.bottomAnchor, constant: -18),
            root.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor, constant: -36)
        ])
        BiscuitLocalization.applyInterfaceDirection(to: window)
        BiscuitPresentation.center(window)
        self.window = window
        updateWindow()
    }

    private func label(_ text: String, bold: Bool = false) -> NSTextField {
        let value = NSTextField(wrappingLabelWithString: BiscuitLocalization.string(text))
        if bold { value.font = .boldSystemFont(ofSize: 13) }
        return value
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let value = NSButton(title: BiscuitLocalization.string(title), target: self, action: action)
        value.bezelStyle = .rounded
        return value
    }

    private func localClaudeSessionStatus() -> String {
        do {
            let saved = try claudeStore.contains(claudeOAuthRecordKey)
            return saved
                ? BiscuitLocalization.string("A saved biscuit-owned Claude session is available.")
                : BiscuitLocalization.string("No saved biscuit-owned Claude session.")
        } catch {
            return BiscuitLocalization.string("Claude session status unavailable.")
        }
    }

    private func updateWindow() {
#if BISCUIT_NATIVE_ACCOUNT_QA
        let statusText = self.statusText
#else
        let statusText = selectedProvider == .claude
            ? (claudeStatusText ?? localClaudeSessionStatus())
            : self.statusText
        let callbackPending = selectedProvider == .claude ? pendingClaudeOAuth != nil : pendingOAuth != nil
#endif
        statusLabel?.stringValue = BiscuitLocalization.string(statusText)
#if BISCUIT_NATIVE_ACCOUNT_QA
        manualField?.isHidden = true
        manualSubmit?.isHidden = true
        deviceCodeLabel?.isHidden = true
        deviceCodeLabel?.stringValue = ""
#else
        manualField?.isHidden = !callbackPending
        manualField?.placeholderString = selectedProvider == .claude
            ? BiscuitLocalization.string("Paste Claude redirect URL or code#state")
            : BiscuitLocalization.string("Paste full redirect URL or code#state")
        manualSubmit?.isHidden = !callbackPending
        manualSubmit?.title = selectedProvider == .claude
            ? BiscuitLocalization.string("Complete Claude sign-in")
            : BiscuitLocalization.string("Complete manual sign-in")
        deviceCodeLabel?.isHidden = selectedProvider != .chatgpt || deviceCode == nil
        deviceCodeLabel?.stringValue = deviceCode.map {
            BiscuitLocalization.format("Device code: %@", arguments: [$0])
        } ?? ""
#endif
        for view in appViews { view.isHidden = selectedProvider != .chatgpt }
        for view in claudeViews { view.isHidden = selectedProvider != .claude }
    }
}


private final class CodexLineReader {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var messages: [[String: Any]] = []
    private var partialLine = Data()
    private var ended = false
    private let handle: FileHandle

    init(_ handle: FileHandle) {
        self.handle = handle
        handle.readabilityHandler = { [weak self] source in
            guard let self else { return }
            let data = source.availableData
            self.lock.lock()
            if data.isEmpty {
                self.ended = true
                self.semaphore.signal()
            } else {
                self.partialLine.append(data)
                while let newline = self.partialLine.firstIndex(of: 10) {
                    let line = Data(self.partialLine[..<newline])
                    self.partialLine.removeSubrange(...newline)
                    if let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                        self.messages.append(message)
                        self.semaphore.signal()
                    }
                }
            }
            self.lock.unlock()
        }
    }

    func next(id: Int, deadline: Date) throws -> [String: Any] {
        while Date() < deadline {
            lock.lock()
            if let index = messages.firstIndex(where: { ($0["id"] as? NSNumber)?.intValue == id }) {
                let message = messages.remove(at: index)
                lock.unlock()
                return message
            }
            let ended = self.ended
            lock.unlock()
            if ended { throw NativeAccountError.codexUnavailable }
            let timeout = max(deadline.timeIntervalSinceNow, 0)
            if semaphore.wait(timeout: .now() + timeout) == .timedOut { throw NativeAccountError.codexUnavailable }
        }
        throw NativeAccountError.codexUnavailable
    }

    func stop() { handle.readabilityHandler = nil }
    deinit { stop() }
}

private final class CodexAppServerRunner: @unchecked Sendable {
    private let lock = NSLock()
    private let process = Process()
    private var cancelled = false
    func cancel() {
        lock.lock()
        cancelled = true
        if process.isRunning { process.terminate() }
        lock.unlock()
    }

    var wasCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func run(executable: URL) throws -> SubscriptionAccess {
        lock.lock()
        guard !cancelled else { lock.unlock(); throw NativeAccountError.cancelled }
        process.executableURL = executable
        process.arguments = ["app-server"]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() }
        catch { lock.unlock(); throw NativeAccountError.codexUnavailable }
        if cancelled { process.terminate() }
        lock.unlock()
        defer {
            if process.isRunning { process.terminate() }
            try? input.fileHandleForWriting.close()
        }
        let reader = CodexLineReader(output.fileHandleForReading)
        defer { reader.stop() }
        let deadline = Date().addingTimeInterval(30)
        try input.fileHandleForWriting.write(contentsOf: Data("{\"id\":0,\"method\":\"initialize\",\"params\":{\"clientInfo\":{\"name\":\"biscuit\",\"title\":\"biscuit\",\"version\":\"1.0\"}}}\n".utf8))
        let initialized = try reader.next(id: 0, deadline: deadline)
        guard initialized["result"] != nil else { throw NativeAccountError.codexUnavailable }
        try input.fileHandleForWriting.write(contentsOf: Data("{\"id\":1,\"method\":\"getAuthStatus\",\"params\":{\"includeToken\":true,\"refreshToken\":true}}\n".utf8))
        let response = try reader.next(id: 1, deadline: deadline)
        let data = try JSONSerialization.data(withJSONObject: response)
        return try NativeAccountProtocol.codexAppServerAccess(from: data)
    }
}

private enum CodexAppServerAccess {
    static func read(executable: URL?) async throws -> SubscriptionAccess {
        guard let executable else { throw NativeAccountError.codexUnavailable }
        let runner = CodexAppServerRunner()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do { continuation.resume(returning: try runner.run(executable: executable)) }
                    catch {
                        continuation.resume(throwing: runner.wasCancelled ? NativeAccountError.cancelled : error)
                    }
                }
            }
        } onCancel: {
            runner.cancel()
        }
    }
}

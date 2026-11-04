// Callback/grant regressions adapted from OpenAI Codex, Copyright 2025 OpenAI,
// Apache-2.0. Modified for Swift and offline biscuit fixtures.
// See Resources/Notices/OpenAICodex/SOURCE-PIN.txt.

import Foundation
import Security

@MainActor
enum AccountSmoke {
    struct Failure: Error, CustomStringConvertible { let description: String }

    static func run(root: URL) async throws {
        func require(_ condition: Bool, _ message: String) throws {
            if !condition { throw Failure(description: message) }
        }
        try runOpenAIOAuthProtocolChecks()
        try runDeviceProtocolChecks()

        let suite = "org.biscuit.smoke.account.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { throw Failure(description: "Isolated defaults unavailable") }
        defer { defaults.removePersistentDomain(forName: suite) }
        let old = NativeOAuthCredential(accessToken: "synthetic-expired-access", refreshToken: "synthetic-old-refresh", accountID: "synthetic-account", expiresAt: .distantPast)
        let response = try JSONSerialization.data(withJSONObject: ["access_token": "synthetic-new-access", "refresh_token": "synthetic-new-refresh", "expires_in": 3600, "id_token": try jwt(expiry: 4_000_000_000)])
        let store = MemorySecretStore()
        try store.write(JSONEncoder().encode(old), for: NativeAccountSettingsKey.chatGPTSession)
        let gate = RefreshGate(response: response)
        let controller = NativeAccountController(store: store, transport: gate, defaults: defaults)
        let first = Task { try await controller.access() }
        let second = Task { try await controller.access() }
        await gate.waitForRequest()
        await gate.release()
        let firstAccess = try await first.value
        let secondAccess = try await second.value
        let requests = await gate.requestCount
        try require(requests == 1 && firstAccess.accessToken == secondAccess.accessToken, "Concurrent consumers must share one refresh rotation.")
        guard let saved = try store.read(NativeAccountSettingsKey.chatGPTSession) else { throw Failure(description: "Rotated credential was not committed") }
        let rotated = try JSONDecoder().decode(NativeOAuthCredential.self, from: saved)
        try require(rotated.refreshToken == "synthetic-new-refresh", "A rotated refresh token must be persisted before consumers resume.")
        let relaunched = NativeAccountController(store: store, transport: gate, defaults: defaults)
        _ = try await relaunched.access()
        try require(await gate.requestCount == 1, "A fresh persisted session must survive controller relaunch without another login/refresh.")

        try await runAccessLifecycleChecks()

        let file = root.appendingPathComponent("synthetic-codex-auth.json")
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let boundary = try codexFile(token: jwt(expiry: now.timeIntervalSince1970 + 30))
        do { _ = try NativeAccountProtocol.codexFileAccess(from: boundary, now: now); throw Failure(description: "Unsafe near-expiry Codex token accepted") }
        catch NativeAccountError.codexExpired { }
        let firstFile = try codexFile(token: jwt(expiry: 4_000_000_000))
        var implicitMode = try JSONSerialization.jsonObject(with: firstFile) as! [String: Any]
        implicitMode.removeValue(forKey: "auth_mode")
        let implicitData = try JSONSerialization.data(withJSONObject: implicitMode)
        try require(try NativeAccountProtocol.codexFileAccess(from: implicitData).accountID == Optional("synthetic-account"), "A documented omitted auth_mode must infer ChatGPT when no alternate credential mode is present.")
        implicitMode["OPENAI_API_KEY"] = "synthetic-api-key-not-used"
        do {
            _ = try NativeAccountProtocol.codexFileAccess(from: JSONSerialization.data(withJSONObject: implicitMode))
            throw Failure(description: "API-key mode must never become a subscription connection")
        } catch NativeAccountError.codexUnsupportedAuth { }
        try firstFile.write(to: file)
        defaults.set("file-only", forKey: NativeAccountSettingsKey.codexMode)
        defaults.set(file.path, forKey: NativeAccountSettingsKey.codexFile)
        let connectedStore = MemorySecretStore()
        let connected = NativeAccountController(store: connectedStore, transport: gate, defaults: defaults)
        let before = try await connected.access()
        connected.invalidateAccess(provider: .chatgpt, usedToken: before.accessToken)
        do { _ = try await connected.access(); throw Failure(description: "A rejected Codex file token was reused") }
        catch NativeAccountError.codexFileTokenRejected { }
        let secondFile = try codexFile(token: jwt(expiry: 4_000_000_001))
        try secondFile.write(to: file)
        let after = try await connected.access()
        try require(before.accessToken != after.accessToken, "Connected Codex file mode must re-read the owner's current token per request.")
        connected.disconnect()
        try require(try Data(contentsOf: file) == secondFile, "Disconnect must not modify or delete Codex-owned credentials.")
        try require(try connectedStore.read(NativeAccountSettingsKey.chatGPTSession) == nil, "Connected Codex must not persist upstream tokens in biscuit's owned credential store.")

        try await browserLoginSupersedesRefresh()
        try secureStoreOperationChecks()
        try await deviceLoginCancellationAndTokenExchangeFailure()
        try keychainPersistenceChecks(service: suite)
    }

    static func keychainPersistenceChecks(service: String) throws {
        guard service.hasPrefix("org.biscuit.smoke.") else {
            throw Failure(description: "Keychain smoke requires a task-only service.")
        }
        func require(_ condition: Bool, _ message: String) throws {
            if !condition { throw Failure(description: message) }
        }
        let keychain = NativeKeychainStore(service: service)
        defer { try? keychain.delete("fixture") }
        try keychain.write(Data("synthetic-v1".utf8), for: "fixture")
        try require(try keychain.read("fixture") == Data("synthetic-v1".utf8), "The initial secure session must round-trip.")
        try keychain.write(Data("synthetic-v2".utf8), for: "fixture")
        try require(try NativeKeychainStore(service: service).read("fixture") == Data("synthetic-v2".utf8), "Secure session replacement must survive a fresh store instance.")
        try keychain.delete("fixture")
        try require(try keychain.read("fixture") == nil, "Sign-out must remove only its own secure session.")
    }

    static func runOpenAIOAuthProtocolChecks() throws {
        func require(_ condition: Bool, _ message: String) throws {
            if !condition { throw Failure(description: message) }
        }
        // authorization_tests.rs::callback_validation_checks_state_before_code_or_provider_errors
        let cases = [
            ("state=expected&code=trusted-code", "trusted-code"),
            ("code=untrusted", "state"),
            ("state=wrong&code=untrusted&error=access_denied", "state"),
            ("state=expected.extra&code=untrusted", "state"),
            ("state=expected&code=ignored&error=access_denied", "provider"),
            ("state=expected&code=", "code"),
            // Invalid-state traffic must not end the real pending callback as MissingCode.
            ("state=wrong&code=", "state"),
            ("state=expected&error=", "provider"),
            ("state=expected&state=expected&code=ignored", "state"),
            ("state=expected&code=one&code=two", "code"),
            ("state=expected&code=code%2Bwith%26reserved%3Dcharacters", "code+with&reserved=characters"),
            ("state=expected&code=with+space", "with space")
        ]
        for (query, expected) in cases {
            let actual: String
            do {
                actual = try NativeAccountProtocol.callbackCode("http://127.0.0.1:1455/auth/callback?" + query, expectedState: "expected")
            } catch NativeAccountError.callbackStateMismatch { actual = "state"
            } catch NativeAccountError.providerDenied { actual = "provider"
            } catch NativeAccountError.callbackMissingCode { actual = "code" }
            try require(actual == expected, "Upstream callback precedence/decoding regression.")
        }
        let manual = try NativeAccountProtocol.callbackCode("manual-code#expected", expectedState: "expected")
        try require(manual == "manual-code", "Manual callback must preserve state-bound completion.")
        do {
            _ = try NativeAccountProtocol.callbackCode("bare-code", expectedState: "expected")
            throw Failure(description: "Manual callback accepted without state.")
        } catch NativeAccountError.callbackMissingCode { }

        // client_tests.rs::authorization_code_preserves_pkce_and_http_policy, adapted
        // to pure serialization: no listener, browser, remote HTTP or Keychain.
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        let pkce = NativeAccountProtocol.makePKCE(verifier: verifier, state: "fixture-state")
        try require(pkce.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", "RFC7636 S256 vector mismatch.")
        let redirect = "http://127.0.0.1:1457/auth/callback"
        let authorization = try NativeAccountProtocol.authorizationURL(pkce: pkce, redirectURI: redirect)
        let query = URLComponents(url: authorization, resolvingAgainstBaseURL: false)!.queryItems!
        let body = NativeAccountProtocol.authorizationCodeBody(
            code: "code+with&reserved=characters /%~한", redirectURI: redirect, verifier: verifier
        )
        let encoded = String(decoding: body, as: UTF8.self)
        let decoded = Dictionary(uniqueKeysWithValues: encoded.split(separator: "&").map { part -> (String, String) in
            let pair = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            return (String(pair[0]), String(pair[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding!)
        })
        try require(decoded == [
            "grant_type": "authorization_code", "client_id": NativeAccountProtocol.openAIClientID,
            "code": "code+with&reserved=characters /%~한", "redirect_uri": redirect, "code_verifier": verifier
        ], "Code exchange corrupted a reserved character or grant binding.")
        try require(query.first { $0.name == "code_challenge" }?.value ==
                    NativeAccountProtocol.makePKCE(verifier: decoded["code_verifier"]!, state: pkce.state).challenge &&
                    query.first { $0.name == "redirect_uri" }?.value == decoded["redirect_uri"],
                    "Authorization challenge/callback differs from exchanged grant.")
        let refresh = "credential+crossing&the=limit /%"
        let refreshBody = try NativeAccountProtocol.refreshBody(refreshToken: refresh)
        let refreshJSON = try JSONSerialization.jsonObject(with: refreshBody) as? [String: String]
        try require(refreshJSON == [
            "grant_type": "refresh_token", "client_id": NativeAccountProtocol.openAIClientID, "refresh_token": refresh
        ], "ChatGPT refresh must remain JSON without form-decoding credential bytes.")
    }

    static func runDeviceProtocolChecks() throws {
        // device_code_auth.rs::deserialize_interval preserves the server cadence.
        let intervals: [(Any, TimeInterval)] = [("120", 120), (" 3\n", 3), (120, 120)]
        for (raw, expected) in intervals {
            let data = try JSONSerialization.data(withJSONObject: [
                "device_auth_id": "synthetic-device", "user_code": "PUBLIC-CODE", "interval": raw
            ])
            guard try NativeAccountProtocol.deviceCode(from: data).interval == expected else {
                throw Failure(description: "Device polling must not shorten or replace the server-provided interval.")
            }
        }
        for raw in ["invalid", true] as [Any] {
            let data = try JSONSerialization.data(withJSONObject: [
                "device_auth_id": "synthetic-device", "user_code": "PUBLIC-CODE", "interval": raw
            ])
            do {
                _ = try NativeAccountProtocol.deviceCode(from: data)
                throw Failure(description: "Malformed device interval must not silently start polling.")
            } catch NativeAccountError.invalidProviderResponse { }
        }
        let data = try JSONSerialization.data(withJSONObject: [
            "authorization_code": "synthetic-grant", "code_verifier": "synthetic-verifier",
            "code_challenge": "mismatched-challenge"
        ])
        do {
            _ = try NativeAccountProtocol.deviceGrant(from: data)
            throw Failure(description: "A device grant with mismatched PKCE must not reach token exchange.")
        } catch NativeAccountError.invalidProviderResponse { }
    }

    static func secureStoreOperationChecks() throws {
        func require(_ condition: Bool, _ message: String) throws {
            if !condition { throw Failure(description: message) }
        }
        let service = "synthetic-service-marker"
        let accountQuery = "synthetic-account-query-marker"
        let payload = Data("synthetic-keychain-data-marker:synthetic-access-token-marker".utf8)
        let secretMarkers = [
            service,
            accountQuery,
            String(data: payload, encoding: .utf8)!,
            "synthetic-access-token-marker"
        ]
        func verify(_ error: NativeAccountError, operation: NativeSecureStoreOperation, status: OSStatus) throws {
            let description = error.localizedDescription
            let statusDigits = String(status).filter { $0.isNumber }
            let descriptionDigits = description.filter { $0.isNumber }
            guard case let .secureStore(actualOperation, actualStatus) = error,
                  actualOperation.rawValue == operation.rawValue,
                  actualStatus == status,
                  description.contains(operation.rawValue),
                  descriptionDigits.contains(statusDigits) else {
                let rawDescription = error.errorDescription ?? "<missing>"
                throw Failure(description: "Secure-store error mismatch; expected \(operation.rawValue)/\(status), errorDescription=\(rawDescription), localizedDescription=\(description).")
            }
            for marker in secretMarkers {
                try require(!description.contains(marker), "Secure-store diagnostics exposed a private input.")
            }
        }

        let backend = FakeNativeKeychainBackend()
        let store = NativeKeychainStore(service: service, backend: backend.make())

        backend.copyStatus = errSecItemNotFound
        let absentRead = try store.read(accountQuery)
        try require(absentRead == nil, "A missing Keychain read must remain an absent value.")
        backend.resetCalls()
        let absentContains = try store.contains(accountQuery)
        try require(!absentContains, "A missing Keychain contains query must remain false.")
        backend.resetCalls()
        backend.deleteStatus = errSecItemNotFound
        try store.delete(accountQuery)
        try require(backend.calls == ["delete"], "Deleting a missing Keychain item must remain successful.")

        backend.resetCalls()
        backend.updateStatus = errSecSuccess
        backend.addStatus = errSecAuthFailed
        try store.write(payload, for: accountQuery)
        try require(backend.calls == ["update"], "A successful Keychain update must not add or retry.")

        backend.resetCalls()
        backend.updateStatus = errSecItemNotFound
        backend.addStatus = errSecSuccess
        try store.write(payload, for: accountQuery)
        try require(backend.calls == ["update", "add"], "A missing Keychain update must fall back to one add.")

        backend.resetCalls()
        backend.updateStatus = errSecAuthFailed
        do {
            try store.write(payload, for: accountQuery)
            throw Failure(description: "A failed Keychain update was accepted.")
        } catch let error as NativeAccountError {
            try verify(error, operation: .update, status: errSecAuthFailed)
        }
        try require(backend.calls == ["update"], "A non-not-found update failure must not fall back to add.")

        backend.resetCalls()
        backend.updateStatus = errSecItemNotFound
        backend.addStatus = errSecAuthFailed
        do {
            try store.write(payload, for: accountQuery)
            throw Failure(description: "A failed Keychain add was accepted.")
        } catch let error as NativeAccountError {
            try verify(error, operation: .add, status: errSecAuthFailed)
        }
        try require(backend.calls == ["update", "add"], "The add failure must retain the single not-found fallback.")

        backend.resetCalls()
        backend.copyStatus = errSecAuthFailed
        do {
            _ = try store.read(accountQuery)
            throw Failure(description: "A failed Keychain read was accepted.")
        } catch let error as NativeAccountError {
            try verify(error, operation: .read, status: errSecAuthFailed)
        }
        try require(backend.calls == ["read"], "A Keychain read failure must not retry.")

        backend.resetCalls()
        do {
            _ = try store.contains(accountQuery)
            throw Failure(description: "A failed Keychain contains query was accepted.")
        } catch let error as NativeAccountError {
            try verify(error, operation: .read, status: errSecAuthFailed)
        }
        try require(backend.calls == ["read"], "A Keychain contains failure must be labelled as a read.")

        backend.resetCalls()
        backend.deleteStatus = errSecAuthFailed
        do {
            try store.delete(accountQuery)
            throw Failure(description: "A failed Keychain delete was accepted.")
        } catch let error as NativeAccountError {
            try verify(error, operation: .delete, status: errSecAuthFailed)
        }
        try require(backend.calls == ["delete"], "A Keychain delete failure must not retry.")
    }

    static func runAccessLifecycleChecks() async throws {
        let (defaults, suite) = try fixtureDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        func require(_ condition: Bool, _ message: String) throws {
            if !condition { throw Failure(description: message) }
        }
        let old = NativeOAuthCredential(
            accessToken: "synthetic-expired-access",
            refreshToken: "synthetic-old-refresh",
            accountID: "synthetic-account",
            expiresAt: .distantPast
        )
        let response = try JSONSerialization.data(withJSONObject: [
            "access_token": "synthetic-new-access",
            "refresh_token": "synthetic-new-refresh",
            "expires_in": 3600,
            "id_token": try jwt(expiry: 4_000_000_000)
        ])

        let preCancelledStore = MemorySecretStore()
        try preCancelledStore.write(JSONEncoder().encode(old), for: NativeAccountSettingsKey.chatGPTSession)
        let preCancelledGate = RefreshGate(response: response)
        let preCancelledController = NativeAccountController(store: preCancelledStore, transport: preCancelledGate, defaults: defaults)
        await preCancelledGate.release()
        let preCancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await preCancelledController.access(provider: .chatgpt)
        }
        do {
            _ = try await preCancelled.value
            throw Failure(description: "A pre-cancelled caller started account access.")
        } catch is CancellationError { }
        try require(await preCancelledGate.requestCount == 0, "A pre-cancelled caller must not start a refresh.")

        let sharedStore = MemorySecretStore()
        try sharedStore.write(JSONEncoder().encode(old), for: NativeAccountSettingsKey.chatGPTSession)
        let sharedGate = RefreshGate(response: response)
        let sharedController = NativeAccountController(store: sharedStore, transport: sharedGate, defaults: defaults)
        let owner = Task { try await sharedController.access(provider: .chatgpt) }
        await sharedGate.waitForRequest()
        let cancelledWaiter = Task { try await sharedController.access(provider: .chatgpt) }
        await Task.yield()
        let survivingWaiter = Task { try await sharedController.access(provider: .chatgpt) }
        await Task.yield()
        owner.cancel()
        cancelledWaiter.cancel()
        await sharedGate.release()
        do {
            _ = try await owner.value
            throw Failure(description: "A cancelled refresh owner received access.")
        } catch is CancellationError { }
        do {
            _ = try await cancelledWaiter.value
            throw Failure(description: "A cancelled coalesced waiter received access.")
        } catch is CancellationError { }
        let access = try await survivingWaiter.value
        try require(access.accessToken == "synthetic-new-access", "A surviving waiter must receive the completed shared refresh.")
        let sharedRequestCount = await sharedGate.requestCount
        let sharedCancelledRequestCount = await sharedGate.cancelledRequestCount
        try require(sharedRequestCount == 1 && sharedCancelledRequestCount == 0, "Caller cancellation must not cancel the shared refresh needed by another waiter.")
        guard let sharedData = try sharedStore.read(NativeAccountSettingsKey.chatGPTSession) else {
            throw Failure(description: "Caller cancellation lost the rotated session.")
        }
        let rotated = try JSONDecoder().decode(NativeOAuthCredential.self, from: sharedData)
        try require(rotated.refreshToken == "synthetic-new-refresh", "The shared refresh must persist rotation before surviving waiters resume.")

        let disconnectedStore = MemorySecretStore()
        try disconnectedStore.write(JSONEncoder().encode(old), for: NativeAccountSettingsKey.chatGPTSession)
        let disconnectGate = RefreshGate(response: response)
        let disconnectController = NativeAccountController(store: disconnectedStore, transport: disconnectGate, defaults: defaults)
        let stale = Task { try await disconnectController.access(provider: .chatgpt) }
        await disconnectGate.waitForRequest()
        disconnectController.disconnect(provider: .chatgpt)
        await disconnectGate.release()
        do {
            _ = try await stale.value
            throw Failure(description: "A disconnected refresh returned access.")
        } catch is CancellationError {
        } catch NativeAccountError.cancelled { }
        try require(await disconnectGate.cancelledRequestCount == 1, "Provider disconnect must cancel its owned in-flight refresh task.")
        try require(try disconnectedStore.read(NativeAccountSettingsKey.chatGPTSession) == nil, "A stale refresh must not resurrect a disconnected account.")
    }


    // Type-checked with the suite but intentionally never invoked by Smoke.
    static func claudeOAuthChecksCompileOnly() throws {
        func require(_ condition: Bool, _ message: String) throws {
            if !condition { throw Failure(description: message) }
        }
        func rejects(_ message: String, _ operation: () throws -> Void) throws {
            do { try operation() } catch { return }
            throw Failure(description: message)
        }
        let pkce = NativeAccountProtocol.makePKCE(
            verifier: "synthetic-claude-verifier-012345678901234567890123456789",
            state: "synthetic-claude-state"
        )
        let redirect = "http://localhost:61234/callback"
        let authorization = try NativeClaudeOAuthProtocol.authorizationURL(pkce: pkce, redirectURI: redirect)
        let authorizationQuery = URLComponents(url: authorization, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { authorizationQuery.first { $0.name == name }?.value }
        try require(value("client_id") == NativeClaudeOAuthProtocol.clientID
            && value("scope") == NativeClaudeOAuthProtocol.scope
            && value("code") == "true"
            && value("redirect_uri") == redirect
            && value("code_challenge_method") == "S256"
            && value("code_challenge") == pkce.challenge
            && value("state") == pkce.state,
            "Claude authorization must request its supported user scopes without API-creation access, and bind exact redirect, independent state and S256 PKCE.")
        let callback = "\(redirect)?code=synthetic-claude-code&state=\(pkce.state)"
        try require(try NativeClaudeOAuthProtocol.callbackCode(callback, expectedState: pkce.state, redirectURI: redirect) == "synthetic-claude-code",
            "Claude callback must validate the exact redirect and state before returning code.")
        try rejects("Claude callback must reject another loopback port.") {
            _ = try NativeClaudeOAuthProtocol.callbackCode(
                "http://localhost:61235/callback?code=synthetic-claude-code&state=\(pkce.state)",
                expectedState: pkce.state,
                redirectURI: redirect
            )
        }
        try rejects("Claude callback must reject a duplicate code.") {
            _ = try NativeClaudeOAuthProtocol.callbackCode(
                "\(callback)&code=other",
                expectedState: pkce.state,
                redirectURI: redirect
            )
        }
        let exchange = try NativeClaudeOAuthProtocol.authorizationCodeBody(
            code: "synthetic-claude-code",
            redirectURI: redirect,
            verifier: pkce.verifier,
            state: pkce.state
        )
        let exchangeFields = try JSONSerialization.jsonObject(with: exchange) as? [String: String]
        try require(exchangeFields?["grant_type"] == "authorization_code"
            && exchangeFields?["state"] == pkce.state
            && exchangeFields?["redirect_uri"] == redirect,
            "Claude code exchange must bind the same state and redirect as authorization.")
        let refresh = try NativeClaudeOAuthProtocol.refreshBody(refreshToken: "synthetic-claude-refresh")
        let refreshFields = try JSONSerialization.jsonObject(with: refresh) as? [String: String]
        try require(refreshFields?["scope"] == NativeClaudeOAuthProtocol.scope
            && refreshFields?["client_id"] == NativeClaudeOAuthProtocol.clientID,
            "Claude refresh must preserve the authorized user-scope set and provider-specific client.")
        let response = try JSONSerialization.data(withJSONObject: [
            "access_token": "synthetic-claude-access",
            "refresh_token": "synthetic-claude-rotated-refresh",
            "expires_in": 3600,
            "account_id": "ignored-opaque-provider-data"
        ])
        let credential = try NativeClaudeOAuthProtocol.credential(from: response, now: Date(timeIntervalSince1970: 100))
        try require(credential.accessToken == "synthetic-claude-access"
            && credential.refreshToken == "synthetic-claude-rotated-refresh"
            && credential.expiresAt == Date(timeIntervalSince1970: 3700),
            "Claude credentials must preserve opaque tokens and expiry without account-ID parsing.")
        let accessOnlyResponse = try JSONSerialization.data(withJSONObject: [
            "access_token": "synthetic-claude-access-without-refresh",
            "expires_in": 3600
        ])
        let accessOnly = try NativeClaudeOAuthProtocol.credential(from: accessOnlyResponse)
        let retainedRefresh = try NativeClaudeOAuthProtocol.credential(
            from: accessOnlyResponse,
            previousRefreshToken: "synthetic-existing-refresh"
        )
        try require(accessOnly.refreshToken == nil
            && retainedRefresh.refreshToken == "synthetic-existing-refresh",
            "An optional refresh token may be absent on sign-in and an omitted rotation must preserve the prior token.")
    }
    // Type-checked with the suite but intentionally never invoked by Smoke.
    static func claudeOptionalRefreshBoundaryCheckCompileOnly() async throws {
        let (defaults, suite) = try fixtureDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MemorySecretStore()
        let transport = ClaudeBoundaryTransport()
        let nearExpiry = ClaudeOAuthCredential(
            accessToken: "synthetic-near-expiry-access",
            refreshToken: nil,
            expiresAt: Date().addingTimeInterval(30)
        )
        try store.write(JSONEncoder().encode(nearExpiry), for: NativeAccountSettingsKey.claudeSession)
        let controller = NativeAccountController(store: store, claudeStore: store, transport: transport, defaults: defaults)
        let available = try await controller.access(provider: .claude)
        guard available.accessToken == nearExpiry.accessToken, await transport.requestCount() == 0 else {
            throw Failure(description: "A valid access-only Claude session must remain usable inside the proactive refresh window.")
        }

        let expired = ClaudeOAuthCredential(accessToken: "synthetic-expired-access", refreshToken: nil, expiresAt: .distantPast)
        try store.write(JSONEncoder().encode(expired), for: NativeAccountSettingsKey.claudeSession)
        do {
            _ = try await controller.access(provider: .claude)
            throw Failure(description: "An expired Claude session without a refresh token must require sign-in.")
        } catch NativeAccountError.claudeRefreshRequired { }
        guard await transport.requestCount() == 0 else {
            throw Failure(description: "An expired access-only Claude session must not attempt a refresh request.")
        }
    }


    private static func browserLoginSupersedesRefresh() async throws {
        let (defaults, suite) = try fixtureDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MemorySecretStore()
        let expired = NativeOAuthCredential(accessToken: "synthetic-old-access", refreshToken: "synthetic-old-refresh", accountID: "synthetic-account", expiresAt: .distantPast)
        try store.write(JSONEncoder().encode(expired), for: NativeAccountSettingsKey.chatGPTSession)
        let transport = LoginRaceTransport(
            refreshResponse: try tokenResponse(access: "synthetic-refresh-access", refresh: "synthetic-refresh-rotation"),
            loginResponse: try tokenResponse(access: "synthetic-login-access", refresh: "synthetic-login-refresh")
        )
        let endpoints = fixtureEndpoints()
        let controller = NativeAccountController(store: store, transport: transport, endpoints: endpoints, defaults: defaults, openURL: { authorization in
            guard let authorization = URLComponents(url: authorization, resolvingAgainstBaseURL: false),
                  let redirect = authorization.queryItems?.first(where: { $0.name == "redirect_uri" })?.value,
                  let state = authorization.queryItems?.first(where: { $0.name == "state" })?.value,
                  var callback = URLComponents(string: redirect) else { return false }
            callback.queryItems = [URLQueryItem(name: "code", value: "synthetic-login-code"), URLQueryItem(name: "state", value: state)]
            guard let callbackURL = callback.url else { return false }
            Task.detached { _ = try? await URLSession.shared.data(from: callbackURL) }
            return true
        })

        let oldRefresh = Task { try await controller.access() }
        guard await transport.waitForRefresh() else { throw Failure(description: "Synthetic old refresh did not enter its transport gate.") }
        guard let login = controller.beginBrowserLogin() else { throw Failure(description: "Synthetic browser login did not start.") }
        guard await transport.waitForLogin() else {
            controller.cancelLogin()
            await transport.releaseRefresh()
            await login.value
            _ = try? await oldRefresh.value
            throw Failure(description: "Local callback did not reach the synthetic browser token-exchange fixture.")
        }
        await transport.releaseRefresh()
        do { _ = try await oldRefresh.value; throw Failure(description: "An old refresh survived a successful replacement login.") }
        catch NativeAccountError.cancelled { }
        await login.value

        guard let saved = try store.read(NativeAccountSettingsKey.chatGPTSession) else { throw Failure(description: "New browser login did not commit its owned credential.") }
        let committed = try JSONDecoder().decode(NativeOAuthCredential.self, from: saved)
        guard committed.accessToken == "synthetic-login-access",
              committed.refreshToken == "synthetic-login-refresh",
              defaults.string(forKey: NativeAccountSettingsKey.codexMode) == "owned" else {
            throw Failure(description: "The stale refresh overwrote or invalidated the completed browser login.")
        }
    }

    static func deviceLoginCancellationAndTokenExchangeFailure() async throws {
        let endpoints = fixtureEndpoints()
        let issue = try JSONSerialization.data(withJSONObject: ["device_auth_id": "synthetic-device", "user_code": "PUBLIC-CODE", "interval": 1])
        let pkce = NativeAccountProtocol.makePKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk", state: "fixture-state")
        let grant = try JSONSerialization.data(withJSONObject: ["authorization_code": "synthetic-device-code", "code_verifier": pkce.verifier, "code_challenge": pkce.challenge])

        let (cancelDefaults, cancelSuite) = try fixtureDefaults()
        defer { cancelDefaults.removePersistentDomain(forName: cancelSuite) }
        let cancelStore = MemorySecretStore()
        let cancelledTransport = DeviceFixtureTransport(deviceCodeURL: endpoints.deviceCode, devicePollURL: endpoints.devicePoll, tokenURL: endpoints.token, issue: issue, grant: grant, mode: .holdIssuance)
        let cancelledController = NativeAccountController(store: cancelStore, transport: cancelledTransport, endpoints: endpoints, defaults: cancelDefaults, openURL: { _ in true })
        guard let cancelledLogin = cancelledController.beginDeviceLogin(),
              await cancelledTransport.waitForIssue() else {
            throw Failure(description: "Synthetic device-code issuance did not reach its gate.")
        }
        cancelledController.cancelLogin()
        await cancelledTransport.releaseIssue()
        await cancelledLogin.value
        let cancelledCounts = await cancelledTransport.counts()
        guard cancelledCounts.0 == 1 && cancelledCounts.1 == 0 && cancelledCounts.2 == 0,
              try cancelStore.read(NativeAccountSettingsKey.chatGPTSession) == nil else {
            throw Failure(description: "Cancelling device issuance must prevent polling, token exchange, and credential commit.")
        }

        let (failureDefaults, failureSuite) = try fixtureDefaults()
        defer { failureDefaults.removePersistentDomain(forName: failureSuite) }
        let failureStore = MemorySecretStore()
        let failureTransport = DeviceFixtureTransport(deviceCodeURL: endpoints.deviceCode, devicePollURL: endpoints.devicePoll, tokenURL: endpoints.token, issue: issue, grant: grant, mode: .rejectTokenExchange)
        let failureController = NativeAccountController(store: failureStore, transport: failureTransport, endpoints: endpoints, defaults: failureDefaults, openURL: { _ in true })
        guard let failedLogin = failureController.beginDeviceLogin() else { throw Failure(description: "Synthetic device-code login did not start.") }
        await failedLogin.value
        let failureCounts = await failureTransport.counts()
        guard failureCounts.0 == 1 && failureCounts.1 == 1 && failureCounts.2 == 1,
              try failureStore.read(NativeAccountSettingsKey.chatGPTSession) == nil else {
            throw Failure(description: "Token-exchange HTTP 403 must fail once, not be mistaken for a pending device poll or commit a session.")
        }

        let (successDefaults, successSuite) = try fixtureDefaults()
        defer { successDefaults.removePersistentDomain(forName: successSuite) }
        let successStore = MemorySecretStore()
        let successTransport = DeviceFixtureTransport(
            deviceCodeURL: endpoints.deviceCode, devicePollURL: endpoints.devicePoll,
            tokenURL: endpoints.token, issue: issue, grant: grant, mode: .completeAfterPending,
            token: try tokenResponse(access: "synthetic-device-access", refresh: "synthetic-device-refresh")
        )
        let successController = NativeAccountController(
            store: successStore, transport: successTransport, endpoints: endpoints,
            defaults: successDefaults, openURL: { _ in true }
        )
        guard let successLogin = successController.beginDeviceLogin() else {
            throw Failure(description: "Synthetic device-code login did not start.")
        }
        await successLogin.value
        let restoredController = NativeAccountController(
            store: successStore, transport: successTransport, endpoints: endpoints, defaults: successDefaults
        )
        let restoredAccess = try await restoredController.access()
        let successCounts = await successTransport.counts()
        guard successCounts.1 == 3 && successCounts.2 == 1,
              restoredAccess.accessToken == "synthetic-device-access",
              let stored = try successStore.read(NativeAccountSettingsKey.chatGPTSession),
              try JSONDecoder().decode(NativeOAuthCredential.self, from: stored).refreshToken == "synthetic-device-refresh" else {
            throw Failure(description: "Pending device-poll 403/404 must allow one successful exchange and a durable owned session.")
        }
    }

    private static func fixtureDefaults() throws -> (UserDefaults, String) {
        let suite = "org.biscuit.smoke.account.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { throw Failure(description: "Isolated login-fixture defaults unavailable.") }
        return (defaults, suite)
    }

    private static func fixtureEndpoints() -> NativeAccountEndpoints {
        NativeAccountEndpoints(
            authorization: URL(string: "https://fixture.invalid/oauth/authorize")!,
            token: URL(string: "https://fixture.invalid/oauth/token")!,
            deviceCode: URL(string: "https://fixture.invalid/device/code")!,
            devicePoll: URL(string: "https://fixture.invalid/device/poll")!,
            deviceVerification: URL(string: "https://fixture.invalid/device")!,
            deviceCallback: "https://fixture.invalid/device/callback"
        )
    }

    private static func tokenResponse(access: String, refresh: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "access_token": access, "refresh_token": refresh, "expires_in": 3600,
            "id_token": try jwt(expiry: 4_000_000_000)
        ])
    }

    private static func jwt(expiry: TimeInterval) throws -> String {
        let header = try JSONSerialization.data(withJSONObject: ["alg": "RS256", "typ": "JWT"])
        let claims = try JSONSerialization.data(withJSONObject: ["exp": expiry, "https://api.openai.com/auth": ["chatgpt_account_id": "synthetic-account"]])
        return header.base64URLEncodedString + "." + claims.base64URLEncodedString + ".c3ludGhldGlj"
    }
    private static func codexFile(token: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["auth_mode": "chatgpt", "tokens": ["access_token": token, "refresh_token": "codex-owner-only"]])
    }
}

private final class MemorySecretStore: NativeSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func read(_ key: String) throws -> Data? { lock.withLock { values[key] } }
    func contains(_ key: String) throws -> Bool { lock.withLock { values[key] != nil } }
    func write(_ data: Data, for key: String) throws { lock.withLock { values[key] = data } }
    func delete(_ key: String) throws { _ = lock.withLock { values.removeValue(forKey: key) } }
}
private final class FakeNativeKeychainBackend {
    var copyStatus = errSecItemNotFound
    var copyResult: CFTypeRef?
    var updateStatus = errSecItemNotFound
    var addStatus = errSecSuccess
    var deleteStatus = errSecItemNotFound
    var calls: [String] = []

    func make() -> NativeKeychainBackend {
        NativeKeychainBackend(
            copyMatching: { [unowned self] _, result in
                self.calls.append("read")
                result.pointee = self.copyResult
                return self.copyStatus
            },
            update: { [unowned self] _, _ in
                self.calls.append("update")
                return self.updateStatus
            },
            add: { [unowned self] _ in
                self.calls.append("add")
                return self.addStatus
            },
            delete: { [unowned self] _ in
                self.calls.append("delete")
                return self.deleteStatus
            }
        )
    }

    func resetCalls() { calls.removeAll(keepingCapacity: true) }
}

private actor ClaudeBoundaryTransport: NativeAccountHTTPTransport {
    private var requests = 0
    func post(_ url: URL, body: Data, contentType: String, timeout: TimeInterval) async throws -> Data {
        requests += 1
        throw NativeAccountError.transportFailed
    }
    func requestCount() -> Int { requests }
}


private actor RefreshGate: NativeAccountHTTPTransport {
    private let response: Data
    private var pending: CheckedContinuation<Data, Error>?
    private var entered: CheckedContinuation<Void, Never>?
    private var released = false
    private(set) var requestCount = 0
    private(set) var cancelledRequestCount = 0
    init(response: Data) { self.response = response }
    func post(_ url: URL, body: Data, contentType: String, timeout: TimeInterval) async throws -> Data {
        requestCount += 1
        entered?.resume(); entered = nil
        if released || requestCount > 1 { return response }
        let response = try await withCheckedThrowingContinuation { pending = $0 }
        if Task.isCancelled { cancelledRequestCount += 1 }
        return response
    }
    func waitForRequest() async {
        if requestCount > 0 { return }
        await withCheckedContinuation { entered = $0 }
    }
    func release() { released = true; pending?.resume(returning: response); pending = nil }
}
private actor LoginRaceTransport: NativeAccountHTTPTransport {
    private let refreshResponse: Data
    private let loginResponse: Data
    private var pendingRefresh: CheckedContinuation<Data, Error>?
    private var refreshStarted = false
    private var loginCount = 0

    init(refreshResponse: Data, loginResponse: Data) {
        self.refreshResponse = refreshResponse
        self.loginResponse = loginResponse
    }

    func post(_ url: URL, body: Data, contentType: String, timeout: TimeInterval) async throws -> Data {
        if contentType == "application/json",
           let value = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           value["grant_type"] as? String == "refresh_token" {
            refreshStarted = true
            return try await withCheckedThrowingContinuation { pendingRefresh = $0 }
        }
        if String(decoding: body, as: UTF8.self).contains("grant_type=authorization_code") {
            loginCount += 1
            return loginResponse
        }
        throw NativeAccountError.transportFailed
    }

    func waitForRefresh() async -> Bool {
        for _ in 0..<500 {
            if refreshStarted { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }

    func waitForLogin() async -> Bool {
        for _ in 0..<500 {
            if loginCount > 0 { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }

    func releaseRefresh() {
        pendingRefresh?.resume(returning: refreshResponse)
        pendingRefresh = nil
    }
}

private actor DeviceFixtureTransport: NativeAccountHTTPTransport {
    enum Mode: Sendable, Equatable { case holdIssuance, rejectTokenExchange, completeAfterPending }
    private let deviceCodeURL: URL
    private let devicePollURL: URL
    private let tokenURL: URL
    private let issue: Data
    private let grant: Data
    private let mode: Mode
    private let token: Data?
    private var pendingIssue: CheckedContinuation<Data, Error>?
    private var issueCount = 0
    private var pollCount = 0
    private var tokenCount = 0

    init(deviceCodeURL: URL, devicePollURL: URL, tokenURL: URL, issue: Data, grant: Data, mode: Mode, token: Data? = nil) {
        self.deviceCodeURL = deviceCodeURL
        self.devicePollURL = devicePollURL
        self.tokenURL = tokenURL
        self.issue = issue
        self.grant = grant
        self.mode = mode
        self.token = token
    }
    func post(_ url: URL, body: Data, contentType: String, timeout: TimeInterval) async throws -> Data {
        if url == deviceCodeURL {
            issueCount += 1
            if mode == .holdIssuance {
                return try await withCheckedThrowingContinuation { pendingIssue = $0 }
            }
            return issue
        }
        if url == devicePollURL {
            pollCount += 1
            if mode == .completeAfterPending && pollCount <= 2 {
                throw NativeAccountError.providerRejected(pollCount == 1 ? 403 : 404)
            }
            return grant
        }
        if url == tokenURL {
            tokenCount += 1
            if mode == .completeAfterPending, let token { return token }
            throw NativeAccountError.providerRejected(403)
        }
        throw NativeAccountError.transportFailed
    }

    func waitForIssue() async -> Bool {
        for _ in 0..<500 {
            if issueCount > 0 { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }

    func releaseIssue() {
        pendingIssue?.resume(returning: issue)
        pendingIssue = nil
    }

    func counts() -> (Int, Int, Int) { (issueCount, pollCount, tokenCount) }
}

#if BISCUIT_CHATGPT_ACCESS_SMOKE
@main
struct ChatGPTAccessLifecycleSmoke {
    @MainActor
    static func main() async throws {
        try AccountSmoke.runOpenAIOAuthProtocolChecks()
        print("OPENAI_OAUTH_PROTOCOL_PASS")
        try AccountSmoke.runDeviceProtocolChecks()
        print("OPENAI_DEVICE_PROTOCOL_PASS")
        try await AccountSmoke.deviceLoginCancellationAndTokenExchangeFailure()
        print("OPENAI_DEVICE_LIFECYCLE_PASS")
        try await AccountSmoke.runAccessLifecycleChecks()
        print("CHATGPT_ACCESS_LIFECYCLE_PASS")
    }
}
#endif

#if BISCUIT_SECURE_STORE_DIAGNOSTICS_SMOKE
@main
struct SecureStoreOperationDiagnosticsSmoke {
    @MainActor
    static func main() throws {
        try AccountSmoke.secureStoreOperationChecks()
        print("SECURE_STORE_OPERATION_DIAGNOSTICS_PASS")
    }
}
#endif

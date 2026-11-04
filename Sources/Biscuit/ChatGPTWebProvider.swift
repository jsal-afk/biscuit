import AppKit
import CryptoKit
import Darwin
import Foundation


struct ChatGPTWebStatus: Decodable {
    let connected: Bool
    let needsReconnect: Bool
    let browserRuntimeAvailable: Bool
    let canDisconnect: Bool
    let modelRoutes: [ChatGPTWebModelRoute]
    let defaultModelSlug: String?
}

enum ChatGPTWebFailure: LocalizedError {
    case consentRequired
    case unsupportedArchitecture
    case runtimeMissing
    case runtimeIntegrity
    case runtimeDownload
    case runtimeExtraction
    case runtimeStorage
    case runtimeBusy
    case sidecarBundleMissing
    case sidecarLaunch
    case sidecarExited
    case protocolFailure
    case provider(String)
    case login(String, previousSessionRetained: Bool)

    var errorDescription: String? {
        switch self {
        case .consentRequired:
            return BiscuitLocalization.string("Biscuit needs your confirmation before downloading its optional ChatGPT Web runtime.")
        case .unsupportedArchitecture:
            return BiscuitLocalization.string("ChatGPT Web has no pinned Electron runtime for this Mac architecture.")
        case .runtimeMissing:
            return BiscuitLocalization.string("The optional Electron 41.10.7 runtime is not installed. Download it in ChatGPT Web Provider Settings.")
        case .runtimeIntegrity:
            return BiscuitLocalization.string("Biscuit could not verify its private Electron runtime. Do not run it; replace it with a fresh verified copy.")
        case .runtimeDownload:
            return BiscuitLocalization.string("The official Electron 41.10.7 download failed. Check the network and try again.")
        case .runtimeExtraction:
            return BiscuitLocalization.string("Biscuit could not extract the verified Electron archive. The existing runtime, if any, was preserved.")
        case .runtimeStorage:
            return BiscuitLocalization.string("Biscuit could not securely store the ChatGPT Web runtime. Check the Biscuit Application Support folder and try again.")
        case .runtimeBusy:
            return BiscuitLocalization.string("Another ChatGPT Web runtime operation is still in progress. Wait for it to finish, then try again.")
        case .sidecarBundleMissing:
            return BiscuitLocalization.string("The ChatGPT Web provider files are missing from this Biscuit build. Reinstall or rebuild Biscuit.")
        case .sidecarLaunch:
            return BiscuitLocalization.string("Biscuit could not start its private Electron Web runtime. Verify or replace it and try again.")
        case .sidecarExited:
            return BiscuitLocalization.string("The ChatGPT Web provider stopped unexpectedly. Reconnect or restart Biscuit before trying again.")
        case .protocolFailure:
            return BiscuitLocalization.string("The ChatGPT Web provider returned an invalid local response. Restart Biscuit and try again.")
        case .provider(let category):
            return Self.message(for: category, login: false, retained: false)
        case .login(let category, let retained):
            return Self.message(for: category, login: true, retained: retained)
        }
    }

    private static func message(for category: String, login: Bool, retained: Bool) -> String {
        let message: String
        switch category {
        case "login_required":
            message = BiscuitLocalization.string("Connect your ChatGPT account in Biscuit's dedicated browser before using this route. No other provider was used.")
        case "reconnect_required":
            message = BiscuitLocalization.string("The saved ChatGPT Web session needs to be reconnected. Biscuit did not fall back to Codex or an API route.")
        case "browser_runtime_missing":
            message = BiscuitLocalization.string("Biscuit's dedicated Electron Web runtime is not available. Install the verified runtime in Settings.")
        case "login_browser_closed":
            message = BiscuitLocalization.string("The dedicated sign-in browser closed before Continue. No ChatGPT session was captured.")
        case "model_unavailable":
            message = BiscuitLocalization.string("The requested ChatGPT Web model is unavailable. Biscuit never substitutes a different model; choose the model in ChatGPT and select Browser-selected ChatGPT model.")
        case "plan_limit":
            message = BiscuitLocalization.string("The ChatGPT account or selected model reached a plan or usage limit. This route uses ChatGPT chat allowance, not Codex quota, and remains subject to plan and model limits.")
        case "prompt_too_long":
            message = BiscuitLocalization.string("The text is too long for the selected ChatGPT Web model. Shorten it and try again.")
        case "timeout":
            message = BiscuitLocalization.string(login ? "ChatGPT Web sign-in timed out. Start again when ready." : "The ChatGPT Web request timed out. Check the connection and try again.")
        case "cancelled":
            message = BiscuitLocalization.string(login ? "ChatGPT Web sign-in was canceled." : "The ChatGPT Web request was canceled. Any partial answer is incomplete.")
        case "cancelled_before_send":
            message = BiscuitLocalization.string("The ChatGPT Web request was canceled before any text was sent.")
        case "cancelled_after_stop":
            message = BiscuitLocalization.string("ChatGPT Web stopped generating. Any partial answer is incomplete; run again when ready.")
        case "cancelled_already_settled":
            message = BiscuitLocalization.string("ChatGPT Web had already stopped generating when cancellation settled. Any partial answer is incomplete.")
        case "generation_stop_unconfirmed":
            message = BiscuitLocalization.string("Biscuit could not confirm that ChatGPT Web stopped generating. Wait for the current response to finish, then quit and reopen Biscuit before retrying. The saved session was preserved.")
        case "account_access":
            message = BiscuitLocalization.string("The ChatGPT account could not access this Web request. Check the signed-in account and plan.")
        case "empty_response":
            message = BiscuitLocalization.string("ChatGPT Web completed without returning an answer. Check the selected model and try again.")
        case "incomplete_response":
            message = BiscuitLocalization.string("The ChatGPT Web response ended before completion. Any partial answer is incomplete.")
        case "tool_invariant_failed":
            message = BiscuitLocalization.string("ChatGPT Web displayed a tool-approval action. Biscuit stopped the request; no local tools are enabled.")
        case "busy":
            message = BiscuitLocalization.string("The ChatGPT Web provider is finishing another operation. Wait a moment and try again.")
        case "private_directory_invalid":
            message = BiscuitLocalization.string("Biscuit could not securely open its private ChatGPT Web data folder. Check the Biscuit Application Support folder.")
        case "configuration":
            message = BiscuitLocalization.string("The ChatGPT Web provider is missing its private runtime configuration. Restart Biscuit and try again.")
        case "disconnect_failed":
            message = BiscuitLocalization.string("Biscuit could not disconnect this session without changing its preserved browser profile. No profile data was removed.")
        case "shutting_down":
            message = BiscuitLocalization.string("The ChatGPT Web provider is shutting down. Try again after Biscuit restarts.")
        default:
            message = BiscuitLocalization.string(login
                ? "ChatGPT Web sign-in could not be verified. Check the Biscuit-owned browser and try again."
                : "The ChatGPT Web request failed. Check the dedicated browser and saved session, then try again.")
        }
        guard login, retained else { return message }
        return BiscuitLocalization.format("%1$@ Your previous verified ChatGPT Web session was retained.", arguments: [message])
}
}

private struct ElectronRuntimeArtifact {
    let architecture: String
    let archiveName: String
    let archiveSHA256: String
    let executableSHA256: String

    static func current() throws -> ElectronRuntimeArtifact {
        #if arch(arm64)
        return ElectronRuntimeArtifact(
            architecture: "arm64",
            archiveName: "electron-v41.10.7-darwin-arm64.zip",
            archiveSHA256: "7497a1f398c7bcac208fce96c73d297b1d63924624361a1a21930cd666cc4bbc",
            executableSHA256: "0c23b9764481d57cd769318ec81b42e8337ed7d1cad241b82592d88a80ef8a64"
        )
        #elseif arch(x86_64)
        return ElectronRuntimeArtifact(
            architecture: "x86_64",
            archiveName: "electron-v41.10.7-darwin-x64.zip",
            archiveSHA256: "e48bb52a1694ba839d98239fe103bab7d90939b2afecc3672a5311b06cd88c03",
            executableSHA256: "260bd7753918fa9f5d7207c4f78cbf7376e753947b7d65ed6bb8582d854150c7"
        )
        #else
        throw ChatGPTWebFailure.unsupportedArchitecture
        #endif
    }

    var downloadURL: URL {
        URL(string: "https://github.com/electron/electron/releases/download/v41.10.7/\(archiveName)")!
    }
}
private struct ChatGPTWebProfileIdentity: Codable, Equatable {
    static let schemaName = "biscuit.chatgpt-web.profile-identity.v1"
    let schema: String
    let userDataPath: String
    let appName: String
    let partition: String

    init(userDataPath: String, appName: String, partition: String) {
        schema = Self.schemaName
        self.userDataPath = userDataPath
        self.appName = appName
        self.partition = partition
    }
}

@MainActor
final class ChatGPTWebRuntimeManager {
    static let shared = ChatGPTWebRuntimeManager()
    static let modelPreferenceKey = "language.chatgptWeb.modelSlug"
    static let profileIdentityPreferenceKey = "language.chatgptWeb.profileIdentity"

    private let fileManager = FileManager.default
    private var installInProgress = false
    private init() {}

    var webHomeURL: URL {
        Self.dataRootURL.appendingPathComponent("chatgpt-web", isDirectory: true)
    }

    var runtimeDirectoryURL: URL? {
        guard let artifact = try? ElectronRuntimeArtifact.current() else { return nil }
        return webHomeURL.appendingPathComponent("electron-v41.10.7-\(artifact.architecture)", isDirectory: true)
    }

    var runtimeIsPresent: Bool {
        if let override = ProcessInfo.processInfo.environment["BISCUIT_CHATGPT_WEB_ELECTRON_APP_PATH"], !override.isEmpty {
            return fileManager.isExecutableFile(atPath: Self.executableURL(for: URL(fileURLWithPath: (override as NSString).expandingTildeInPath)).path)
        }
        guard let payloadRoot = runtimeDirectoryURL else { return false }
        return fileManager.isExecutableFile(atPath: Self.executableURL(inPayloadRoot: payloadRoot).path)
    }

    var browserRuntimeIsPresent: Bool { runtimeIsPresent }

    var storedSessionExists: Bool {
        fileManager.fileExists(atPath: descriptorURL.path)
            || fileManager.fileExists(atPath: profileIdentityURL.path)
            || fileManager.fileExists(atPath: webHomeURL.appendingPathComponent("profile", isDirectory: true).path)
    }

    var descriptorURL: URL {
        webHomeURL.appendingPathComponent("electron-host.json", isDirectory: false)
    }

    var profileIdentityURL: URL {
        webHomeURL.appendingPathComponent("profile-identity.json", isDirectory: false)
    }

    func verifiedRuntimeURL() async throws -> URL {
        let artifact = try ElectronRuntimeArtifact.current()
        if let override = ProcessInfo.processInfo.environment["BISCUIT_CHATGPT_WEB_ELECTRON_APP_PATH"], !override.isEmpty {
            let appURL = URL(fileURLWithPath: (override as NSString).expandingTildeInPath).standardizedFileURL
            let executable = Self.executableURL(for: appURL)
            guard Self.fileType(at: executable) == S_IFREG,
                  fileManager.isExecutableFile(atPath: executable.path),
                  try await Self.sha256(fileURL: executable) == artifact.executableSHA256 else {
                throw ChatGPTWebFailure.runtimeIntegrity
            }
            return executable
        }
        guard let payloadRoot = runtimeDirectoryURL else { throw ChatGPTWebFailure.unsupportedArchitecture }
        guard Self.fileType(at: payloadRoot) == S_IFDIR else { throw ChatGPTWebFailure.runtimeMissing }
        return try await Self.verifiedRuntimeURL(
            inPayloadRoot: payloadRoot,
            expectedExecutableSHA256: artifact.executableSHA256,
            fileManager: fileManager
        )
    }

    static func verifiedRuntimeURL(
        inPayloadRoot payloadRoot: URL,
        expectedExecutableSHA256: String,
        fileManager: FileManager = .default
    ) async throws -> URL {
        let appURL = appURL(inPayloadRoot: payloadRoot)
        let executable = executableURL(for: appURL)
        let license = payloadRoot.appendingPathComponent("LICENSE", isDirectory: false)
        let chromiumNotices = payloadRoot.appendingPathComponent("LICENSES.chromium.html", isDirectory: false)
        guard Self.fileType(at: appURL) == S_IFDIR,
              Self.fileType(at: executable) == S_IFREG,
              fileManager.isExecutableFile(atPath: executable.path),
              try await Self.sha256(fileURL: executable) == expectedExecutableSHA256,
              fileManager.isReadableFile(atPath: license.path),
              fileManager.isReadableFile(atPath: chromiumNotices.path) else {
            throw ChatGPTWebFailure.runtimeIntegrity
        }
        return executable
    }

    func installRuntime(consented: Bool, replacing: Bool = false) async throws -> URL {
        guard consented else { throw ChatGPTWebFailure.consentRequired }
        guard !installInProgress else { throw ChatGPTWebFailure.runtimeBusy }
        if !replacing, let installed = try? await verifiedRuntimeURL() { return installed }
        installInProgress = true
        defer { installInProgress = false }
        let artifact = try ElectronRuntimeArtifact.current()
        guard let destination = runtimeDirectoryURL else { throw ChatGPTWebFailure.unsupportedArchitecture }
        do {
            try prepareWebHome()
            let staging = webHomeURL.appendingPathComponent(".electron-install-\(UUID().uuidString)", isDirectory: true)
            try Self.makePrivate(staging)
            defer { try? fileManager.removeItem(at: staging) }

            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.timeoutIntervalForRequest = 120
            configuration.timeoutIntervalForResource = 600
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            var request = URLRequest(url: artifact.downloadURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 120)
            request.httpMethod = "GET"
            let (downloadedURL, response) = try await session.download(for: request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let finalURL = response.url, finalURL.scheme?.lowercased() == "https",
                  ["github.com", "release-assets.githubusercontent.com"].contains(finalURL.host?.lowercased() ?? "") else {
                throw ChatGPTWebFailure.runtimeDownload
            }
            let archiveURL = staging.appendingPathComponent(artifact.archiveName, isDirectory: false)
            try fileManager.moveItem(at: downloadedURL, to: archiveURL)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: archiveURL.path)
            guard try await Self.sha256(fileURL: archiveURL) == artifact.archiveSHA256 else {
                throw ChatGPTWebFailure.runtimeIntegrity
            }
            let payload = staging.appendingPathComponent("payload", isDirectory: true)
            try Self.makePrivate(payload)
            try await Task.detached(priority: .utility) {
                let unzip = Process()
                unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
                unzip.arguments = ["-q", archiveURL.path, "-d", payload.path]
                unzip.standardOutput = FileHandle.nullDevice
                unzip.standardError = FileHandle.nullDevice
                try unzip.run()
                unzip.waitUntilExit()
                guard unzip.terminationStatus == 0 else { throw ChatGPTWebFailure.runtimeExtraction }
            }.value
            try Task.checkCancellation()
            _ = try await Self.verifiedRuntimeURL(
                inPayloadRoot: payload,
                expectedExecutableSHA256: artifact.executableSHA256,
                fileManager: fileManager
            )

            let backup = webHomeURL.appendingPathComponent(".electron-backup-\(UUID().uuidString)", isDirectory: true)
            let hadPrevious = Self.fileType(at: destination) == S_IFDIR
            if hadPrevious { try fileManager.moveItem(at: destination, to: backup) }
            do {
                try fileManager.moveItem(at: payload, to: destination)
                try Self.makePrivate(destination)
                let installed = try await verifiedRuntimeURL()
                if hadPrevious { try? fileManager.removeItem(at: backup) }
                return installed
            } catch {
                if Self.fileType(at: destination) != nil { try? fileManager.removeItem(at: destination) }
                if hadPrevious { try? fileManager.moveItem(at: backup, to: destination) }
                throw error
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as ChatGPTWebFailure {
            throw failure
        } catch {
            throw ChatGPTWebFailure.runtimeDownload
        }
    }

    func removeRuntime() throws {
        guard !installInProgress else { throw ChatGPTWebFailure.runtimeBusy }
        guard let directory = runtimeDirectoryURL else { return }
        do {
            try Self.makePrivate(webHomeURL)
            if Self.fileType(at: directory) != nil { try fileManager.removeItem(at: directory) }
            let entries = try fileManager.contentsOfDirectory(at: webHomeURL, includingPropertiesForKeys: nil)
            for entry in entries where entry.lastPathComponent.hasPrefix(".electron-install-") || entry.lastPathComponent.hasPrefix(".electron-backup-") {
                guard Self.fileType(at: entry) == S_IFDIR else { continue }
                try fileManager.removeItem(at: entry)
            }
        } catch {
            throw ChatGPTWebFailure.runtimeStorage
        }
    }

    func prepareWebHome() throws {
        try Self.makePrivate(webHomeURL)
        try Self.makePrivate(webHomeURL.appendingPathComponent("tmp", isDirectory: true))
        try persistProfileIdentity()
    }

    private func persistProfileIdentity() throws {
        guard let values = BiscuitPreferences.defaults.dictionary(forKey: Self.profileIdentityPreferenceKey) else { return }
        guard let userDataPath = values["userDataPath"] as? String,
              let appName = values["appName"] as? String,
              let partition = values["partition"] as? String,
              userDataPath.hasPrefix("/"),
              URL(fileURLWithPath: userDataPath).standardizedFileURL.path == userDataPath,
              Self.fileType(at: URL(fileURLWithPath: userDataPath)) == S_IFDIR,
              !appName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              appName.utf16.count <= 128,
              partition.hasPrefix("persist:"),
              partition.utf16.count <= 128 else {
            throw ChatGPTWebFailure.runtimeStorage
        }
        let identity = ChatGPTWebProfileIdentity(userDataPath: userDataPath, appName: appName, partition: partition)
        let data = try JSONEncoder().encode(identity)
        if let fileType = Self.fileType(at: profileIdentityURL) {
            guard fileType == S_IFREG,
                  let attributes = try? fileManager.attributesOfItem(atPath: profileIdentityURL.path),
                  let size = (attributes[.size] as? NSNumber)?.intValue,
                  size <= 4096,
                  let savedData = try? Data(contentsOf: profileIdentityURL),
                  let saved = try? JSONDecoder().decode(ChatGPTWebProfileIdentity.self, from: savedData),
                  saved == identity else {
                throw ChatGPTWebFailure.runtimeStorage
            }
        } else {
            do { try data.write(to: profileIdentityURL, options: .atomic) }
            catch { throw ChatGPTWebFailure.runtimeStorage }
        }
        do { try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: profileIdentityURL.path) }
        catch { throw ChatGPTWebFailure.runtimeStorage }
    }

    private static var dataRootURL: URL {
        if let override = ProcessInfo.processInfo.environment["BISCUIT_DATA_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("biscuit", isDirectory: true)
    }

    private static func appURL(inPayloadRoot payloadRoot: URL) -> URL {
        payloadRoot.appendingPathComponent("Electron.app", isDirectory: true)
    }

    private static func executableURL(inPayloadRoot payloadRoot: URL) -> URL {
        executableURL(for: appURL(inPayloadRoot: payloadRoot))
    }

    private static func executableURL(for appURL: URL) -> URL {
        if appURL.lastPathComponent == "Electron" { return appURL }
        return appURL.appendingPathComponent("Contents/MacOS/Electron", isDirectory: false)
    }

    private nonisolated static func fileType(at url: URL) -> mode_t? {
        var info = stat()
        let result = url.path.withCString { Darwin.lstat($0, &info) }
        guard result == 0 else { return nil }
        return info.st_mode & S_IFMT
    }

    private static func makePrivate(_ directory: URL) throws {
        if Self.fileType(at: directory) == nil {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        guard Self.fileType(at: directory) == S_IFDIR else { throw ChatGPTWebFailure.runtimeStorage }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    private nonisolated static func sha256(fileURL: URL) async throws -> String {
        try await Task.detached(priority: .utility) {
            guard Self.fileType(at: fileURL) == S_IFREG else { throw ChatGPTWebFailure.runtimeIntegrity }
            let handle = try FileHandle(forReadingFrom: fileURL)
            defer { try? handle.close() }
            var hasher = SHA256()
            while let bytes = try handle.read(upToCount: 64 * 1024), !bytes.isEmpty { hasher.update(data: bytes) }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
    }
}

@MainActor
final class ChatGPTWebProvider {
    static let shared = ChatGPTWebProvider()
    let runtime = ChatGPTWebRuntimeManager.shared
    private let sidecar = ChatGPTWebSidecarClient.shared
    private(set) var lastKnownStatus: ChatGPTWebStatus?
    private init() {}

    var selectedModelSlug: String? {
        BiscuitPreferences.defaults.string(forKey: ChatGPTWebRuntimeManager.modelPreferenceKey)
    }

    func setSelectedModelSlug(_ slug: String?) {
        if let slug, !slug.isEmpty { BiscuitPreferences.defaults.set(slug, forKey: ChatGPTWebRuntimeManager.modelPreferenceKey) }
        else { BiscuitPreferences.defaults.removeObject(forKey: ChatGPTWebRuntimeManager.modelPreferenceKey) }
    }

    func status(reconcileStopState: Bool = true) async throws -> ChatGPTWebStatus {
        let (runtimeURL, home) = try await prepareSidecar()
        let status = try await sidecar.status(runtimeURL: runtimeURL, webHome: home, reconcileStopState: reconcileStopState)
        lastKnownStatus = status
        return status
    }

    func login(onBrowserOpened: @escaping @MainActor () -> Void) async throws -> ChatGPTWebStatus {
        let (runtimeURL, home) = try await prepareSidecar()
        try await sidecar.login(runtimeURL: runtimeURL, webHome: home, onBrowserOpened: onBrowserOpened)
        let status = try await sidecar.status(runtimeURL: runtimeURL, webHome: home, reconcileStopState: false)
        lastKnownStatus = status
        return status
    }

    func continueLogin() { sidecar.continueLogin() }
    func cancelLogin() { sidecar.cancelLogin() }

    func stream(
        text: String,
        instructions: String,
        onText: @escaping (String) -> Void,
        beforeRun: @escaping @MainActor () throws -> Void = {}
    ) async throws -> String {
        let (runtimeURL, home) = try await prepareSidecar()
        let status = try await sidecar.status(runtimeURL: runtimeURL, webHome: home, reconcileStopState: false)
        lastKnownStatus = status
        guard status.connected else { throw ChatGPTWebFailure.provider(status.needsReconnect ? "reconnect_required" : "login_required") }
        guard let modelSlug = ChatGPTWebModelSelection.requestSlug(
            savedSlug: selectedModelSlug,
            defaultSlug: status.defaultModelSlug,
            routeInventory: status.modelRoutes
        ) else {
            throw ChatGPTWebFailure.provider("model_unavailable")
        }
        try Task.checkCancellation()
        try beforeRun()
        return try await sidecar.run(runtimeURL: runtimeURL, webHome: home, text: text, instructions: instructions, modelSlug: modelSlug, onText: onText)
    }

    func disconnect() async throws {
        let (runtimeURL, home) = try await prepareSidecar()
        try await sidecar.disconnect(runtimeURL: runtimeURL, webHome: home)
        lastKnownStatus = nil
    }

    func installRuntime(consented: Bool, replacing: Bool = false) async throws {
        await sidecar.shutdown()
        if replacing || !runtime.runtimeIsPresent { _ = try await runtime.installRuntime(consented: consented, replacing: replacing) }
    }

    func removeRuntime() async throws {
        await sidecar.shutdown()
        try runtime.removeRuntime()
    }

    func shutdown() async { await sidecar.shutdown() }
    func shutdownForTermination(_ completion: @escaping @MainActor () -> Void) -> Bool { sidecar.shutdownForTermination(completion) }

    private func prepareSidecar() async throws -> (URL, URL) {
        let runtimeURL = try await runtime.verifiedRuntimeURL()
        try runtime.prepareWebHome()
        return (runtimeURL, runtime.webHomeURL)
    }
}

@MainActor
private final class ChatGPTWebSidecarClient {
    static let shared = ChatGPTWebSidecarClient()

    private enum PendingOperation {
        case status(CheckedContinuation<ChatGPTWebStatus, Error>)
        case run(CheckedContinuation<String, Error>, onText: (String) -> Void, output: String)
        case login(CheckedContinuation<Void, Error>, onBrowserOpened: @MainActor () -> Void)
        case disconnect(CheckedContinuation<Void, Error>)
    }

    private let fileManager = FileManager.default
    private let writeQueue = DispatchQueue(label: "org.biscuit.ChatGPTWebElectron.stdin")
    private var process: Process?
    private var input: FileHandle?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var outputBuffer = Data()
    private var errorBuffer = Data()
    private var pending: [String: PendingOperation] = [:]
    private var startupWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var cancellationTimers: [String: Task<Void, Never>] = [:]
    private var isReady = false
    private var isStopping = false
    private var shutdownCompletions: [@MainActor () -> Void] = []

    private init() {}

    func status(runtimeURL: URL, webHome: URL, reconcileStopState: Bool) async throws -> ChatGPTWebStatus {
        let id = Self.newID()
        return try await withTaskCancellationHandler {
            try await ensureStarted(runtimeURL: runtimeURL, webHome: webHome)
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                pending[id] = .status(continuation)
                do { try send(["type": "status", "id": id, "reconcileStopState": reconcileStopState]) }
                catch { settle(id, with: .failure(ChatGPTWebFailure.sidecarExited)) }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.abandon(id: id) } }
    }

    func login(runtimeURL: URL, webHome: URL, onBrowserOpened: @escaping @MainActor () -> Void) async throws {
        let id = Self.newID()
        try await withTaskCancellationHandler {
            try await ensureStarted(runtimeURL: runtimeURL, webHome: webHome)
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = .login(continuation, onBrowserOpened: onBrowserOpened)
                do { try send(["type": "login", "id": id, "timeoutMs": 600_000]) }
                catch { settle(id, with: .failure(ChatGPTWebFailure.sidecarExited)) }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.cancelLogin(id: id) } }
    }

    func run(runtimeURL: URL, webHome: URL, text: String, instructions: String, modelSlug: String, onText: @escaping (String) -> Void) async throws -> String {
        guard !text.isEmpty, text.utf16.count <= 200_000,
              !instructions.isEmpty, instructions.utf16.count <= 8_000,
              !modelSlug.isEmpty, modelSlug.utf16.count <= 160 else {
            throw ChatGPTWebFailure.provider("invalid_request")
        }
        let id = Self.newID()
        return try await withTaskCancellationHandler {
            try await ensureStarted(runtimeURL: runtimeURL, webHome: webHome)
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                pending[id] = .run(continuation, onText: onText, output: "")
                do { try send(["type": "run", "id": id, "text": text, "instructions": instructions, "modelSlug": modelSlug]) }
                catch { settle(id, with: .failure(ChatGPTWebFailure.sidecarExited)) }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.cancelRun(id: id) } }
    }

    func disconnect(runtimeURL: URL, webHome: URL) async throws {
        let id = Self.newID()
        try await withTaskCancellationHandler {
            try await ensureStarted(runtimeURL: runtimeURL, webHome: webHome)
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = .disconnect(continuation)
                do { try send(["type": "disconnect", "id": id]) }
                catch { settle(id, with: .failure(ChatGPTWebFailure.sidecarExited)) }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.abandon(id: id) } }
    }

    func continueLogin() {
        guard let id = pending.first(where: { if case .login = $0.value { return true }; return false })?.key else { return }
        try? send(["type": "login_continue", "id": id])
    }

    func cancelLogin() {
        guard let id = pending.first(where: { if case .login = $0.value { return true }; return false })?.key else { return }
        cancelLogin(id: id)
    }

    func shutdown() async {
        await withCheckedContinuation { continuation in beginShutdown { continuation.resume() } }
    }

    func shutdownForTermination(_ completion: @escaping @MainActor () -> Void) -> Bool {
        guard process != nil else { return false }
        beginShutdown(completion)
        return true
    }

    private func beginShutdown(_ completion: @escaping @MainActor () -> Void) {
        guard let process else {
            completion()
            return
        }
        shutdownCompletions.append(completion)
        guard !isStopping else { return }
        isStopping = true
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        if isReady { try? send(["type": "shutdown"]) }
        DispatchQueue.global(qos: .utility).async {
            if process.isRunning, exited.wait(timeout: .now() + 3) == .timedOut {
                process.terminate()
                if process.isRunning, exited.wait(timeout: .now() + 1) == .timedOut {
                    _ = Darwin.kill(process.processIdentifier, SIGKILL)
                    _ = exited.wait(timeout: .now() + 1)
                }
            }
            RunLoop.main.perform(inModes: [.common, .modalPanel]) {
                MainActor.assumeIsolated {
                    self.finishProcess(process, failure: ChatGPTWebFailure.sidecarExited)
                    let completions = self.shutdownCompletions
                    self.shutdownCompletions.removeAll()
                    completions.forEach { $0() }
                }
            }
        }
    }

    private func ensureStarted(runtimeURL: URL, webHome: URL) async throws {
        guard !isStopping else { throw ChatGPTWebFailure.sidecarExited }
        if process == nil || process?.isRunning == false {
            try start(runtimeURL: runtimeURL, webHome: webHome)
        }
        let waiterID = UUID()
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if isReady { continuation.resume() }
                else if process?.isRunning == true {
                    startupWaiters[waiterID] = continuation
                    DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
                        Task { @MainActor in self?.failStartupWaiter(waiterID, error: ChatGPTWebFailure.sidecarLaunch) }
                    }
                } else { continuation.resume(throwing: ChatGPTWebFailure.sidecarLaunch) }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.failStartupWaiter(waiterID, error: CancellationError()) } }
    }

    private func start(runtimeURL: URL, webHome: URL) throws {
        guard let resources = Bundle.main.resourceURL?.appendingPathComponent("ChatGPTWeb", isDirectory: true) else {
            throw ChatGPTWebFailure.sidecarBundleMissing
        }
        let bootstrap = resources.appendingPathComponent("electron-main.cjs", isDirectory: false)
        let driver = resources.appendingPathComponent("electron-driver.cjs", isDirectory: false)
        let nodeModules = resources.appendingPathComponent("node_modules", isDirectory: true)
        guard fileManager.isReadableFile(atPath: bootstrap.path),
              fileManager.isReadableFile(atPath: driver.path),
              fileManager.fileExists(atPath: nodeModules.appendingPathComponent("playwright-core/package.json").path),
              fileManager.isExecutableFile(atPath: runtimeURL.path) else {
            throw ChatGPTWebFailure.sidecarBundleMissing
        }
        let temporary = webHome.appendingPathComponent("tmp", isDirectory: true)
        let stdout = Pipe()
        let stderr = Pipe()
        let stdin = Pipe()
        let child = Process()
        child.executableURL = runtimeURL
        child.arguments = [bootstrap.path]
        child.currentDirectoryURL = resources
        child.standardInput = stdin
        child.standardOutput = stdout
        child.standardError = stderr
        child.environment = [
            "HOME": NSHomeDirectory(),
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "TMPDIR": temporary.path,
            "LANG": "en_US.UTF-8",
            "BISCUIT_CHATGPT_WEB_HOME": webHome.path,
            "BISCUIT_CHATGPT_WEB_DESCRIPTOR": webHome.appendingPathComponent("electron-host.json").path,
        ]
        do { try child.run() }
        catch { throw ChatGPTWebFailure.sidecarLaunch }
        process = child
        input = stdin.fileHandleForWriting
        outputPipe = stdout
        errorPipe = stderr
        outputBuffer.removeAll(keepingCapacity: true)
        isReady = false
        isStopping = false
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { Task { @MainActor [weak self] in self?.sidecarOutputClosed(child) } }
            else { Task { @MainActor [weak self] in self?.consume(data) } }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            Task { @MainActor [weak self] in self?.consumeDiagnostics(data) }
        }
        child.terminationHandler = { [weak self] terminated in
            Task { @MainActor [weak self] in self?.sidecarTerminated(terminated) }
        }
    }

    private func send(_ message: [String: Any]) throws {
        guard let input else { throw ChatGPTWebFailure.sidecarExited }
        let encoded: Data
        do { encoded = try JSONSerialization.data(withJSONObject: message, options: [.fragmentsAllowed]) }
        catch { throw ChatGPTWebFailure.protocolFailure }
        guard encoded.count <= 1_000_000 else { throw ChatGPTWebFailure.provider("invalid_request") }
        var line = encoded
        line.append(0x0A)
        let handle = input
        writeQueue.async { [weak self] in
            do { try handle.write(contentsOf: line) }
            catch { Task { @MainActor [weak self] in self?.failAll(with: ChatGPTWebFailure.sidecarExited) } }
        }
    }

    private func consumeDiagnostics(_ data: Data) {
        errorBuffer.append(data)
        let newline = Data([0x0A])
        while let range = errorBuffer.range(of: newline) {
            let line = Data(errorBuffer[..<range.lowerBound])
            errorBuffer.removeSubrange(..<range.upperBound)
            guard let text = String(data: line, encoding: .utf8)?.lowercased(),
                  text.contains("warning") || text.contains("error") || text.contains("failed") else { continue }
            let category: String
            if ["security", "sandbox", "certificate", "tls", "ssl"].contains(where: text.contains) {
                category = "security warning"
            } else if text.contains("warning") {
                category = "runtime warning"
            } else {
                category = "runtime error"
            }
            FileHandle.standardError.write(Data("Biscuit ChatGPT Web: \(category)\n".utf8))
        }
        if errorBuffer.count > 16_384 {
            errorBuffer.removeAll(keepingCapacity: true)
            FileHandle.standardError.write(Data("Biscuit ChatGPT Web: diagnostic line truncated\n".utf8))
        }
    }
    private func consume(_ data: Data) {
        outputBuffer.append(data)
        let newline = Data([0x0A])
        while let range = outputBuffer.range(of: newline) {
            let line = Data(outputBuffer[..<range.lowerBound])
            outputBuffer.removeSubrange(..<range.upperBound)
            guard line.count <= 1_000_000,
                  let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                failAll(with: ChatGPTWebFailure.protocolFailure)
                process?.terminate()
                return
            }
            handle(message)
        }
        if outputBuffer.count > 1_000_000 {
            failAll(with: ChatGPTWebFailure.protocolFailure)
            process?.terminate()
        }
    }

    private func handle(_ message: [String: Any]) {
        guard let type = message["type"] as? String else { failAll(with: ChatGPTWebFailure.protocolFailure); return }
        if type == "ready" {
            isReady = true
            let waiters = Array(startupWaiters.values)
            startupWaiters.removeAll()
            waiters.forEach { $0.resume() }
            return
        }
        if type == "fatal" { failAll(with: ChatGPTWebFailure.sidecarLaunch); process?.terminate(); return }
        guard let id = message["id"] as? String, let operation = pending[id] else { return }
        switch type {
        case "status":
            guard case .status = operation,
                  let data = try? JSONSerialization.data(withJSONObject: message),
                  let status = try? JSONDecoder().decode(ChatGPTWebStatus.self, from: data) else {
                settle(id, with: .failure(ChatGPTWebFailure.protocolFailure)); return
            }
            settle(id, with: .status(status))
        case "started", "login_started":
            return
        case "delta":
            guard case .run(let continuation, let onText, var output) = operation,
                  let delta = message["text"] as? String, !delta.isEmpty else { return }
            output.append(contentsOf: delta)
            pending[id] = .run(continuation, onText: onText, output: output)
            onText(output)
        case "snapshot":
            guard case .run(let continuation, let onText, _) = operation,
                  let output = message["text"] as? String else { return }
            pending[id] = .run(continuation, onText: onText, output: output)
            onText(output)
        case "done":
            guard case .run(_, _, let output) = operation else { return }
            settle(id, with: .text(output))
        case "login_browser_opened":
            guard case .login(_, let onBrowserOpened) = operation else { return }
            onBrowserOpened()
        case "login_succeeded":
            guard case .login = operation else { return }
            settle(id, with: .void)
        case "disconnected":
            guard case .disconnect = operation else { return }
            settle(id, with: .void)
        case "login_failed":
            guard case .login = operation else { return }
            let category = message["category"] as? String ?? "browser_error"
            let retained = message["previousSessionRetained"] as? Bool ?? false
            settle(id, with: .failure(ChatGPTWebFailure.login(category, previousSessionRetained: retained)))
        case "error":
            let category = message["category"] as? String ?? "browser_error"
            if case .login = operation { settle(id, with: .failure(ChatGPTWebFailure.login(category, previousSessionRetained: false))) }
            else if category == "cancelled", let stopState = message["remoteStopState"] as? String {
                switch stopState {
                case "stopped": settle(id, with: .failure(ChatGPTWebFailure.provider("cancelled_after_stop")))
                case "not_submitted": settle(id, with: .failure(ChatGPTWebFailure.provider("cancelled_before_send")))
                case "already_settled": settle(id, with: .failure(ChatGPTWebFailure.provider("cancelled_already_settled")))
                default: settle(id, with: .failure(ChatGPTWebFailure.provider(category)))
                }
            } else { settle(id, with: .failure(ChatGPTWebFailure.provider(category))) }
        default:
            settle(id, with: .failure(ChatGPTWebFailure.protocolFailure))
        }
    }

    private enum Completion {
        case status(ChatGPTWebStatus)
        case text(String)
        case void
        case failure(Error)
    }

    private func settle(_ id: String, with completion: Completion) {
        cancellationTimers.removeValue(forKey: id)?.cancel()
        guard let operation = pending.removeValue(forKey: id) else { return }
        switch (operation, completion) {
        case (.status(let continuation), .status(let status)): continuation.resume(returning: status)
        case (.run(let continuation, _, _), .text(let text)): continuation.resume(returning: text)
        case (.login(let continuation, _), .void), (.disconnect(let continuation), .void): continuation.resume()
        case (.status(let continuation), .failure(let error)): continuation.resume(throwing: error)
        case (.run(let continuation, _, _), .failure(let error)): continuation.resume(throwing: error)
        case (.login(let continuation, _), .failure(let error)): continuation.resume(throwing: error)
        case (.disconnect(let continuation), .failure(let error)): continuation.resume(throwing: error)
        default:
            switch operation {
            case .status(let continuation): continuation.resume(throwing: ChatGPTWebFailure.protocolFailure)
            case .run(let continuation, _, _): continuation.resume(throwing: ChatGPTWebFailure.protocolFailure)
            case .login(let continuation, _): continuation.resume(throwing: ChatGPTWebFailure.protocolFailure)
            case .disconnect(let continuation): continuation.resume(throwing: ChatGPTWebFailure.protocolFailure)
            }
        }
    }

    private func failAll(with error: Error) {
        for id in Array(pending.keys) { settle(id, with: .failure(error)) }
        let waiters = Array(startupWaiters.values)
        startupWaiters.removeAll()
        waiters.forEach { $0.resume(throwing: error) }
    }

    private func abandon(id: String) {
        guard pending[id] != nil else { return }
        settle(id, with: .failure(CancellationError()))
    }

    private func cancelRun(id: String) {
        guard case .run = pending[id] else { return }
        do { try send(["type": "run_cancel", "id": id]) }
        catch { settle(id, with: .failure(CancellationError())); return }
        cancellationTimers[id]?.cancel()
        cancellationTimers[id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.settleCancelledRunIfNeeded(id)
        }
    }

    private func settleCancelledRunIfNeeded(_ id: String) async {
        guard case .run = pending[id] else { return }
        settle(id, with: .failure(CancellationError()))
        await shutdown()
    }

    private func cancelLogin(id: String) {
        guard case .login = pending[id] else { return }
        do { try send(["type": "login_cancel", "id": id]) }
        catch { settle(id, with: .failure(ChatGPTWebFailure.sidecarExited)); return }
        cancellationTimers[id]?.cancel()
        cancellationTimers[id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.settleCancelledLoginIfNeeded(id)
        }
    }

    private func settleCancelledLoginIfNeeded(_ id: String) async {
        guard case .login = pending[id] else { return }
        settle(id, with: .failure(ChatGPTWebFailure.sidecarExited))
        await shutdown()
    }

    private func failStartupWaiter(_ id: UUID, error: Error) {
        guard let continuation = startupWaiters.removeValue(forKey: id) else { return }
        continuation.resume(throwing: error)
        guard startupWaiters.isEmpty, !isReady, let child = process, child.isRunning else { return }
        child.terminate()
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard self?.process === child, child.isRunning else { return }
            _ = Darwin.kill(child.processIdentifier, SIGKILL)
        }
    }

    private func sidecarOutputClosed(_ child: Process) {
        guard process === child, !isStopping else { return }
        if child.isRunning {
            child.terminate()
            Task {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if child.isRunning { _ = Darwin.kill(child.processIdentifier, SIGKILL) }
            }
        }
        finishProcess(child, failure: ChatGPTWebFailure.sidecarExited)
    }

    private func sidecarTerminated(_ child: Process) {
        guard !isStopping else { return }
        finishProcess(child, failure: ChatGPTWebFailure.sidecarExited)
    }

    private func finishProcess(_ child: Process, failure: Error) {
        guard process === child else { return }
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        try? input?.close()
        try? outputPipe?.fileHandleForReading.close()
        try? errorPipe?.fileHandleForReading.close()
        input = nil
        outputPipe = nil
        errorPipe = nil
        process = nil
        isReady = false
        isStopping = false
        outputBuffer.removeAll(keepingCapacity: false)
        errorBuffer.removeAll(keepingCapacity: false)
        failAll(with: failure)
    }

    private static func newID() -> String { "req_" + UUID().uuidString.replacingOccurrences(of: "-", with: "") }
}

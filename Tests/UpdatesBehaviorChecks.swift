import CryptoKit
import Darwin
import Foundation

/// Exercised by the isolated native smoke app. The only modified bundles live in a
/// temporary fixture directory; HTTP is served by this process on loopback only.
#if BISCUIT_UPDATES_STANDALONE
@main
#endif
@MainActor
enum BiscuitUpdateBehaviorChecks {
    static func main() async {
        guard CommandLine.arguments.count == 2 else {
            fputs("Usage: updater-checks <isolated-source-app>\n", stderr)
            exit(2)
        }
        do { try await run(sourceApp: URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)) }
        catch {
            fputs("Updater behavior checks failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    private struct ZIPEntry {
        let name: String
        let bytes: Data
        let mode: UInt16
    }

    static func run(sourceApp: URL) async throws {
        try verifyVersionOrdering()
        try verifyAutomaticCheckPolicy()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("biscuit-updater-check-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceExecutable = sourceApp.appendingPathComponent("Contents/MacOS/biscuit", isDirectory: false)
        let sourceDigest = try digest(Data(contentsOf: sourceExecutable))
        let currentVersion = try bundleVersion(sourceApp)
        let sourceBundleIdentifier = try bundleIdentifier(sourceApp)
        guard let parsedCurrent = BiscuitSemanticVersion(currentVersion), parsedCurrent.patch < UInt64.max else {
            throw Failure(description: "The smoke app has no valid current semantic version.")
        }
        let nextVersion = "\(parsedCurrent.major).\(parsedCurrent.minor).\(parsedCurrent.patch + 1)-preview.1"
        let releaseTag = "v\(nextVersion)"

        let applications = root.appendingPathComponent("Applications", isDirectory: true)
        try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: false)
        let installedApp = applications.appendingPathComponent("biscuit.app", isDirectory: true)
        try FileManager.default.copyItem(at: sourceApp, to: installedApp)

        let candidateApp = root.appendingPathComponent("biscuit.app", isDirectory: true)
        try FileManager.default.copyItem(at: installedApp, to: candidateApp)
        try updateBundleVersion(candidateApp, version: nextVersion)
        try signFixture(candidateApp, identifier: sourceBundleIdentifier)
        let wrongIdentityRoot = root.appendingPathComponent("wrong-identity", isDirectory: true)
        try FileManager.default.createDirectory(at: wrongIdentityRoot, withIntermediateDirectories: false)
        let wrongIdentityApp = wrongIdentityRoot.appendingPathComponent("biscuit.app", isDirectory: true)
        try FileManager.default.copyItem(at: installedApp, to: wrongIdentityApp)
        try updateBundleVersion(wrongIdentityApp, version: nextVersion)
        let wrongBundleIdentifier = "\(sourceBundleIdentifier).wrong-candidate"
        try updateBundleIdentifier(wrongIdentityApp, identifier: wrongBundleIdentifier)
        try signFixture(wrongIdentityApp, identifier: wrongBundleIdentifier)
        let wrongIdentityArchiveURL = wrongIdentityRoot.appendingPathComponent("wrong-identity.zip", isDirectory: false)
        try createAppArchive(wrongIdentityApp, at: wrongIdentityArchiveURL)
        let wrongIdentityArchive = try Data(contentsOf: wrongIdentityArchiveURL, options: .mappedIfSafe)
        let archiveURL = root.appendingPathComponent("release.zip", isDirectory: false)
        try createAppArchive(candidateApp, at: archiveURL)
        let archive = try Data(contentsOf: archiveURL, options: .mappedIfSafe)
        let unsafeArchive = try zip(entries: [
            ZIPEntry(name: "biscuit.app/", bytes: Data(), mode: 0o040755),
            ZIPEntry(name: "biscuit.app/../escape.txt", bytes: Data("unsafe".utf8), mode: 0o100644)
        ])
        let symlinkArchive = try zip(entries: [
            ZIPEntry(name: "biscuit.app/", bytes: Data(), mode: 0o040755),
            ZIPEntry(name: "biscuit.app/Contents/Resources/escape", bytes: Data("../../outside".utf8), mode: 0o120777)
        ])
        let server = try LoopbackHTTPFixture(
            routes: [:],
            files: [
                "/release.zip": archive,
                "/wrong-identity.zip": wrongIdentityArchive,
                "/unsafe.zip": unsafeArchive,
                "/symlink.zip": symlinkArchive
            ]
        )
        defer { server.stop() }
        let routes = try makeReleaseRoutes(
            tag: releaseTag,
            version: nextVersion,
            goodDigest: digest(archive),
            archiveURL: server.url("/release.zip").absoluteString,
            oldPreviewTag: "v0.1.0-preview.1"
        )
        server.configure(routes: routes)

        let baseClient = server.client(path: "/api/newer")
        let check: BiscuitUpdateCheck
        do { check = try await baseClient.check(installedVersion: currentVersion) }
        catch { throw Failure(description: "Loopback GitHub release metadata request failed: \(error.localizedDescription)") }
        guard case .updateAvailable(let release) = check,
              release.version == BiscuitSemanticVersion(nextVersion), release.tag == releaseTag else {
            throw Failure(description: "A genuinely newer prerelease was not identified as an update.")
        }

        let older = try await server.client(path: "/api/old-preview").check(installedVersion: currentVersion)
        try require(older == .upToDate, "The saved v0.1.0-preview.1 tag must not be described as newer than the current 1.0.0 line.")
        let samePreview = try await server.client(path: "/api/newer").check(installedVersion: nextVersion)
        try require(samePreview == .upToDate, "An installed preview release must not be offered as an update to itself.")
        let stableAfterPreview = try await server.client(path: "/api/newer").check(installedVersion: currentVersion)
        try require(stableAfterPreview == check, "The newer prerelease comparison must be consistent across checks.")
        let none = try await server.client(path: "/api/no-release").check(installedVersion: currentVersion)
        try require(none == .noPublishedRelease, "An empty release list must be reported as no published release.")
        let incompatible = try await server.client(path: "/api/no-compatible").check(installedVersion: currentVersion)
        try require(incompatible == .noCompatibleRelease, "Non-semantic release tags must not be treated as compatible versions.")
        try await requireFailure(.releaseAssetUnavailable, from: {
            _ = try await server.client(path: "/api/no-asset").check(installedVersion: currentVersion)
        })
        try await requireFailure(.invalidReleaseDigest, from: {
            _ = try await server.client(path: "/api/bad-digest").check(installedVersion: currentVersion)
        })
        try await requireFailure(.sourceUnavailable, from: {
            _ = try await server.client(path: "/api/missing").check(installedVersion: currentVersion)
        })

        let dataRoot = root.appendingPathComponent("UserData", isDirectory: true)
        try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: false)
        let userData = dataRoot.appendingPathComponent("preserve-me.txt", isDirectory: false)
        try Data("fixture user data remains unchanged".utf8).write(to: userData)
        let installer = BiscuitUpdateInstaller(expectedBundleIdentifier: sourceBundleIdentifier)
        let wrongIdentityRelease = BiscuitUpdateRelease(
            tag: release.tag,
            version: release.version,
            archiveURL: server.url("/wrong-identity.zip"),
            sha256: digest(wrongIdentityArchive)
        )
        try await requireFailure(.appBundleInvalid, from: {
            _ = try await installer.install(wrongIdentityRelease, using: baseClient, at: installedApp, dataRoot: dataRoot)
        })
        try require(try bundleVersion(installedApp) == currentVersion,
                    "A mismatched candidate bundle identifier must leave the copied installation unchanged.")
        try require(!FileManager.default.fileExists(atPath: dataRoot.appendingPathComponent("Updates/Rollbacks", isDirectory: true).path),
                    "A mismatched candidate bundle identifier must not create a rollback copy.")

        let tampered = BiscuitUpdateRelease(
            tag: release.tag,
            version: release.version,
            archiveURL: release.archiveURL,
            sha256: String(repeating: "0", count: 64)
        )
        try await requireFailure(.integrityCheckFailed, from: {
            _ = try await installer.install(tampered, using: baseClient, at: installedApp, dataRoot: dataRoot)
        })
        try require(try bundleVersion(installedApp) == currentVersion, "A digest failure must leave the copied installation unchanged.")
        try require(!FileManager.default.fileExists(atPath: dataRoot.appendingPathComponent("Updates/Rollbacks", isDirectory: true).path),
                    "An unverified archive must not create a rollback or touch installation state.")

        let unsafeRelease = BiscuitUpdateRelease(
            tag: release.tag,
            version: release.version,
            archiveURL: server.url("/unsafe.zip"),
            sha256: digest(unsafeArchive)
        )
        try await requireFailure(.unsafeArchive, from: {
            _ = try await installer.install(unsafeRelease, using: baseClient, at: installedApp, dataRoot: dataRoot)
        })
        try require(!FileManager.default.fileExists(atPath: root.appendingPathComponent("escape.txt").path),
                    "A traversal entry must not write outside the isolated extraction root.")
        try require(try bundleVersion(installedApp) == currentVersion, "A rejected path traversal archive must leave the copied installation unchanged.")

        let symlinkRelease = BiscuitUpdateRelease(
            tag: release.tag,
            version: release.version,
            archiveURL: server.url("/symlink.zip"),
            sha256: digest(symlinkArchive)
        )
        try await requireFailure(.unsafeArchive, from: {
            _ = try await installer.install(symlinkRelease, using: baseClient, at: installedApp, dataRoot: dataRoot)
        })
        try require(try bundleVersion(installedApp) == currentVersion, "An archive symlink must be rejected before replacing the copied installation.")

        let rollback = try await installer.install(release, using: baseClient, at: installedApp, dataRoot: dataRoot)
        try require(try bundleVersion(installedApp) == nextVersion, "A verified release must install into the isolated app copy.")
        try require(try bundleVersion(rollback) == currentVersion, "The prior app must be preserved as a verified rollback copy.")
        try require(try bundleIdentifier(installedApp) == sourceBundleIdentifier,
                    "The installed candidate must retain the caller's bundle identifier.")
        try require(try bundleIdentifier(rollback) == sourceBundleIdentifier,
                    "The rollback copy must retain the caller's bundle identifier.")
        try require(try Data(contentsOf: userData) == Data("fixture user data remains unchanged".utf8),
                    "Updater installation must not change unrelated user data.")
        try installer.restore(rollback, at: installedApp)
        try require(try bundleVersion(installedApp) == currentVersion, "The isolated rollback path must restore the previous app version.")
        try require(FileManager.default.fileExists(atPath: rollback.path), "Rollback must remain recoverable after restoration.")
        try require(try digest(Data(contentsOf: sourceExecutable)) == sourceDigest,
                    "The running QA source app must not be changed by isolated updater checks.")
        try require(server.requestCount(for: "/release.zip") == 2,
                    "Only the tampered-digest and successful install cases should download the valid loopback archive.")

        print("Biscuit updater local HTTP, SemVer, bundle-identity enforcement, verification, isolated install, rollback, and user-data preservation checks passed")
    }


    private static func verifyVersionOrdering() throws {
        func version(_ value: String) throws -> BiscuitSemanticVersion {
            guard let parsed = BiscuitSemanticVersion(value) else { throw Failure(description: "Invalid fixture semantic version: \(value)") }
            return parsed
        }
        try require(try version("v0.1.0-preview.1") < version("1.0.0"), "The saved preview tag is older than 1.0.0.")
        try require(try version("1.0.1-preview.1") > version("1.0.0"), "A newer patch prerelease is newer than the current stable version.")
        try require(try version("1.0.1-alpha.2") < version("1.0.1-alpha.10"), "Numeric prerelease identifiers use numeric ordering.")
        try require(try version("1.0.1-rc.1") < version("1.0.1"), "A prerelease sorts before its stable version.")
        try require(try version("1.0.1+build.1") == version("1.0.1+build.2"), "SemVer build metadata does not change precedence or identity.")
        try require(BiscuitSemanticVersion("01.0.0") == nil, "SemVer leading zeroes in the numeric core are invalid.")
    }

    private static func verifyAutomaticCheckPolicy() throws {
        let suite = "org.biscuit.updater-check.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { throw Failure(description: "Isolated updater preferences are unavailable.") }
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        try require(!BiscuitUpdatePreferences.automaticChecksEnabled(defaults: defaults), "Automatic checks must be opt-in by default.")
        try require(!BiscuitUpdatePreferences.shouldCheckAutomatically(defaults: defaults, now: now), "Disabled automatic checks must never schedule a request.")
        BiscuitUpdatePreferences.setAutomaticChecksEnabled(true, defaults: defaults)
        try require(BiscuitUpdatePreferences.shouldCheckAutomatically(defaults: defaults, now: now), "Explicit opt-in permits a first automatic check.")
        BiscuitUpdatePreferences.recordCheck(at: now, defaults: defaults)
        try require(!BiscuitUpdatePreferences.shouldCheckAutomatically(defaults: defaults, now: now.addingTimeInterval(60)), "Repeated launches are throttled within the check interval.")
        try require(BiscuitUpdatePreferences.shouldCheckAutomatically(defaults: defaults, now: now.addingTimeInterval(BiscuitUpdatePreferences.automaticCheckInterval)),
                    "An opted-in check becomes eligible after the sparse interval.")
        BiscuitUpdatePreferences.setAutomaticChecksEnabled(false, defaults: defaults)
        try require(!BiscuitUpdatePreferences.shouldCheckAutomatically(defaults: defaults, now: now.addingTimeInterval(2 * BiscuitUpdatePreferences.automaticCheckInterval)),
                    "Turning automatic checks off prevents later requests.")
    }

    private static func makeReleaseRoutes(
        tag: String,
        version: String,
        goodDigest: String,
        archiveURL: String,
        oldPreviewTag: String
    ) throws -> [String: Data] {
        func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
        func record(_ tag: String, assets: [[String: Any]] = []) -> [String: Any] {
            ["tag_name": tag, "draft": false, "assets": assets]
        }
        let goodAsset: [[String: Any]] = [[
            "name": "biscuit-\(version)-macos-universal.zip",
            "browser_download_url": archiveURL,
            "digest": "sha256:\(goodDigest)"
        ]]
        let malformedAsset: [[String: Any]] = [[
            "name": "biscuit-\(version)-macos-universal.zip",
            "browser_download_url": archiveURL,
            "digest": "sha256:not-a-valid-digest"
        ]]
        return [
            "/api/newer": try json([record(tag, assets: goodAsset)]),
            "/api/old-preview": try json([record(oldPreviewTag)]),
            "/api/no-release": try json([]),
            "/api/no-compatible": try json([record("not-a-version")]),
            "/api/no-asset": try json([record(tag)]),
            "/api/bad-digest": try json([record(tag, assets: malformedAsset)])
        ]
    }

    private static func bundleVersion(_ app: URL) throws -> String {
        let info = app.appendingPathComponent("Contents/Info.plist", isDirectory: false)
        let value = try PropertyListSerialization.propertyList(from: Data(contentsOf: info), format: nil)
        guard let dictionary = value as? [String: Any],
              let version = dictionary["CFBundleShortVersionString"] as? String else {
            throw Failure(description: "Fixture app has no short bundle version.")
        }
        return version
    }
    private static func bundleIdentifier(_ app: URL) throws -> String {
        let info = app.appendingPathComponent("Contents/Info.plist", isDirectory: false)
        let value = try PropertyListSerialization.propertyList(from: Data(contentsOf: info), format: nil)
        guard let dictionary = value as? [String: Any],
              let identifier = dictionary["CFBundleIdentifier"] as? String,
              !identifier.isEmpty else {
            throw Failure(description: "Fixture app has no bundle identifier.")
        }
        return identifier
    }


    private static func updateBundleVersion(_ app: URL, version: String) throws {
        let infoURL = app.appendingPathComponent("Contents/Info.plist", isDirectory: false)
        let value = try PropertyListSerialization.propertyList(from: Data(contentsOf: infoURL), format: nil)
        guard var dictionary = value as? [String: Any] else { throw Failure(description: "Fixture Info.plist is invalid.") }
        dictionary["CFBundleShortVersionString"] = version
        dictionary["CFBundleVersion"] = "\(version.split(separator: ".").prefix(3).joined(separator: "."))"
        let data = try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
        try data.write(to: infoURL, options: .atomic)
    }
    private static func updateBundleIdentifier(_ app: URL, identifier: String) throws {
        let infoURL = app.appendingPathComponent("Contents/Info.plist", isDirectory: false)
        let value = try PropertyListSerialization.propertyList(from: Data(contentsOf: infoURL), format: nil)
        guard var dictionary = value as? [String: Any] else { throw Failure(description: "Fixture Info.plist is invalid.") }
        dictionary["CFBundleIdentifier"] = identifier
        let data = try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
        try data.write(to: infoURL, options: .atomic)
    }


    private static func signFixture(_ app: URL, identifier: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--force", "--sign", "-", "--identifier", identifier, "--deep", app.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run(); process.waitUntilExit() }
        catch { throw Failure(description: "Could not sign the isolated updater fixture: \(error.localizedDescription)") }
        guard process.terminationStatus == 0 else { throw Failure(description: "Could not sign the isolated updater fixture.") }
    }

    private static func createAppArchive(_ app: URL, at archive: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--norsrc", "--noextattr", "--noqtn", "--noacl", "--nopersistRootless", "--keepParent", app.path, archive.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run(); process.waitUntilExit() }
        catch { throw Failure(description: "Could not create the isolated updater ZIP fixture: \(error.localizedDescription)") }
        guard process.terminationStatus == 0 else { throw Failure(description: "Could not create the isolated updater ZIP fixture.") }
    }

    private static func zip(entries: [ZIPEntry]) throws -> Data {
        var local = Data()
        var central = Data()
        for entry in entries {
            let name = Data(entry.name.utf8)
            guard name.count <= Int(UInt16.max), entry.bytes.count <= Int(UInt32.max) else {
                throw Failure(description: "Invalid synthetic ZIP entry.")
            }
            let offset = UInt32(local.count)
            append32(0x04034b50, to: &local)
            append16(20, to: &local); append16(0, to: &local); append16(0, to: &local)
            append16(0, to: &local); append16(0, to: &local)
            append32(0, to: &local)
            append32(UInt32(entry.bytes.count), to: &local); append32(UInt32(entry.bytes.count), to: &local)
            append16(UInt16(name.count), to: &local); append16(0, to: &local)
            local.append(name); local.append(entry.bytes)

            append32(0x02014b50, to: &central)
            append16(UInt16((3 << 8) | 20), to: &central); append16(20, to: &central)
            append16(0, to: &central); append16(0, to: &central)
            append16(0, to: &central); append16(0, to: &central)
            append32(0, to: &central)
            append32(UInt32(entry.bytes.count), to: &central); append32(UInt32(entry.bytes.count), to: &central)
            append16(UInt16(name.count), to: &central); append16(0, to: &central); append16(0, to: &central)
            append16(0, to: &central); append16(0, to: &central)
            append32(UInt32(entry.mode) << 16, to: &central); append32(offset, to: &central)
            central.append(name)
        }
        guard entries.count <= Int(UInt16.max), local.count <= Int(UInt32.max), central.count <= Int(UInt32.max) else {
            throw Failure(description: "Synthetic ZIP exceeds the classic ZIP format limits.")
        }
        let centralOffset = UInt32(local.count)
        local.append(central)
        append32(0x06054b50, to: &local)
        append16(0, to: &local); append16(0, to: &local)
        append16(UInt16(entries.count), to: &local); append16(UInt16(entries.count), to: &local)
        append32(UInt32(central.count), to: &local); append32(centralOffset, to: &local); append16(0, to: &local)
        return local
    }

    private static func append16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
    }

    private static func append32(_ value: UInt32, to data: inout Data) {
        append16(UInt16(truncatingIfNeeded: value), to: &data)
        append16(UInt16(truncatingIfNeeded: value >> 16), to: &data)
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw Failure(description: message) }
    }

    private static func requireFailure(
        _ expected: BiscuitUpdateFailure,
        from operation: () async throws -> Void
    ) async throws {
        do {
            try await operation()
            throw Failure(description: "Expected updater failure \(expected), but the operation succeeded.")
        } catch let failure as BiscuitUpdateFailure {
            guard failure == expected else { throw Failure(description: "Unexpected updater failure: \(failure)") }
        }
    }

    private final class LoopbackHTTPFixture: @unchecked Sendable {
        private let listener: Int32
        private let queue = DispatchQueue(label: "org.biscuit.updater-http-fixture")
        private var routes: [String: Data]
        private let files: [String: Data]
        private let lock = NSLock()
        private var stopped = false
        private var counts: [String: Int] = [:]
        let port: UInt16

        init(routes: [String: Data], files: [String: Data]) throws {
            self.routes = routes
            self.files = files
            let socketDescriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
            guard socketDescriptor >= 0 else { throw Failure(description: "Could not create the updater loopback socket.") }
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = 0
            address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(socketDescriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bound == 0, Darwin.listen(socketDescriptor, 8) == 0 else {
                Darwin.close(socketDescriptor)
                throw Failure(description: "Could not bind the updater test server to loopback.")
            }
            var actual = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let named = withUnsafeMutablePointer(to: &actual) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.getsockname(socketDescriptor, $0, &length)
                }
            }
            guard named == 0 else {
                Darwin.close(socketDescriptor)
                throw Failure(description: "Could not read the updater loopback port.")
            }
            self.port = UInt16(bigEndian: actual.sin_port)
            self.listener = socketDescriptor
            queue.async { [weak self] in self?.acceptConnections() }
        }

        func url(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(port)\(path)")! }
        func client(path: String) -> BiscuitUpdateClient {
            BiscuitUpdateClient(apiURL: url(path), allowedAssetHosts: ["127.0.0.1"], allowLoopbackHTTP: true)
        }
        func configure(routes: [String: Data]) {
            lock.lock(); defer { lock.unlock() }
            self.routes = routes
        }

        func requestCount(for path: String) -> Int {
            lock.lock(); defer { lock.unlock() }
            return counts[path, default: 0]
        }

        func stop() {
            lock.lock()
            let shouldClose = !stopped
            stopped = true
            lock.unlock()
            if shouldClose {
                _ = shutdown(listener, Int32(SHUT_RDWR))
                Darwin.close(listener)
            }
        }

        private func acceptConnections() {
            while true {
                let connection = Darwin.accept(listener, nil, nil)
                if connection < 0 {
                    lock.lock(); let shouldStop = stopped; lock.unlock()
                    if shouldStop { return }
                    continue
                }
                serve(connection)
                Darwin.close(connection)
                lock.lock(); let shouldStop = stopped; lock.unlock()
                if shouldStop { return }
            }
        }

        private func serve(_ connection: Int32) {
            var noPipe: Int32 = 1
            _ = setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &noPipe, socklen_t(MemoryLayout<Int32>.size))
            var request = Data()
            var chunk = [UInt8](repeating: 0, count: 4096)
            while request.count < 64 * 1024, request.range(of: Data("\r\n\r\n".utf8)) == nil {
                let received = chunk.withUnsafeMutableBytes { bytes in
                    recv(connection, bytes.baseAddress, bytes.count, 0)
                }
                guard received > 0 else { return }
                request.append(contentsOf: chunk.prefix(received))
            }
            guard let firstLine = String(data: request, encoding: .utf8)?.components(separatedBy: "\r\n").first,
                  let target = firstLine.split(separator: " ").dropFirst().first,
                  let components = URLComponents(string: "http://fixture\(target)") else { return }
            let path = components.path
            lock.lock()
            counts[path, default: 0] += 1
            let route = routes[path]
            lock.unlock()
            let body = route ?? files[path]
            let status = body == nil ? "404 Not Found" : "200 OK"
            let contentType = route == nil ? "application/zip" : "application/json"
            let header = Data("HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body?.count ?? 0)\r\nConnection: close\r\n\r\n".utf8)
            send(header, to: connection)
            if let body { send(body, to: connection) }
        }

        private func send(_ data: Data, to connection: Int32) {
            data.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return }
                var offset = 0
                while offset < bytes.count {
                    let sent = Darwin.send(connection, base.advanced(by: offset), bytes.count - offset, 0)
                    if sent <= 0 { return }
                    offset += sent
                }
            }
        }
    }
}


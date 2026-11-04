import CryptoKit
import Darwin
import Foundation

/// Preference and timing policy for explicit, sparse update checks. Checks only read
/// public GitHub release metadata; installation always requires a separate user action.
enum BiscuitUpdatePreferences {
    static let automaticChecksKey = "updates.automaticallyCheck"
    static let lastCheckKey = "updates.lastCheckAt"
    static let automaticChecksDefault = false
    static let automaticCheckInterval: TimeInterval = 24 * 60 * 60

    static func automaticChecksEnabled(defaults: UserDefaults) -> Bool {
        guard defaults.object(forKey: automaticChecksKey) != nil else { return automaticChecksDefault }
        return defaults.bool(forKey: automaticChecksKey)
    }

    static func setAutomaticChecksEnabled(_ enabled: Bool, defaults: UserDefaults) {
        defaults.set(enabled, forKey: automaticChecksKey)
    }

    static func shouldCheckAutomatically(defaults: UserDefaults, now: Date = Date()) -> Bool {
        guard automaticChecksEnabled(defaults: defaults) else { return false }
        guard let last = defaults.object(forKey: lastCheckKey) as? Date else { return true }
        return now.timeIntervalSince(last) >= automaticCheckInterval
    }

    static func recordCheck(at date: Date = Date(), defaults: UserDefaults) {
        defaults.set(date, forKey: lastCheckKey)
    }

    static func dataRoot(fileManager: FileManager = .default) -> URL {
        if let override = ProcessInfo.processInfo.environment["BISCUIT_DATA_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
        }
        return fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("biscuit", isDirectory: true)
    }
}

struct BiscuitSemanticVersion: Hashable, Comparable, CustomStringConvertible {
    private enum Identifier: Hashable {
        case numeric(String)
        case text(String)
    }

    let major: UInt64
    let minor: UInt64
    let patch: UInt64
    private let prerelease: [Identifier]

    var description: String {
        let base = "\(major).\(minor).\(patch)"
        guard !prerelease.isEmpty else { return base }
        return base + "-" + prerelease.map { identifier in
            switch identifier {
            case .numeric(let value), .text(let value): return value
            }
        }.joined(separator: ".")
    }

    init?(_ source: String) {
        var value = source
        if value.first == "v" || value.first == "V" { value.removeFirst() }
        let buildComponents = value.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)
        guard buildComponents.count <= 2 else { return nil }
        if buildComponents.count == 2 {
            let metadata = buildComponents[1].split(separator: ".", omittingEmptySubsequences: false)
            guard !metadata.isEmpty, metadata.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy({
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45
            }) }) else { return nil }
            value = String(buildComponents[0])
        }
        guard !value.isEmpty else { return nil }
        let components = value.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let core = components[0].split(separator: ".", omittingEmptySubsequences: false)
        guard core.count == 3,
              let major = Self.numericComponent(core[0]),
              let minor = Self.numericComponent(core[1]),
              let patch = Self.numericComponent(core[2]) else { return nil }
        let identifiers: [Identifier]
        if components.count == 1 {
            identifiers = []
        } else {
            let rawIdentifiers = components[1].split(separator: ".", omittingEmptySubsequences: false)
            guard !rawIdentifiers.isEmpty else { return nil }
            var parsed: [Identifier] = []
            for raw in rawIdentifiers {
                let item = String(raw)
                guard !item.isEmpty, item.utf8.allSatisfy({
                    (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45
                }) else { return nil }
                if item.utf8.allSatisfy({ (48...57).contains($0) }) {
                    guard item == "0" || item.first != "0" else { return nil }
                    parsed.append(.numeric(item))
                } else {
                    parsed.append(.text(item))
                }
            }
            identifiers = parsed
        }
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = identifiers
    }

    private static func numericComponent(_ value: Substring) -> UInt64? {
        guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }),
              value == "0" || value.first != "0" else { return nil }
        return UInt64(value)
    }

    static func < (lhs: BiscuitSemanticVersion, rhs: BiscuitSemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        if lhs.prerelease.isEmpty { return false }
        if rhs.prerelease.isEmpty { return true }
        for index in 0..<min(lhs.prerelease.count, rhs.prerelease.count) {
            let left = lhs.prerelease[index]
            let right = rhs.prerelease[index]
            if left == right { continue }
            switch (left, right) {
            case (.numeric(let a), .numeric(let b)):
                if a.count != b.count { return a.count < b.count }
                return a < b
            case (.numeric, .text): return true
            case (.text, .numeric): return false
            case (.text(let a), .text(let b)): return a < b
            }
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }
}

struct BiscuitUpdateRelease: Equatable {
    let tag: String
    let version: BiscuitSemanticVersion
    let archiveURL: URL
    let sha256: String?
}

enum BiscuitUpdateCheck: Equatable {
    case updateAvailable(BiscuitUpdateRelease)
    case upToDate
    case noPublishedRelease
    case noCompatibleRelease
}

enum BiscuitUpdateFailure: Error, LocalizedError, Equatable {
    case sourceUnavailable
    case releaseAssetUnavailable
    case invalidReleaseDigest
    case downloadFailed
    case integrityCheckFailed
    case unsafeArchive
    case extractionFailed
    case appBundleInvalid
    case releaseVersionMismatch
    case incompatibleArchitecture
    case unsupportedSystemVersion
    case signatureInvalid
    case installFailed
    case rollbackFailed

    var errorDescription: String? {
        let key: String
        switch self {
        case .sourceUnavailable: key = "The Biscuit update source is not available yet."
        case .releaseAssetUnavailable: key = "A published Biscuit release has no compatible macOS update archive."
        case .invalidReleaseDigest: key = "The release archive has an unsupported or malformed SHA-256 digest."
        case .downloadFailed: key = "The update archive could not be downloaded from the official release source."
        case .integrityCheckFailed: key = "The update archive failed its integrity check. Your installed copy was not changed."
        case .unsafeArchive: key = "The update archive contains unsafe or unsupported paths. Your installed copy was not changed."
        case .extractionFailed: key = "The update archive could not be safely extracted. Your installed copy was not changed."
        case .appBundleInvalid: key = "The update is not a valid Biscuit app bundle. Your installed copy was not changed."
        case .releaseVersionMismatch: key = "The app version does not match the published release. Your installed copy was not changed."
        case .incompatibleArchitecture: key = "The update does not contain the required Mac architectures. Your installed copy was not changed."
        case .unsupportedSystemVersion: key = "This update requires a newer version of macOS. Your installed copy was not changed."
        case .signatureInvalid: key = "The app's code signature did not pass macOS verification. Your installed copy was not changed."
        case .installFailed: key = "The update could not be installed. Your previous app was restored."
        case .rollbackFailed: key = "The update failed and automatic restoration was incomplete. Keep both app copies and contact the Biscuit maintainers."
        }
        return BiscuitLocalization.string(key)
    }
}

private struct GitHubReleaseRecord: Decodable {
    struct Asset: Decodable {
        let name: String
        let browser_download_url: URL
        let digest: String?
    }

    let tag_name: String
    let draft: Bool
    let assets: [Asset]
}
private final class BiscuitUpdateSizeLimitDelegate: NSObject, URLSessionDataDelegate, URLSessionDownloadDelegate, @unchecked Sendable {
    private let maximumBytes: Int64
    private var receivedDataBytes: Int64 = 0

    init(maximumBytes: Int64) {
        self.maximumBytes = maximumBytes
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        receivedDataBytes += Int64(data.count)
        if receivedDataBytes > maximumBytes { dataTask.cancel() }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        if totalBytesWritten > maximumBytes || totalBytesExpectedToWrite > maximumBytes {
            downloadTask.cancel()
        }
    }
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: location.path)[.size]) as? NSNumber,
              size.int64Value <= maximumBytes else {
            downloadTask.cancel()
            return
        }
    }
}


/// Uses only the public, unauthenticated GitHub Releases API for jsal-afk/biscuit.
/// The endpoint and allowed hosts are injectable only for offline/loopback behavior checks.
final class BiscuitUpdateClient: @unchecked Sendable {
    static let releasesURL = URL(string: "https://api.github.com/repos/jsal-afk/biscuit/releases")!
    static let archiveLimit: Int64 = 512 * 1024 * 1024
    private let apiURL: URL
    private let allowedAssetHosts: Set<String>
    private let allowLoopbackHTTP: Bool
    private let session: URLSession
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.apiURL = Self.releasesURL
        self.allowedAssetHosts = ["github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com"]
        self.allowLoopbackHTTP = false
        self.fileManager = fileManager
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        self.session = URLSession(configuration: configuration)
    }

    /// Internal loopback-only seam used by the updater's local HTTP behavior checks.
    init(apiURL: URL, allowedAssetHosts: Set<String>, allowLoopbackHTTP: Bool, fileManager: FileManager = .default) {
        self.apiURL = apiURL
        self.allowedAssetHosts = Set(allowedAssetHosts.map { $0.lowercased() })
        self.allowLoopbackHTTP = allowLoopbackHTTP
        self.fileManager = fileManager
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        self.session = URLSession(configuration: configuration)
    }

    func check(installedVersion rawInstalledVersion: String) async throws -> BiscuitUpdateCheck {
        guard let installedVersion = BiscuitSemanticVersion(rawInstalledVersion) else {
            throw BiscuitUpdateFailure.sourceUnavailable
        }
        var pageURL: URL? = Self.pageURL(apiURL, page: 1)
        var visited = Set<URL>()
        var releases: [GitHubReleaseRecord] = []
        var pageCount = 0
        while let url = pageURL {
            guard visited.insert(url).inserted, pageCount < 10, Self.isAllowedAPIURL(url, relativeTo: apiURL, allowLoopbackHTTP: allowLoopbackHTTP) else {
                throw BiscuitUpdateFailure.sourceUnavailable
            }
            pageCount += 1
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
            request.httpMethod = "GET"
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
            request.setValue("biscuit-update-check", forHTTPHeaderField: "User-Agent")
            let data: Data
            let response: URLResponse
            do {
                let sizeLimit = BiscuitUpdateSizeLimitDelegate(maximumBytes: 10 * 1024 * 1024)
                (data, response) = try await session.data(for: request, delegate: sizeLimit)
            } catch { throw BiscuitUpdateFailure.sourceUnavailable }
            guard let http = response as? HTTPURLResponse,
                  Self.isAllowedAPIURL(response.url, relativeTo: apiURL, allowLoopbackHTTP: allowLoopbackHTTP) else {
                throw BiscuitUpdateFailure.sourceUnavailable
            }
            if http.statusCode == 404 { throw BiscuitUpdateFailure.sourceUnavailable }
            guard http.statusCode == 200, data.count <= 10 * 1024 * 1024 else {
                throw BiscuitUpdateFailure.sourceUnavailable
            }
            do { releases.append(contentsOf: try JSONDecoder().decode([GitHubReleaseRecord].self, from: data)) }
            catch { throw BiscuitUpdateFailure.sourceUnavailable }
            pageURL = Self.nextPage(in: http.value(forHTTPHeaderField: "Link"), relativeTo: apiURL, allowLoopbackHTTP: allowLoopbackHTTP)
        }

        let published = releases.filter { !$0.draft }
        guard !published.isEmpty else { return .noPublishedRelease }
        let candidates = published.compactMap { record -> (GitHubReleaseRecord, BiscuitSemanticVersion)? in
            guard let version = BiscuitSemanticVersion(record.tag_name) else { return nil }
            return (record, version)
        }
        guard let newest = candidates.max(by: { $0.1 < $1.1 }) else { return .noCompatibleRelease }
        guard installedVersion < newest.1 else { return .upToDate }

        let expectedName = "biscuit-\(newest.1.description)-macos-universal.zip"
        guard let asset = newest.0.assets.first(where: { $0.name == expectedName }),
              Self.isConfiguredReleaseURL(
                asset.browser_download_url,
                tag: newest.0.tag_name,
                archiveName: expectedName,
                allowedHosts: allowedAssetHosts,
                allowLoopbackHTTP: allowLoopbackHTTP
              ) else {
            throw BiscuitUpdateFailure.releaseAssetUnavailable
        }
        let digest: String?
        if let declared = asset.digest {
            guard declared.hasPrefix("sha256:"), declared.count == 71,
                  declared.dropFirst(7).utf8.allSatisfy({
                    (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
                  }) else { throw BiscuitUpdateFailure.invalidReleaseDigest }
            digest = String(declared.dropFirst(7)).lowercased()
        } else {
            digest = nil
        }
        return .updateAvailable(BiscuitUpdateRelease(tag: newest.0.tag_name, version: newest.1, archiveURL: asset.browser_download_url, sha256: digest))
    }

    func download(_ release: BiscuitUpdateRelease, to destination: URL) async throws {
        let expectedName = "biscuit-\(release.version.description)-macos-universal.zip"
        guard BiscuitSemanticVersion(release.tag) == release.version,
              Self.isConfiguredReleaseURL(
                release.archiveURL,
                tag: release.tag,
                archiveName: expectedName,
                allowedHosts: allowedAssetHosts,
                allowLoopbackHTTP: allowLoopbackHTTP
              ) else {
            throw BiscuitUpdateFailure.downloadFailed
        }
        var request = URLRequest(url: release.archiveURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.httpMethod = "GET"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        let sizeLimit = BiscuitUpdateSizeLimitDelegate(maximumBytes: Self.archiveLimit)
        let temporary: URL
        let response: URLResponse
        do { (temporary, response) = try await session.download(for: request, delegate: sizeLimit) }
        catch { throw BiscuitUpdateFailure.downloadFailed }
        defer { try? fileManager.removeItem(at: temporary) }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              Self.isAllowedAssetURL(response.url, allowedHosts: allowedAssetHosts, allowLoopbackHTTP: allowLoopbackHTTP),
              let size = (try? fileManager.attributesOfItem(atPath: temporary.path)[.size]) as? NSNumber,
              size.int64Value > 0, size.int64Value <= Self.archiveLimit else {
            throw BiscuitUpdateFailure.downloadFailed
        }
        do { try fileManager.moveItem(at: temporary, to: destination) }
        catch { throw BiscuitUpdateFailure.downloadFailed }
        guard let expected = release.sha256 else { return }
        do {
            guard try Self.sha256(fileURL: destination, fileManager: fileManager) == expected else {
                try? fileManager.removeItem(at: destination)
                throw BiscuitUpdateFailure.integrityCheckFailed
            }
        } catch let error as BiscuitUpdateFailure {
            throw error
        } catch {
            try? fileManager.removeItem(at: destination)
            throw BiscuitUpdateFailure.integrityCheckFailed
        }
    }

    private static func pageURL(_ base: URL, page: Int) -> URL? {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        var items = components.queryItems ?? []
        items.removeAll(where: { $0.name == "per_page" || $0.name == "page" })
        items.append(URLQueryItem(name: "per_page", value: "100"))
        items.append(URLQueryItem(name: "page", value: String(page)))
        components.queryItems = items
        return components.url
    }

    private static func nextPage(in link: String?, relativeTo base: URL, allowLoopbackHTTP: Bool) -> URL? {
        guard let link else { return nil }
        for part in link.split(separator: ",") {
            let fields = part.split(separator: ";", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count >= 2, fields.dropFirst().contains(where: { $0 == "rel=\"next\"" || $0 == "rel='next'" }),
                  fields[0].first == "<", fields[0].last == ">",
                  let url = URL(string: String(fields[0].dropFirst().dropLast())),
                  isAllowedAPIURL(url, relativeTo: base, allowLoopbackHTTP: allowLoopbackHTTP) else { continue }
            return url
        }
        return nil
    }

    private static func isAllowedAPIURL(_ url: URL?, relativeTo base: URL, allowLoopbackHTTP: Bool) -> Bool {
        guard let url, url.host?.lowercased() == base.host?.lowercased(),
              url.port == base.port, url.user == nil, url.password == nil,
              url.scheme?.lowercased() == base.scheme?.lowercased() else { return false }
        if url.scheme?.lowercased() == "https" { return true }
        return allowLoopbackHTTP && url.scheme?.lowercased() == "http" && isLoopback(url.host)
    }

    private static func isAllowedAssetURL(_ url: URL?, allowedHosts: Set<String>, allowLoopbackHTTP: Bool) -> Bool {
        guard let url, let host = url.host?.lowercased(), url.user == nil, url.password == nil else { return false }
        if url.scheme?.lowercased() == "https" {
            return (url.port == nil || url.port == 443) && allowedHosts.contains(host)
        }
        return allowLoopbackHTTP && url.scheme?.lowercased() == "http" && isLoopback(host)
    }

    private static func isConfiguredReleaseURL(
        _ url: URL,
        tag: String,
        archiveName: String,
        allowedHosts: Set<String>,
        allowLoopbackHTTP: Bool
    ) -> Bool {
        if allowLoopbackHTTP {
            return isAllowedAssetURL(url, allowedHosts: allowedHosts, allowLoopbackHTTP: true)
        }
        guard url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "github.com",
              url.port == nil || url.port == 443,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return false }
        return url.path == "/jsal-afk/biscuit/releases/download/\(tag)/\(archiveName)"
    }

    private static func isLoopback(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "localhost" || host == "::1" || host == "127.0.0.1" || host.hasPrefix("127.")
    }

    fileprivate static func sha256(fileURL: URL, fileManager: FileManager) throws -> String {
        guard BiscuitUpdateInstaller.fileType(at: fileURL) == S_IFREG else { throw BiscuitUpdateFailure.integrityCheckFailed }
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let bytes = try handle.read(upToCount: 64 * 1024), !bytes.isEmpty { hasher.update(data: bytes) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Validates the ZIP central directory before writing any paths. Files are then streamed
/// individually through unzip into newly-created regular files; archive symlinks, aliases,
/// path traversal, duplicate/case-colliding paths and non-app roots are rejected.
private enum BiscuitUpdateArchive {
    private struct Entry {
        let path: String
        let isDirectory: Bool
        let mode: UInt16
        let size: UInt64
    }

    private static let maximumEntries = 100_000
    private static let maximumExpandedBytes: UInt64 = 2 * 1024 * 1024 * 1024
    private static let appRoot = "biscuit.app"

    static func extract(_ archive: URL, into directory: URL, fileManager: FileManager) throws -> URL {
        let entries = try readEntries(archive, fileManager: fileManager)
        guard BiscuitUpdateInstaller.fileType(at: directory) == nil else { throw BiscuitUpdateFailure.unsafeArchive }
        do { try fileManager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        catch { throw BiscuitUpdateFailure.extractionFailed }
        let bundleURL = directory.appendingPathComponent(appRoot, isDirectory: true)
        do { try fileManager.createDirectory(at: bundleURL, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        catch { throw BiscuitUpdateFailure.extractionFailed }

        var directoryModes: [(URL, UInt16)] = []
        var fileEntries: [(Entry, URL)] = []
        for entry in entries where entry.path != "\(appRoot)/" {
            let components = entry.path.split(separator: "/").map(String.init)
            let relative = components.dropFirst().joined(separator: "/")
            guard !relative.isEmpty else { continue }
            let destination = relative.split(separator: "/").reduce(bundleURL) { $0.appendingPathComponent(String($1), isDirectory: false) }
            if entry.isDirectory {
                do { try fileManager.createDirectory(at: destination, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
                catch { throw BiscuitUpdateFailure.extractionFailed }
                directoryModes.append((destination, entry.mode))
            } else {
                let parent = destination.deletingLastPathComponent()
                do { try fileManager.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
                catch { throw BiscuitUpdateFailure.extractionFailed }
                guard BiscuitUpdateInstaller.fileType(at: destination) == nil,
                      fileManager.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                    throw BiscuitUpdateFailure.unsafeArchive
                }
                fileEntries.append((entry, destination))
            }
        }
        try extractEntries(archive, fileEntries: fileEntries)
        for (entry, destination) in fileEntries {
            do { try fileManager.setAttributes([.posixPermissions: NSNumber(value: entry.mode & 0o777)], ofItemAtPath: destination.path) }
            catch { throw BiscuitUpdateFailure.extractionFailed }
        }
        for (url, mode) in directoryModes.reversed() {
            do { try fileManager.setAttributes([.posixPermissions: NSNumber(value: mode & 0o777)], ofItemAtPath: url.path) }
            catch { throw BiscuitUpdateFailure.extractionFailed }
        }
        return bundleURL
    }

    private static func readEntries(_ archive: URL, fileManager: FileManager) throws -> [Entry] {
        guard BiscuitUpdateInstaller.fileType(at: archive) == S_IFREG,
              let sizeNumber = (try? fileManager.attributesOfItem(atPath: archive.path)[.size]) as? NSNumber,
              sizeNumber.int64Value >= 22, sizeNumber.int64Value <= BiscuitUpdateClient.archiveLimit else {
            throw BiscuitUpdateFailure.unsafeArchive
        }
        let totalSize = UInt64(sizeNumber.int64Value)
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: archive) }
        catch { throw BiscuitUpdateFailure.unsafeArchive }
        defer { try? handle.close() }
        let tailSize = min(totalSize, 65_557)
        let tail: Data
        do {
            try handle.seek(toOffset: totalSize - tailSize)
            tail = try handle.read(upToCount: Int(tailSize)) ?? Data()
        } catch { throw BiscuitUpdateFailure.unsafeArchive }
        guard let eocd = findEndRecord(in: tail),
              let disk = u16(tail, eocd + 4), disk == 0,
              let centralDisk = u16(tail, eocd + 6), centralDisk == 0,
              let diskEntries = u16(tail, eocd + 8),
              let entryCount = u16(tail, eocd + 10), diskEntries == entryCount,
              let centralSize32 = u32(tail, eocd + 12), centralSize32 != UInt32.max,
              let centralOffset32 = u32(tail, eocd + 16), centralOffset32 != UInt32.max,
              let commentLength = u16(tail, eocd + 20),
              eocd + 22 + Int(commentLength) == tail.count,
              Int(entryCount) <= maximumEntries else { throw BiscuitUpdateFailure.unsafeArchive }
        let centralSize = UInt64(centralSize32)
        let centralOffset = UInt64(centralOffset32)
        guard centralSize <= 32 * 1024 * 1024,
              centralOffset <= totalSize, centralSize <= totalSize - centralOffset,
              centralOffset + centralSize <= totalSize - tailSize + UInt64(eocd) else {
            throw BiscuitUpdateFailure.unsafeArchive
        }
        let central: Data
        do {
            try handle.seek(toOffset: centralOffset)
            central = try handle.read(upToCount: Int(centralSize)) ?? Data()
        } catch { throw BiscuitUpdateFailure.unsafeArchive }
        guard central.count == Int(centralSize) else { throw BiscuitUpdateFailure.unsafeArchive }

        var entries: [Entry] = []
        entries.reserveCapacity(Int(entryCount))
        var offset = 0
        var totalExpanded: UInt64 = 0
        var paths = Set<String>()
        var filePaths = Set<String>()
        for _ in 0..<entryCount {
            guard u32(central, offset) == 0x02014b50,
                  let creator = u16(central, offset + 4),
                  let flags = u16(central, offset + 8), flags & 0x0001 == 0,
                  let method = u16(central, offset + 10), method == 0 || method == 8,
                  let compressed = u32(central, offset + 20), compressed != UInt32.max,
                  let expanded = u32(central, offset + 24), expanded != UInt32.max,
                  let nameLength = u16(central, offset + 28),
                  let extraLength = u16(central, offset + 30),
                  let commentLength = u16(central, offset + 32),
                  let startDisk = u16(central, offset + 34), startDisk == 0,
                  let attributes = u32(central, offset + 38),
                  let localOffset = u32(central, offset + 42), localOffset != UInt32.max else {
                throw BiscuitUpdateFailure.unsafeArchive
            }
            let end = offset + 46 + Int(nameLength) + Int(extraLength) + Int(commentLength)
            guard nameLength > 0, end <= central.count, localOffset < totalSize,
                  UInt64(compressed) <= BiscuitUpdateClient.archiveLimit,
                  UInt64(expanded) <= maximumExpandedBytes,
                  totalExpanded <= maximumExpandedBytes - UInt64(expanded) else { throw BiscuitUpdateFailure.unsafeArchive }
            let nameData = central.subdata(in: (offset + 46)..<(offset + 46 + Int(nameLength)))
            guard let path = String(data: nameData, encoding: .utf8),
                  path.utf8.allSatisfy({ (32...126).contains($0) }),
                  !path.hasPrefix("/"), !path.contains("\\"), !path.contains(":"), !path.contains("\0") else {
                throw BiscuitUpdateFailure.unsafeArchive
            }
            let isDirectory = path.hasSuffix("/")
            guard !isDirectory || (compressed == 0 && expanded == 0) else {
                throw BiscuitUpdateFailure.unsafeArchive
            }
            let trimmed = isDirectory ? String(path.dropLast()) : path
            let parts = trimmed.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard parts.first == appRoot, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
                throw BiscuitUpdateFailure.unsafeArchive
            }
            let canonical = trimmed.lowercased()
            guard paths.insert(canonical).inserted else { throw BiscuitUpdateFailure.unsafeArchive }
            let versionMadeByOS = creator >> 8
            let mode = UInt16((attributes >> 16) & 0xffff)
            let type = mode & 0o170000
            if versionMadeByOS == 3 || versionMadeByOS == 19 {
                guard type == 0 || type == 0o100000 || type == 0o040000,
                      (isDirectory ? type != 0o100000 : type != 0o040000) else {
                    throw BiscuitUpdateFailure.unsafeArchive
                }
            } else if type != 0 {
                throw BiscuitUpdateFailure.unsafeArchive
            }
            if !isDirectory { filePaths.insert(canonical) }
            entries.append(Entry(path: path, isDirectory: isDirectory, mode: mode == 0 ? (isDirectory ? 0o755 : 0o644) : mode, size: UInt64(expanded)))
            totalExpanded += UInt64(expanded)
            offset = end
        }
        guard offset == central.count,
              entries.contains(where: { $0.path == "\(appRoot)/" }) else { throw BiscuitUpdateFailure.unsafeArchive }
        for entry in entries {
            let parts = entry.path.split(separator: "/").map(String.init)
            guard parts.count <= 1 || !parts.dropLast().enumerated().contains(where: { index, _ in
                let ancestor = parts.prefix(index + 1).joined(separator: "/").lowercased()
                return filePaths.contains(ancestor)
            }) else { throw BiscuitUpdateFailure.unsafeArchive }
        }
        return entries
    }

    private static func extractEntries(_ archive: URL, fileEntries: [(Entry, URL)]) throws {
        guard !fileEntries.isEmpty else { return }
        // `readEntries` validates every path; unzip streams payloads in central-directory order.
        // Declared sizes split that single stream into the precreated regular files below.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", archive.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() }
        catch { throw BiscuitUpdateFailure.extractionFailed }

        let input = pipe.fileHandleForReading
        var received: UInt64 = 0
        do {
            for (entry, destination) in fileEntries {
                let output = try FileHandle(forWritingTo: destination)
                defer { try? output.close() }
                var remaining = entry.size
                while remaining > 0 {
                    let count = Int(min(remaining, 64 * 1024))
                    guard let chunk = try input.read(upToCount: count), !chunk.isEmpty else {
                        throw BiscuitUpdateFailure.extractionFailed
                    }
                    let amount = UInt64(chunk.count)
                    guard amount <= remaining,
                          received <= maximumExpandedBytes,
                          amount <= maximumExpandedBytes - received else {
                        throw BiscuitUpdateFailure.unsafeArchive
                    }
                    try output.write(contentsOf: chunk)
                    remaining -= amount
                    received += amount
                }
                try output.close()
            }
            if let trailing = try input.read(upToCount: 1), !trailing.isEmpty {
                throw BiscuitUpdateFailure.unsafeArchive
            }
        } catch {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            if let failure = error as? BiscuitUpdateFailure { throw failure }
            throw BiscuitUpdateFailure.extractionFailed
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw BiscuitUpdateFailure.extractionFailed }
    }

    private static func findEndRecord(in data: Data) -> Int? {
        guard data.count >= 22 else { return nil }
        for offset in stride(from: data.count - 22, through: max(0, data.count - 65_557), by: -1) {
            if u32(data, offset) == 0x06054b50 { return offset }
        }
        return nil
    }

    private static func u16(_ data: Data, _ offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= data.count else { return nil }
        return UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    private static func u32(_ data: Data, _ offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        return UInt32(data[offset]) | UInt32(data[offset + 1]) << 8 | UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
    }
}

/// Verifies the downloaded app before it can replace anything, saves a private rollback
/// copy, and atomically swaps same-volume app directories. It never requests elevation.
final class BiscuitUpdateInstaller: @unchecked Sendable {
    private let fileManager: FileManager
    private let requiredArchitectures: Set<String>
    private let expectedBundleIdentifier: String

    init(expectedBundleIdentifier: String, fileManager: FileManager = .default, requiredArchitectures: Set<String> = ["arm64", "x86_64"]) {
        self.fileManager = fileManager
        self.requiredArchitectures = requiredArchitectures
        self.expectedBundleIdentifier = expectedBundleIdentifier
    }

    func install(_ release: BiscuitUpdateRelease, using client: BiscuitUpdateClient, at appURL: URL, dataRoot: URL) async throws -> URL {
        let target = appURL.standardizedFileURL
        guard Self.fileType(at: target) == S_IFDIR,
              let parentType = Self.fileType(at: target.deletingLastPathComponent()), parentType == S_IFDIR else {
            throw BiscuitUpdateFailure.installFailed
        }
        let current = try verifyApp(at: target, expectedVersion: nil)
        let staging = target.deletingLastPathComponent().appendingPathComponent(".biscuit-update-\(UUID().uuidString)", isDirectory: true)
        do { try fileManager.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        catch { throw BiscuitUpdateFailure.installFailed }
        var keepStaging = false
        defer { if !keepStaging { try? fileManager.removeItem(at: staging) } }

        let archive = staging.appendingPathComponent("release.zip", isDirectory: false)
        try await client.download(release, to: archive)
        let expanded = staging.appendingPathComponent("expanded", isDirectory: true)
        let candidate = try BiscuitUpdateArchive.extract(archive, into: expanded, fileManager: fileManager)
        let newInfo = try verifyApp(at: candidate, expectedVersion: release.version)
        guard current.architectures == newInfo.architectures else { throw BiscuitUpdateFailure.incompatibleArchitecture }

        let updatesRoot = dataRoot.appendingPathComponent("Updates", isDirectory: true)
        let rollbackRoot = updatesRoot.appendingPathComponent("Rollbacks", isDirectory: true)
        do {
            if Self.fileType(at: dataRoot) == nil {
                try fileManager.createDirectory(at: dataRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
            guard Self.fileType(at: dataRoot) == S_IFDIR else { throw BiscuitUpdateFailure.installFailed }
            if Self.fileType(at: updatesRoot) == nil {
                try fileManager.createDirectory(at: updatesRoot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            }
            guard Self.fileType(at: updatesRoot) == S_IFDIR else { throw BiscuitUpdateFailure.installFailed }
            if Self.fileType(at: rollbackRoot) == nil {
                try fileManager.createDirectory(at: rollbackRoot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            }
            guard Self.fileType(at: rollbackRoot) == S_IFDIR else { throw BiscuitUpdateFailure.installFailed }
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: rollbackRoot.path)
        } catch { throw BiscuitUpdateFailure.installFailed }
        let rollback = rollbackRoot.appendingPathComponent("biscuit-\(current.version.description)-\(UUID().uuidString).app", isDirectory: true)
        do { try fileManager.copyItem(at: target, to: rollback) }
        catch {
            try? fileManager.removeItem(at: rollback)
            throw BiscuitUpdateFailure.installFailed
        }
        do {
            let saved = try verifyApp(at: rollback, expectedVersion: current.version)
            guard saved.architectures == current.architectures else { throw BiscuitUpdateFailure.appBundleInvalid }
        } catch {
            try? fileManager.removeItem(at: rollback)
            throw error
        }

        do { try Self.swapDirectories(target, candidate) }
        catch { throw BiscuitUpdateFailure.installFailed }
        do {
            let installed = try verifyApp(at: target, expectedVersion: release.version)
            guard installed.architectures == current.architectures else { throw BiscuitUpdateFailure.incompatibleArchitecture }
        } catch {
            do {
                try Self.swapDirectories(target, candidate)
                let restored = try verifyApp(at: target, expectedVersion: current.version)
                guard restored.architectures == current.architectures else { throw BiscuitUpdateFailure.rollbackFailed }
            } catch {
                keepStaging = true
                throw BiscuitUpdateFailure.rollbackFailed
            }
            try? fileManager.removeItem(at: rollback)
            throw error
        }
        return rollback
    }

    /// Restore a previously saved version after LaunchServices refuses to open the new app.
    func restore(_ rollbackURL: URL, at appURL: URL) throws {
        let target = appURL.standardizedFileURL
        let backup = rollbackURL.standardizedFileURL
        let saved = try verifyApp(at: backup, expectedVersion: nil)
        let staging = target.deletingLastPathComponent().appendingPathComponent(".biscuit-rollback-\(UUID().uuidString)", isDirectory: true)
        do { try fileManager.copyItem(at: backup, to: staging) }
        catch { throw BiscuitUpdateFailure.rollbackFailed }
        do {
            try Self.swapDirectories(target, staging)
            let restored = try verifyApp(at: target, expectedVersion: saved.version)
            guard restored.architectures == saved.architectures else { throw BiscuitUpdateFailure.rollbackFailed }
            try? fileManager.removeItem(at: staging)
        } catch {
            if Self.fileType(at: target) == S_IFDIR, Self.fileType(at: staging) == S_IFDIR {
                try? Self.swapDirectories(target, staging)
            }
            throw BiscuitUpdateFailure.rollbackFailed
        }
    }

    private struct AppFacts {
        let version: BiscuitSemanticVersion
        let architectures: Set<String>
    }

    private func verifyApp(at url: URL, expectedVersion: BiscuitSemanticVersion?) throws -> AppFacts {
        guard Self.fileType(at: url) == S_IFDIR else { throw BiscuitUpdateFailure.appBundleInvalid }
        let infoURL = url.appendingPathComponent("Contents/Info.plist", isDirectory: false)
        guard Self.fileType(at: infoURL) == S_IFREG,
              let data = try? Data(contentsOf: infoURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              !expectedBundleIdentifier.isEmpty,
              plist["CFBundleIdentifier"] as? String == expectedBundleIdentifier,
              plist["CFBundlePackageType"] as? String == "APPL",
              let executableName = plist["CFBundleExecutable"] as? String,
              Self.safeExecutableName(executableName),
              let rawVersion = plist["CFBundleShortVersionString"] as? String,
              let version = BiscuitSemanticVersion(rawVersion) else { throw BiscuitUpdateFailure.appBundleInvalid }
        if let expectedVersion, expectedVersion != version { throw BiscuitUpdateFailure.releaseVersionMismatch }
        guard Self.supportsCurrentSystem(plist["LSMinimumSystemVersion"] as? String) else {
            throw BiscuitUpdateFailure.unsupportedSystemVersion
        }
        let executable = url.appendingPathComponent("Contents/MacOS", isDirectory: true).appendingPathComponent(executableName, isDirectory: false)
        guard Self.fileType(at: executable) == S_IFREG, fileManager.isExecutableFile(atPath: executable.path) else {
            throw BiscuitUpdateFailure.appBundleInvalid
        }
        guard Self.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", url.path]) == 0 else {
            throw BiscuitUpdateFailure.signatureInvalid
        }
        let (lipoStatus, architectureText) = Self.runCapturing("/usr/bin/lipo", ["-archs", executable.path])
        guard lipoStatus == 0 else { throw BiscuitUpdateFailure.appBundleInvalid }
        let present = Set(architectureText.split(whereSeparator: { $0.isWhitespace }).map(String.init).filter {
            $0 == "arm64" || $0 == "x86_64"
        })
        guard requiredArchitectures.isSubset(of: present) else { throw BiscuitUpdateFailure.incompatibleArchitecture }
        return AppFacts(version: version, architectures: present)
    }

    private static func supportsCurrentSystem(_ minimum: String?) -> Bool {
        guard let minimum else { return true }
        let parts = minimum.split(separator: ".")
        guard (1...3).contains(parts.count), let major = Int(parts[0]),
              parts.dropFirst().allSatisfy({ Int($0) != nil }) else { return false }
        let version = OperatingSystemVersion(
            majorVersion: major,
            minorVersion: parts.count > 1 ? Int(parts[1])! : 0,
            patchVersion: parts.count > 2 ? Int(parts[2])! : 0
        )
        return ProcessInfo.processInfo.isOperatingSystemAtLeast(version)
    }

    private static func safeExecutableName(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/") && !value.contains("\\") && !value.contains(":")
    }

    private static func swapDirectories(_ first: URL, _ second: URL) throws {
        guard fileType(at: first) == S_IFDIR, fileType(at: second) == S_IFDIR,
              let firstDevice = device(at: first), firstDevice == device(at: second) else {
            throw BiscuitUpdateFailure.installFailed
        }
        let result = first.path.withCString { from in
            second.path.withCString { to in renamex_np(from, to, UInt32(RENAME_SWAP)) }
        }
        guard result == 0 else { throw BiscuitUpdateFailure.installFailed }
    }

    private static func device(at url: URL) -> dev_t? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return info.st_dev
    }

    fileprivate static func fileType(at url: URL) -> mode_t? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return info.st_mode & S_IFMT
    }

    private static func run(_ executable: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run(); process.waitUntilExit(); return process.terminationStatus }
        catch { return -1 }
    }

    private static func runCapturing(_ executable: String, _ arguments: [String]) -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let bytes = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: bytes, as: UTF8.self))
        } catch { return (-1, "") }
    }
}

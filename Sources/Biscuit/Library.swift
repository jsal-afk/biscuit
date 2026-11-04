import AppKit
import ImageIO
import Foundation

public enum LibraryItemKind: String, Codable {
    case text
    case image
}

public struct LibraryItem: Codable, Identifiable, Equatable {
    public let id: UUID
    public let kind: LibraryItemKind
    public let createdAt: Date
    public let text: String?
    public let imageFilename: String?
    public let title: String?

    public init(
        id: UUID = UUID(),
        kind: LibraryItemKind,
        createdAt: Date = Date(),
        text: String? = nil,
        imageFilename: String? = nil,
        title: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.createdAt = createdAt
        self.text = text
        self.imageFilename = imageFilename
        self.title = title
    }
}

public enum LibraryStoreError: LocalizedError {
    case invalidManifest
    case invalidImageLimit
    case confirmationRequired(Int)
    case missingImage
    case pasteboardWriteFailed
    case cleanupFailed(String)
    case imageTitleRollbackFailed(String)
    case imageEditRollbackFailed(String)
    case imageTitleFilenameUnavailable
    case invalidImageTitle
    case itemUnavailable

    public var errorDescription: String? {
        switch self {
        case .invalidManifest: return BiscuitLocalization.string("The library file is invalid. It was left untouched so its contents can be recovered.")
        case .invalidImageLimit: return BiscuitLocalization.string("Image retention must be All or a positive whole number.")
        case .confirmationRequired(let count):
            return BiscuitLocalization.format("Reducing the image limit will permanently remove %1$d older saved image file(s).", arguments: [count])
        case .missingImage: return BiscuitLocalization.string("The image file is missing or cannot be read as an image.")
        case .pasteboardWriteFailed: return BiscuitLocalization.string("The item could not be copied to the clipboard.")
        case .cleanupFailed(let path):
            return BiscuitLocalization.format("The history entry was removed, but its managed image file could not be deleted: %1$@", arguments: [path])
        case .imageTitleRollbackFailed(let path):
            return BiscuitLocalization.format("The generated title could not be saved, and the image file could not be restored to its previous name: %1$@", arguments: [path])
        case .imageEditRollbackFailed(let path):
            return BiscuitLocalization.format("The edited image could not be rolled back safely: %1$@", arguments: [path])
        case .imageTitleFilenameUnavailable: return BiscuitLocalization.string("Biscuit could not choose an unused file name for this image title.")
        case .invalidImageTitle: return BiscuitLocalization.string("The selected provider did not return a usable one-line image title.")
        case .itemUnavailable: return BiscuitLocalization.string("This library item is no longer available.")
        }
    }
}

private struct LibraryArchive: Codable {
    var items: [LibraryItem]
    var imageLimit: Int?
}

/// Text history is unlimited; image retention is unlimited unless the user sets a count.
@MainActor public final class LibraryStore {
    public let dataDirectory: URL
    public let imageDirectory: URL
    public let manifestURL: URL
    public private(set) var items: [LibraryItem]
    public private(set) var imageLimit: Int?
    private let onRemovingImages: @MainActor ([URL]) -> Set<URL>

    public init(dataDirectory: URL? = nil, onRemovingImages: @escaping @MainActor ([URL]) -> Set<URL> = { _ in [] }) throws {
        let root = dataDirectory ?? Self.defaultDataDirectory()
        self.dataDirectory = root
        self.imageDirectory = root.appendingPathComponent("library-images", isDirectory: true)
        self.manifestURL = root.appendingPathComponent("library.json", isDirectory: false)
        self.items = []
        self.imageLimit = nil
        self.onRemovingImages = onRemovingImages

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { return }
        let data = try Data(contentsOf: manifestURL)
        let decoder = JSONDecoder()
        let archive: LibraryArchive
        do { archive = try decoder.decode(LibraryArchive.self, from: data) }
        catch { throw LibraryStoreError.invalidManifest }
        guard Self.valid(archive.items, imageLimit: archive.imageLimit) else { throw LibraryStoreError.invalidManifest }
        self.items = archive.items.sorted { $0.createdAt > $1.createdAt }
        self.imageLimit = archive.imageLimit
    }

    public func setImageLimit(_ limit: Int?, confirmTrim: Bool = false) throws {
        guard limit.map({ $0 > 0 }) ?? true else { throw LibraryStoreError.invalidImageLimit }
        let removed = Self.imagesToTrim(items, limit: limit)
        guard removed.isEmpty || confirmTrim else { throw LibraryStoreError.confirmationRequired(removed.count) }
        let removedIDs = Set(removed.map { $0.id })
        let updated = items.filter { !removedIDs.contains($0.id) }
        try persist(updated, imageLimit: limit)
        items = updated
        imageLimit = limit
        try removeManagedImages(removed)
    }

    public func addText(_ text: String) throws {
        let updated = [LibraryItem(kind: .text, text: text)] + items
        try persist(updated, imageLimit: imageLimit)
        items = updated
    }

    @discardableResult public func addImage(_ source: URL, recognizedText: String? = nil) throws -> LibraryItem {
        guard NSImage(contentsOf: source) != nil else { throw LibraryStoreError.missingImage }
        try FileManager.default.createDirectory(at: imageDirectory, withIntermediateDirectories: true)

        let ownedFilename = managedImageFilename(for: source)
        if let ownedFilename,
           let existing = items.first(where: { $0.kind == .image && $0.imageFilename == ownedFilename }) {
            if recognizedText != nil { try updateImageText(recognizedText, for: existing.id) }
            return items.first(where: { $0.id == existing.id }) ?? existing
        }
        let filename = ownedFilename ?? UUID().uuidString + "." + Self.safeExtension(source.pathExtension)
        let finalURL = imageDirectory.appendingPathComponent(filename, isDirectory: false)
        if ownedFilename == nil {
            let stagingURL = imageDirectory.appendingPathComponent(".\(UUID().uuidString).partial", isDirectory: false)
            do {
                try FileManager.default.copyItem(at: source, to: stagingURL)
                try FileManager.default.moveItem(at: stagingURL, to: finalURL)
            } catch {
                try? FileManager.default.removeItem(at: stagingURL)
                throw error
            }
        }

        let item = LibraryItem(kind: .image, text: Self.normalizedOCRText(recognizedText), imageFilename: filename)
        let candidate = [item] + items
        let removed = Self.imagesToTrim(candidate, limit: imageLimit)
        let removedIDs = Set(removed.map { $0.id })
        let updated = candidate.filter { !removedIDs.contains($0.id) }
        do {
            try persist(updated, imageLimit: imageLimit)
        } catch {
            if ownedFilename == nil { try? FileManager.default.removeItem(at: finalURL) }
            throw error
        }
        items = updated
        try removeManagedImages(removed)
        return item
    }
    @discardableResult
    public func saveEditedImage(_ pngData: Data, session: ImageEditorSession) throws -> (item: LibraryItem, oldURL: URL, newURL: URL) {
        guard let index = items.firstIndex(where: { $0.id == session.itemID && $0.kind == .image }) else {
            throw LibraryStoreError.itemUnavailable
        }
        guard let oldURL = imageURL(for: items[index]), FileManager.default.fileExists(atPath: oldURL.path) else {
            throw LibraryStoreError.missingImage
        }
        guard let source = CGImageSourceCreateWithData(pngData as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              CGImageSourceGetType(source) == ("public.png" as CFString) else {
            throw LibraryStoreError.missingImage
        }
        try FileManager.default.createDirectory(at: imageDirectory, withIntermediateDirectories: true)
        var filename: String
        var newURL: URL
        repeat {
            filename = UUID().uuidString + ".png"
            newURL = imageDirectory.appendingPathComponent(filename, isDirectory: false)
        } while FileManager.default.fileExists(atPath: newURL.path)

        let oldItem = items[index]
        let replacement = LibraryItem(id: oldItem.id, kind: .image, createdAt: oldItem.createdAt,
                                      text: nil, imageFilename: filename, title: nil)
        var updated = items
        updated[index] = replacement
        let persistence = ImageEditorPersistence(dataDirectory: dataDirectory)
        let snapshot = try persistence.snapshot(itemID: session.itemID)
        var sidecarsTouched = false
        do {
            try pngData.write(to: newURL, options: .atomic)
            sidecarsTouched = true
            try persistence.saveOriginalAndDocument(session)
            try persist(updated, imageLimit: imageLimit)
            items = updated
            return (replacement, oldURL, newURL)
        } catch {
            do {
                if FileManager.default.fileExists(atPath: newURL.path) {
                    try FileManager.default.removeItem(at: newURL)
                }
                if sidecarsTouched { try persistence.restore(snapshot, itemID: session.itemID) }
            } catch {
                throw LibraryStoreError.imageEditRollbackFailed(newURL.path)
            }
            throw error
        }
    }

    public func search(_ query: String) -> [LibraryItem] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return items }
        return items.filter { item in
            item.text?.localizedCaseInsensitiveContains(needle) == true ||
            item.title?.localizedCaseInsensitiveContains(needle) == true ||
            item.kind.rawValue.localizedCaseInsensitiveContains(needle) ||
            (item.imageFilename?.localizedCaseInsensitiveContains(needle) ?? false)
        }
    }

    public func copyToPasteboard(_ id: UUID, pasteboard: NSPasteboard = .general) throws {
        guard let item = items.first(where: { $0.id == id }) else { throw LibraryStoreError.itemUnavailable }
        switch item.kind {
        case .text:
            guard let text = item.text else { throw LibraryStoreError.invalidManifest }
            pasteboard.clearContents()
            guard pasteboard.setString(text, forType: .string) else { throw LibraryStoreError.pasteboardWriteFailed }
        case .image:
            guard let url = imageURL(for: item), let image = NSImage(contentsOf: url) else {
                throw LibraryStoreError.missingImage
            }
            pasteboard.clearContents()
            guard pasteboard.writeObjects([image]) else { throw LibraryStoreError.pasteboardWriteFailed }
        }
    }



    public func updateText(_ text: String, for id: UUID) throws {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].kind == .text else {
            throw LibraryStoreError.itemUnavailable
        }
        let old = items[index]
        guard old.text != text else { return }
        let replacement = LibraryItem(id: old.id, kind: .text, createdAt: old.createdAt, text: text)
        var updated = items
        updated[index] = replacement
        try persist(updated, imageLimit: imageLimit)
        items = updated
    }
    public func updateImageText(_ text: String?, for id: UUID) throws {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].kind == .image else {
            throw LibraryStoreError.itemUnavailable
        }
        let normalized = Self.normalizedOCRText(text)
        guard items[index].text != normalized else { return }
        let old = items[index]
        let replacement = LibraryItem(id: old.id, kind: .image, createdAt: old.createdAt,
                                      text: normalized, imageFilename: old.imageFilename, title: old.title)
        var updated = items
        updated[index] = replacement
        try persist(updated, imageLimit: imageLimit)
        items = updated
    }

    @discardableResult
    public func updateImageTitle(_ proposedTitle: String, for id: UUID) throws -> (oldURL: URL, newURL: URL) {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].kind == .image else {
            throw LibraryStoreError.itemUnavailable
        }
        guard let title = Self.normalizedImageTitle(proposedTitle) else { throw LibraryStoreError.invalidImageTitle }
        let old = items[index]
        guard let oldURL = imageURL(for: old), FileManager.default.fileExists(atPath: oldURL.path) else {
            throw LibraryStoreError.missingImage
        }
        let filename = try titleImageFilename(title, for: old)
        let newURL = imageDirectory.appendingPathComponent(filename, isDirectory: false)
        let replacement = LibraryItem(id: old.id, kind: .image, createdAt: old.createdAt,
                                      text: old.text, imageFilename: filename, title: title)
        guard replacement != old else { return (oldURL, oldURL) }

        let movedFile = newURL != oldURL
        if movedFile { try FileManager.default.moveItem(at: oldURL, to: newURL) }
        var updated = items
        updated[index] = replacement
        do {
            try persist(updated, imageLimit: imageLimit)
        } catch {
            if movedFile {
                do {
                    try FileManager.default.moveItem(at: newURL, to: oldURL)
                } catch {
                    throw LibraryStoreError.imageTitleRollbackFailed(oldURL.path)
                }
            }
            throw error
        }
        items = updated
        return (oldURL, newURL)
    }


    public func delete(_ id: UUID) throws {
        guard let item = items.first(where: { $0.id == id }) else { throw LibraryStoreError.itemUnavailable }
        let updated = items.filter { $0.id != id }
        try persist(updated, imageLimit: imageLimit)
        items = updated
        try removeManagedImages([item])
    }
    public func removeSupersededImageFile(at url: URL) throws {
        let normalized = url.standardizedFileURL
        let filename = normalized.lastPathComponent
        guard normalized.isFileURL,
              normalized.deletingLastPathComponent().path == imageDirectory.standardizedFileURL.path,
              Self.isSafeImageFilename(filename),
              !items.contains(where: { $0.kind == .image && $0.imageFilename == filename }) else { return }
        do {
            try FileManager.default.removeItem(at: normalized)
        } catch {
            if FileManager.default.fileExists(atPath: normalized.path) { throw LibraryStoreError.cleanupFailed(normalized.path) }
        }
    }

    private func managedImageFilename(for source: URL) -> String? {
        guard source.isFileURL else { return nil }
        let normalized = source.standardizedFileURL
        guard normalized.deletingLastPathComponent().path == imageDirectory.standardizedFileURL.path,
              Self.isSafeImageFilename(normalized.lastPathComponent),
              let values = try? normalized.resourceValues(forKeys: [.isSymbolicLinkKey]),
              values.isSymbolicLink != true else { return nil }
        return normalized.lastPathComponent
    }

    public func imageURL(for item: LibraryItem) -> URL? {
        guard item.kind == .image,
              let filename = item.imageFilename,
              Self.isSafeImageFilename(filename) else { return nil }
        return imageDirectory.appendingPathComponent(filename, isDirectory: false)
    }

    public func export(_ item: LibraryItem, to destination: URL) throws {
        guard let current = items.first(where: { $0.id == item.id }) else { throw LibraryStoreError.itemUnavailable }
        switch current.kind {
        case .text:
            guard let text = current.text else { throw LibraryStoreError.invalidManifest }
            try Data(text.utf8).write(to: destination, options: .atomic)
        case .image:
            let fileManager = FileManager.default
            guard let source = imageURL(for: current),
                  fileManager.fileExists(atPath: source.path) else {
                throw LibraryStoreError.missingImage
            }
            let normalizedDestination = destination.standardizedFileURL
            guard source.standardizedFileURL != normalizedDestination else { return }
            let stagingDirectory = normalizedDestination.deletingLastPathComponent()
                .appendingPathComponent(".biscuit-export-\(UUID().uuidString).partial", isDirectory: true)
            try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: false)
            defer { try? fileManager.removeItem(at: stagingDirectory) }
            let stagedFile = stagingDirectory.appendingPathComponent(normalizedDestination.lastPathComponent)
            try fileManager.copyItem(at: source, to: stagedFile)
            if fileManager.fileExists(atPath: normalizedDestination.path) {
                _ = try fileManager.replaceItemAt(normalizedDestination, withItemAt: stagedFile)
            } else {
                try fileManager.moveItem(at: stagedFile, to: normalizedDestination)
            }
        }
    }

    /// Exports a portable folder containing a JSON manifest and all retained images.
    public func exportAll(to destination: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let exportImages = destination.appendingPathComponent("images", isDirectory: true)
        try fm.createDirectory(at: exportImages, withIntermediateDirectories: true)
        for item in items where item.kind == .image {
            guard let source = imageURL(for: item), let filename = item.imageFilename,
                  fm.fileExists(atPath: source.path) else { throw LibraryStoreError.missingImage }
            try fm.copyItem(at: source, to: exportImages.appendingPathComponent(filename, isDirectory: false))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(LibraryArchive(items: items, imageLimit: imageLimit))
        try data.write(to: destination.appendingPathComponent("library.json", isDirectory: false), options: .atomic)
    }

    private func persist(_ newItems: [LibraryItem], imageLimit: Int?) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(LibraryArchive(items: newItems, imageLimit: imageLimit))
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        try data.write(to: manifestURL, options: .atomic)
    }

    private static func valid(_ items: [LibraryItem], imageLimit: Int?) -> Bool {
        guard imageLimit.map({ $0 > 0 }) ?? true else { return false }
        var ids = Set<UUID>()
        for item in items {
            guard ids.insert(item.id).inserted else { return false }
            switch item.kind {
            case .text:
                guard item.text != nil, item.imageFilename == nil, item.title == nil else { return false }
            case .image:
                guard let name = item.imageFilename, isSafeImageFilename(name) else { return false }
                if let title = item.title, normalizedImageTitle(title) != title { return false }
            }
        }
        return true
    }

    private static func normalizedOCRText(_ text: String?) -> String? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    private static func normalizedImageTitle(_ proposed: String) -> String? {
        ImageTitleText.normalized(proposed)
    }

    private func titleImageFilename(_ title: String, for item: LibraryItem) throws -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " _-."))
        var stem = ""
        var separatorPending = false
        for character in title.precomposedStringWithCanonicalMapping {
            let value = String(character)
            if value.unicodeScalars.allSatisfy(allowed.contains) {
                stem.append(character)
                separatorPending = false
            } else if !separatorPending {
                stem.append("-")
                separatorPending = true
            }
        }
        stem = stem.trimmingCharacters(in: CharacterSet(charactersIn: " ._-"))
        guard !stem.isEmpty else { throw LibraryStoreError.invalidImageTitle }

        let proposedExtension = item.imageFilename?.split(separator: ".").last.map(String.init) ?? "png"
        let fileExtension = Self.safeExtension(proposedExtension)
        let fileManager = FileManager.default
        for collisionIndex in 0..<10_000 {
            let suffix = collisionIndex == 0 ? "" : "-\(collisionIndex + 1)"
            let maximumStemBytes = 255 - fileExtension.utf8.count - 1 - suffix.utf8.count
            let candidateStem = Self.utf8Prefix(stem, maximumBytes: maximumStemBytes)
                .trimmingCharacters(in: CharacterSet(charactersIn: " ._-"))
            guard !candidateStem.isEmpty else { throw LibraryStoreError.invalidImageTitle }
            let filename = candidateStem + suffix + "." + fileExtension
            guard Self.isSafeImageFilename(filename) else { throw LibraryStoreError.invalidImageTitle }
            if filename == item.imageFilename { return filename }
            let usedByAnotherItem = items.contains { $0.id != item.id && $0.imageFilename == filename }
            let destination = imageDirectory.appendingPathComponent(filename, isDirectory: false)
            if !usedByAnotherItem && !fileManager.fileExists(atPath: destination.path) { return filename }
        }
        throw LibraryStoreError.imageTitleFilenameUnavailable
    }

    private static func utf8Prefix(_ value: String, maximumBytes: Int) -> String {
        guard maximumBytes > 0 else { return "" }
        var result = ""
        var byteCount = 0
        for character in value {
            let characterBytes = String(character).utf8.count
            guard byteCount + characterBytes <= maximumBytes else { break }
            result.append(character)
            byteCount += characterBytes
        }
        return result
    }


    private static func imagesToTrim(_ items: [LibraryItem], limit: Int?) -> [LibraryItem] {
        guard let limit else { return [] }
        let images = items.enumerated().filter { $0.element.kind == .image }.sorted {
            if $0.element.createdAt != $1.element.createdAt {
                return $0.element.createdAt > $1.element.createdAt
            }
            return $0.offset < $1.offset
        }
        return images.dropFirst(limit).map { $0.element }
    }

    private func removeManagedImages(_ removed: [LibraryItem]) throws {
        let retainedFilenames = Set(items.compactMap { $0.kind == .image ? $0.imageFilename : nil })
        var seen = Set<URL>()
        let urls = removed.compactMap { imageURL(for: $0) }.filter { url in
            !retainedFilenames.contains(url.lastPathComponent) && seen.insert(url.standardizedFileURL).inserted
        }
        let deferred = Set(onRemovingImages(urls).map(\.standardizedFileURL))
        for url in urls where !deferred.contains(url.standardizedFileURL) {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                if FileManager.default.fileExists(atPath: url.path) {
                    throw LibraryStoreError.cleanupFailed(url.path)
                }
            }
        }
        try ImageEditorPersistence(dataDirectory: dataDirectory).remove(itemIDs: removed.map(\.id))
    }

    private static func isSafeImageFilename(_ filename: String) -> Bool {
        guard !filename.isEmpty, filename.utf8.count <= 255,
              filename != ".", filename != "..", !filename.hasPrefix("."),
              URL(fileURLWithPath: filename).lastPathComponent == filename else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " ._-"))
        return filename.unicodeScalars.allSatisfy(allowed.contains)
    }

    private static func safeExtension(_ proposed: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789")
        let scalars = proposed.lowercased().unicodeScalars.filter { allowed.contains($0) }
        let value = String(String.UnicodeScalarView(scalars.prefix(12)))
        return value.isEmpty ? "img" : value
    }

    private static func defaultDataDirectory() -> URL {
        if let override = ProcessInfo.processInfo.environment["BISCUIT_DATA_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("biscuit", isDirectory: true)
    }
}

@MainActor public final class LibraryController: NSObject {
    public private(set) var store: LibraryStore?
    private var startupError: Error?
    private var window: NSWindow?
    private var imageEditorWindows: [UUID: ImageEditorWindowController] = [:]
    private var scrollView: NSScrollView?
    private var rows: NSStackView?
    private var searchField: NSSearchField?
    private var imageLimitField: NSTextField?
    public var currentImageLimit: Int? { store?.imageLimit }
    private var pendingOCR = Set<UUID>()
    private var ocrFailures: [UUID: String] = [:]
    private var imageTitleFailures: [UUID: String] = [:]
    private var pendingImageTitleConsents: [UUID: ImageTitleConsentSnapshot] = [:]
    private var imageOCRURLs: [UUID: URL] = [:]
    private var pendingImageTitleTasks: [UUID: Task<Void, Never>] = [:]
    private var pendingImageTitleRequestTokens: [UUID: UUID] = [:]
    private var pendingImageTitleRequestURLs: [UUID: URL] = [:]
    private var imageTitleConsentRevision: UInt64 = 0
    private let thumbnailCache = NSCache<NSString, NSImage>()
    private var pasteboard: NSPasteboard
    private let onCopied: (LibraryItemKind, String?) -> Void
    private let imageTitleEnabled: @MainActor () -> Bool
    private let requestImageTitle: @MainActor (String, @escaping @MainActor () -> Bool, @escaping @MainActor (Result<String, Error>) -> Void) -> Task<Void, Never>?
    private let scheduleImageFileMutation: @MainActor (URL, @escaping @MainActor () -> Void) -> Void
    private let onImageFileURLChanged: @MainActor (URL, URL, String) -> Void
    private let recognizeImageText: (URL) throws -> String

    public init(
        dataDirectory: URL? = nil,
        onRemovingImages: @escaping @MainActor ([URL]) -> Set<URL>,
        onCopied: @escaping (LibraryItemKind, String?) -> Void,
        imageTitleEnabled: @escaping @MainActor () -> Bool,
        requestImageTitle: @escaping @MainActor (String, @escaping @MainActor () -> Bool, @escaping @MainActor (Result<String, Error>) -> Void) -> Task<Void, Never>?,
        scheduleImageFileMutation: @escaping @MainActor (URL, @escaping @MainActor () -> Void) -> Void,
        onImageFileURLChanged: @escaping @MainActor (URL, URL, String) -> Void,
        recognizeImageText: @escaping (URL) throws -> String = { try CaptureOCR.recognizeText(in: $0) },
        pasteboard: NSPasteboard = .general
    ) {
        self.pasteboard = pasteboard
        self.onCopied = onCopied
        self.imageTitleEnabled = imageTitleEnabled
        self.requestImageTitle = requestImageTitle
        self.scheduleImageFileMutation = scheduleImageFileMutation
        self.onImageFileURLChanged = onImageFileURLChanged
        self.recognizeImageText = recognizeImageText
        super.init()
        thumbnailCache.countLimit = 96
        thumbnailCache.totalCostLimit = 24 * 1024 * 1024
        do {
            store = try LibraryStore(dataDirectory: dataDirectory, onRemovingImages: { [weak self] urls in
                self?.cancelImageTitleWork(for: urls)
                return onRemovingImages(urls)
            })
        } catch {
            startupError = error
        }
    }
    #if BISCUIT_SMOKE
    func smokeUsePasteboard(_ pasteboard: NSPasteboard) { self.pasteboard = pasteboard }
    #endif

    public func addText(_ text: String) {
        do {
            guard let store else { throw startupError ?? LibraryStoreError.itemUnavailable }
            try store.addText(text)
            refreshRows()
        } catch { present(error) }
    }

    public func addImage(_ url: URL) {
        let consent = imageTitleConsentSnapshot()
        do {
            guard let store else { throw startupError ?? LibraryStoreError.itemUnavailable }
            let item = try store.addImage(url)
            guard item.text == nil, !pendingOCR.contains(item.id),
                  let imageURL = store.imageURL(for: item) else {
                refreshRows()
                return
            }
            beginImageOCR(item, imageURL: imageURL, consent: consent, recognize: true)
        } catch {
            refreshRows()
            present(error)
        }
    }
    public func editImage(forImageURL url: URL) {
        guard let store else {
            present(startupError ?? LibraryStoreError.itemUnavailable)
            return
        }
        if let item = store.items.first(where: { store.imageURL(for: $0)?.standardizedFileURL == url.standardizedFileURL }) {
            editImage(item.id)
            return
        }
        do {
            let item = try store.addImage(url)
            refreshRows()
            if item.text == nil, !pendingOCR.contains(item.id), let imageURL = store.imageURL(for: item) {
                beginImageOCR(item, imageURL: imageURL, consent: imageTitleConsentSnapshot(), recognize: true)
            }
            editImage(item.id)
        } catch {
            present(error)
        }
    }

    public func editImage(_ id: UUID) {
        guard let store else {
            present(startupError ?? LibraryStoreError.itemUnavailable)
            return
        }
        if let editor = imageEditorWindows[id] {
            editor.present()
            return
        }
        guard let item = store.items.first(where: { $0.id == id && $0.kind == .image }),
              let imageURL = store.imageURL(for: item) else {
            present(LibraryStoreError.itemUnavailable)
            return
        }
        do {
            let editor = try ImageEditorWindowController(
                itemID: id,
                title: item.title ?? "",
                imageURL: imageURL,
                persistence: ImageEditorPersistence(dataDirectory: store.dataDirectory),
                onSave: { [weak self] session, pngData, completion in
                    guard let self else {
                        completion(.failure(ImageEditorError.missingItem))
                        return
                    }
                    self.saveEditedImage(session, pngData: pngData, completion: completion)
                },
                onClose: { [weak self] closedID in _ = self?.imageEditorWindows.removeValue(forKey: closedID) }
            )
            imageEditorWindows[id] = editor
            editor.present()
        } catch {
            present(error)
        }
    }
    private func saveEditedImage(
        _ session: ImageEditorSession,
        pngData: Data,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard let store,
              let item = store.items.first(where: { $0.id == session.itemID && $0.kind == .image }),
              let oldURL = store.imageURL(for: item) else {
            completion(.failure(ImageEditorError.missingItem))
            return
        }
        cancelImageTitleWork(for: [oldURL])
        scheduleImageFileMutation(oldURL) { [weak self] in
            guard let self,
                  let store = self.store,
                  let current = store.items.first(where: { $0.id == session.itemID && $0.kind == .image }),
                  let currentURL = store.imageURL(for: current),
                  currentURL.standardizedFileURL == oldURL.standardizedFileURL else {
                completion(.failure(ImageEditorError.missingItem))
                return
            }
            do {
                let saved = try store.saveEditedImage(pngData, session: session)
                self.thumbnailCache.removeObject(forKey: session.itemID.uuidString as NSString)
                var cleanupError: Error?
                do { try store.removeSupersededImageFile(at: saved.oldURL) }
                catch { cleanupError = error }
                self.onImageFileURLChanged(saved.oldURL, saved.newURL, "")
                self.beginImageOCR(saved.item, imageURL: saved.newURL,
                                   consent: self.imageTitleConsentSnapshot(), recognize: true)
                completion(.success(()))
                if let cleanupError { self.present(cleanupError) }
            } catch {
                completion(.failure(error))
            }
        }
    }

    func imageTitlePreferenceChanged(enabled: Bool) {
        guard !enabled else { return }
        imageTitleConsentRevision &+= 1
        pendingImageTitleConsents.removeAll()
        let tasks = Array(pendingImageTitleTasks.values)
        pendingImageTitleTasks.removeAll()
        pendingImageTitleRequestTokens.removeAll()
        pendingImageTitleRequestURLs.removeAll()
        tasks.forEach { $0.cancel() }
        refreshRows()
    }

    private func imageTitleConsentSnapshot() -> ImageTitleConsentSnapshot {
        ImageTitleConsentSnapshot(enabledAtCapture: imageTitleEnabled(), revision: imageTitleConsentRevision)
    }

    private func beginImageOCR(
        _ item: LibraryItem,
        imageURL: URL,
        consent: ImageTitleConsentSnapshot,
        recognize: Bool
    ) {
        pendingOCR.insert(item.id)
        pendingImageTitleConsents[item.id] = consent
        imageOCRURLs[item.id] = imageURL.standardizedFileURL
        ocrFailures.removeValue(forKey: item.id)
        imageTitleFailures.removeValue(forKey: item.id)
        refreshRows()
        guard recognize else { return }
        let itemID = item.id
        let recognition = recognizeImageText
        Task.detached(priority: .utility) { [weak self] in
            do {
                let recognizedText = try recognition(imageURL)
                await self?.finishImageOCR(recognizedText, for: itemID, from: imageURL)
            } catch {
                await self?.failImageOCR(error, for: itemID, from: imageURL)
            }
        }
    }

    private func cancelImageTitleWork(for urls: [URL]) {
        let removedURLs = Set(urls.map(\.standardizedFileURL))
        let removedOCRIDs = imageOCRURLs.compactMap { id, url in
            removedURLs.contains(url.standardizedFileURL) ? id : nil
        }
        for id in removedOCRIDs {
            pendingOCR.remove(id)
            pendingImageTitleConsents.removeValue(forKey: id)
            imageOCRURLs.removeValue(forKey: id)
            imageTitleFailures.removeValue(forKey: id)
        }
        let removedRequestIDs = pendingImageTitleRequestURLs.compactMap { id, url in
            removedURLs.contains(url.standardizedFileURL) ? id : nil
        }
        for id in removedRequestIDs {
            pendingImageTitleRequestTokens.removeValue(forKey: id)
            pendingImageTitleRequestURLs.removeValue(forKey: id)
            pendingImageTitleTasks.removeValue(forKey: id)?.cancel()
        }
    }

    #if BISCUIT_SMOKE
    func smokeBeginImageOCR(_ url: URL) throws -> UUID {
        let consent = imageTitleConsentSnapshot()
        guard let store else { throw startupError ?? LibraryStoreError.itemUnavailable }
        let item = try store.addImage(url)
        guard item.text == nil, !pendingOCR.contains(item.id),
              let imageURL = store.imageURL(for: item) else { return item.id }
        beginImageOCR(item, imageURL: imageURL, consent: consent, recognize: false)
        return item.id
    }

    func smokeFinishImageOCR(_ text: String, for id: UUID) { finishImageOCR(text, for: id) }
    #endif

    public func show() {
        guard store != nil else {
            present(startupError ?? LibraryStoreError.itemUnavailable)
            return
        }
        if window == nil { buildWindow() }
        refreshRows()
        guard BiscuitPresentation.show(window) else { return }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildWindow() {
        let created = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 620),
                               styleMask: [.titled, .closable, .miniaturizable, .resizable],
                               backing: .buffered, defer: false)
        created.title = BiscuitLocalization.string("biscuit Library")
        created.minSize = NSSize(width: 560, height: 360)
        created.isReleasedWhenClosed = false
        BiscuitPresentation.center(created)

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 10
        root.translatesAutoresizingMaskIntoConstraints = false

        let toolbar = NSStackView()
        toolbar.orientation = .horizontal
        toolbar.alignment = .centerY
        toolbar.spacing = 8
        let search = NSSearchField()
        search.placeholderString = BiscuitLocalization.string("Search text and images")
        search.sendsSearchStringImmediately = true
        search.target = self
        search.action = #selector(searchChanged(_:))
        let export = NSButton(title: BiscuitLocalization.string("Export All…"), target: self, action: #selector(exportAll(_:)))
        let limitLabel = NSTextField(labelWithString: BiscuitLocalization.string("Keep images:"))
        let limitField = NSTextField(string: store?.imageLimit.map { String($0) } ?? BiscuitLocalization.string("All"))
        limitField.alignment = .center
        limitField.widthAnchor.constraint(equalToConstant: 48).isActive = true
        limitField.target = self
        limitField.action = #selector(applyImageLimit(_:))
        let applyLimit = NSButton(title: BiscuitLocalization.string("Apply"), target: self, action: #selector(applyImageLimit(_:)))
        let count = NSTextField(labelWithString: BiscuitLocalization.string("All text retained"))
        count.textColor = .secondaryLabelColor
        toolbar.addArrangedSubview(search)
        toolbar.addArrangedSubview(limitLabel)
        toolbar.addArrangedSubview(limitField)
        toolbar.addArrangedSubview(applyLimit)
        toolbar.addArrangedSubview(count)
        toolbar.addArrangedSubview(export)
        searchField = search
        imageLimitField = limitField

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        let list = TopStackView()
        list.orientation = .vertical
        list.alignment = .leading
        list.distribution = .fill
        list.spacing = 8
        list.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 8, right: 12)
        list.frame = NSRect(x: 0, y: 0, width: 700, height: 1)
        list.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = list
        list.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        rows = list
        scrollView = scroll
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        scroll.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        root.addArrangedSubview(toolbar)
        root.addArrangedSubview(scroll)
        let content = BiscuitBackgroundView()
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            root.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
            toolbar.widthAnchor.constraint(equalTo: root.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: root.widthAnchor)
        ])
        created.contentView = content
        window = created
    }

    private func refreshRows() {
        guard let store, let list = rows, let scroll = scrollView else { return }
        let retainedIDs = Set(store.items.map(\.id))
        pendingOCR.formIntersection(retainedIDs)
        ocrFailures = ocrFailures.filter { retainedIDs.contains($0.key) }
        imageLimitField?.stringValue = store.imageLimit.map { String($0) } ?? BiscuitLocalization.string("All")
        for view in list.arrangedSubviews {
            list.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        let needle = searchField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let matching = store.search(needle)
        if matching.isEmpty {
            let message = NSTextField(labelWithString: store.items.isEmpty ? BiscuitLocalization.string("Your saved text and images will appear here.") : BiscuitLocalization.string("No matching items."))
            message.textColor = .secondaryLabelColor
            list.addArrangedSubview(message)
        } else {
            for item in matching { list.addArrangedSubview(makeRow(for: item)) }
        }
        for view in list.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: list.widthAnchor, constant: -16).isActive = true
        }
        window?.contentView?.layoutSubtreeIfNeeded()
        scroll.layoutSubtreeIfNeeded()
        list.layoutSubtreeIfNeeded()
        let height = max(list.fittingSize.height, 24)
        list.setFrameSize(NSSize(width: scroll.contentView.bounds.width, height: height))
        if let window { BiscuitLocalization.applyInterfaceDirection(to: window) }
    }

    private func makeRow(for item: LibraryItem) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        row.wantsLayer = true
        row.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        row.layer?.cornerRadius = 7

        let detail = NSStackView()
        detail.orientation = .vertical
        detail.alignment = .leading
        detail.spacing = 4
        let dateLabel = "\(BiscuitLocalization.string(item.kind == .text ? "Text" : "Image")) · \(Self.dateFormatter.string(from: item.createdAt))"
        let heading = NSTextField(labelWithString: item.title ?? dateLabel)
        heading.font = item.title == nil ? .systemFont(ofSize: 11, weight: .semibold) : .systemFont(ofSize: 13, weight: .semibold)
        heading.textColor = item.title == nil ? .secondaryLabelColor : .labelColor
        heading.maximumNumberOfLines = 1
        heading.lineBreakMode = .byTruncatingTail
        detail.addArrangedSubview(heading)
        if item.title != nil {
            let date = NSTextField(labelWithString: dateLabel)
            date.font = .systemFont(ofSize: 11)
            date.textColor = .secondaryLabelColor
            detail.addArrangedSubview(date)
        }
        if item.kind == .text {
            let value = item.text ?? ""
            let summary = String(value.prefix(240)).replacingOccurrences(of: "\n", with: "  ")
            let preview = NSTextField(wrappingLabelWithString: summary + (value.count > 240 ? "…" : ""))
            preview.maximumNumberOfLines = 3
            preview.lineBreakMode = .byTruncatingTail
            detail.addArrangedSubview(preview)
        } else {
            if let thumbnail = thumbnailImage(for: item) {
                let imageView = NSImageView(image: thumbnail)
                imageView.imageScaling = .scaleProportionallyUpOrDown
                imageView.widthAnchor.constraint(equalToConstant: 72).isActive = true
                imageView.heightAnchor.constraint(equalToConstant: 72).isActive = true
                detail.addArrangedSubview(imageView)
            } else {
                detail.addArrangedSubview(NSTextField(labelWithString: BiscuitLocalization.string("Image preview unavailable")))
            }
            if pendingImageTitleRequestTokens[item.id] != nil {
                let progress = NSTextField(labelWithString: BiscuitLocalization.string("Generating title with the selected provider…"))
                progress.textColor = .secondaryLabelColor
                detail.addArrangedSubview(progress)
            } else if let failure = imageTitleFailures[item.id] {
                let message = NSTextField(wrappingLabelWithString: BiscuitLocalization.format("Image title not generated: %1$@", arguments: [failure]))
                message.maximumNumberOfLines = 3
                message.lineBreakMode = .byTruncatingTail
                message.textColor = .systemRed
                detail.addArrangedSubview(message)
            }
            let ocrMessage = ocrFailures[item.id].map { BiscuitLocalization.format("Text recognition failed: %1$@", arguments: [$0]) }
                ?? (item.text ?? (pendingOCR.contains(item.id) ? BiscuitLocalization.string("Reading text locally…") : BiscuitLocalization.string("No searchable text recognized.")))
            let ocrPreview = NSTextField(wrappingLabelWithString: ocrMessage)
            ocrPreview.maximumNumberOfLines = 4
            ocrPreview.lineBreakMode = .byTruncatingTail
            if ocrFailures[item.id] != nil { ocrPreview.textColor = .systemRed }
            detail.addArrangedSubview(ocrPreview)
        }
        detail.setContentHuggingPriority(.defaultLow, for: .horizontal)
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for view in detail.arrangedSubviews {
            guard let label = view as? NSTextField else { continue }
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.widthAnchor.constraint(lessThanOrEqualTo: detail.widthAnchor).isActive = true
        }
        row.addArrangedSubview(detail)
        let spacer = NSView()
        row.addArrangedSubview(spacer)
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(NSButton(title: BiscuitLocalization.string("Recopy"), target: self, action: #selector(recopy(_:))).identified(with: item.id))
        if item.kind == .image {
            row.addArrangedSubview(NSButton(title: BiscuitLocalization.string("Edit"), target: self, action: #selector(editHistoryImage(_:))).identified(with: item.id))
        }
        row.addArrangedSubview(NSButton(title: BiscuitLocalization.string("Export…"), target: self, action: #selector(exportItem(_:))).identified(with: item.id))
        row.addArrangedSubview(NSButton(title: BiscuitLocalization.string("Delete"), target: self, action: #selector(deleteItem(_:))).identified(with: item.id))
        return row
    }
    private func finishImageOCR(_ text: String, for id: UUID, from expectedURL: URL? = nil) {
        guard pendingOCR.contains(id) else { return }
        if let expectedURL,
           imageOCRURLs[id]?.standardizedFileURL != expectedURL.standardizedFileURL { return }
        pendingOCR.remove(id)
        let consent = pendingImageTitleConsents.removeValue(forKey: id)
        imageOCRURLs.removeValue(forKey: id)
        guard let store, store.items.contains(where: { $0.id == id && $0.kind == .image }) else { return }
        ocrFailures.removeValue(forKey: id)
        do {
            try store.updateImageText(text, for: id)
            let recognizedText = store.items.first(where: { $0.id == id })?.text
            refreshRows()
            guard let recognizedText, let consent,
                  consent.allows(enabled: imageTitleEnabled(), currentRevision: imageTitleConsentRevision) else { return }
            generateImageTitleForItem(id, recognizedText: recognizedText, consent: consent)
        } catch {
            ocrFailures[id] = BiscuitLocalization.format("Could not save recognized text: %1$@", arguments: [error.localizedDescription])
            refreshRows()
            present(error)
        }
    }

    private func generateImageTitleForItem(
        _ id: UUID,
        recognizedText: String,
        consent: ImageTitleConsentSnapshot
    ) {
        guard consent.allows(enabled: imageTitleEnabled(), currentRevision: imageTitleConsentRevision),
              let store,
              let item = store.items.first(where: { $0.id == id && $0.kind == .image && $0.text == recognizedText }),
              let imageURL = store.imageURL(for: item) else { return }

        let requestToken = UUID()
        pendingImageTitleRequestTokens[id] = requestToken
        pendingImageTitleRequestURLs[id] = imageURL.standardizedFileURL
        imageTitleFailures.removeValue(forKey: id)
        refreshRows()
        let task = requestImageTitle(recognizedText, { [weak self] in
            guard let self,
                  self.pendingImageTitleRequestTokens[id] == requestToken,
                  consent.allows(enabled: self.imageTitleEnabled(), currentRevision: self.imageTitleConsentRevision),
                  let currentStore = self.store,
                  let currentItem = currentStore.items.first(where: { $0.id == id && $0.kind == .image && $0.text == recognizedText }),
                  let currentURL = currentStore.imageURL(for: currentItem),
                  currentURL.standardizedFileURL == imageURL.standardizedFileURL else { return false }
            return true
        }) { [weak self] result in
            guard let self, self.pendingImageTitleRequestTokens[id] == requestToken else { return }
            self.pendingImageTitleRequestTokens.removeValue(forKey: id)
            self.pendingImageTitleRequestURLs.removeValue(forKey: id)
            self.pendingImageTitleTasks.removeValue(forKey: id)
            guard consent.allows(enabled: self.imageTitleEnabled(), currentRevision: self.imageTitleConsentRevision),
                  let currentStore = self.store,
                  let currentItem = currentStore.items.first(where: { $0.id == id && $0.kind == .image && $0.text == recognizedText }),
                  let currentURL = currentStore.imageURL(for: currentItem) else {
                self.refreshRows()
                return
            }
            switch result {
            case .success(let title):
                self.persistImageTitle(title, for: id, recognizedText: recognizedText,
                                       consent: consent, sourceURL: currentURL)
            case .failure(let error):
                self.imageTitleFailures[id] = error.localizedDescription
                self.refreshRows()
            }
        }
        if pendingImageTitleRequestTokens[id] == requestToken, let task {
            pendingImageTitleTasks[id] = task
        }
    }

    private func persistImageTitle(
        _ title: String,
        for id: UUID,
        recognizedText: String,
        consent: ImageTitleConsentSnapshot,
        sourceURL: URL
    ) {
        scheduleImageFileMutation(sourceURL) { [weak self] in
            guard let self,
                  consent.allows(enabled: self.imageTitleEnabled(), currentRevision: self.imageTitleConsentRevision),
                  let store = self.store,
                  let item = store.items.first(where: { $0.id == id && $0.kind == .image && $0.text == recognizedText }),
                  let currentURL = store.imageURL(for: item),
                  currentURL.standardizedFileURL == sourceURL.standardizedFileURL else { return }
            do {
                let changedURLs = try store.updateImageTitle(title, for: id)
                self.imageTitleFailures.removeValue(forKey: id)
                let savedTitle = store.items.first(where: { $0.id == id })?.title ?? title
                self.onImageFileURLChanged(changedURLs.oldURL, changedURLs.newURL, savedTitle)
            } catch {
                self.imageTitleFailures[id] = error.localizedDescription
            }
            self.refreshRows()
        }
    }

    private func failImageOCR(_ error: Error, for id: UUID, from expectedURL: URL? = nil) {
        guard pendingOCR.contains(id) else { return }
        if let expectedURL,
           imageOCRURLs[id]?.standardizedFileURL != expectedURL.standardizedFileURL { return }
        pendingOCR.remove(id)
        pendingImageTitleConsents.removeValue(forKey: id)
        imageOCRURLs.removeValue(forKey: id)
        guard store?.items.contains(where: { $0.id == id && $0.kind == .image }) == true else { return }
        ocrFailures[id] = error.localizedDescription
        refreshRows()
    }

    private func thumbnailImage(for item: LibraryItem) -> NSImage? {
        let key = item.id.uuidString as NSString
        if let cached = thumbnailCache.object(forKey: key) { return cached }
        guard let store, let url = store.imageURL(for: item),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 144
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let thumbnail = NSImage(cgImage: image, size: NSSize(width: CGFloat(image.width), height: CGFloat(image.height)))
        thumbnailCache.setObject(thumbnail, forKey: key, cost: image.bytesPerRow * image.height)
        return thumbnail
    }


    @objc private func searchChanged(_ sender: NSSearchField) { refreshRows() }
    @objc private func applyImageLimit(_ sender: Any?) {
        guard let field = imageLimitField else { return }
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let limit: Int?
        if value.caseInsensitiveCompare(BiscuitLocalization.string("All")) == .orderedSame || value.caseInsensitiveCompare("all") == .orderedSame {
            limit = nil
        } else if let parsed = Int(value), parsed > 0 {
            limit = parsed
        } else {
            refreshRows()
            present(LibraryStoreError.invalidImageLimit)
            return
        }
        setImageLimitFromSettings(limit)
    }

    @discardableResult
    public func setImageLimitFromSettings(_ limit: Int?) -> Bool {
        guard let store else {
            if let startupError { present(startupError) }
            return false
        }
        do {
            try store.setImageLimit(limit)
        } catch LibraryStoreError.confirmationRequired(let count) {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = BiscuitLocalization.string("Remove older saved images?")
            alert.informativeText = BiscuitLocalization.format("This will permanently delete %1$d older image file(s) managed by biscuit. Text and newer images will remain.", arguments: [count])
            alert.addButton(withTitle: BiscuitLocalization.string("Remove Images"))
            alert.addButton(withTitle: BiscuitLocalization.string("Cancel"))
            BiscuitLocalization.applyInterfaceDirection(to: alert)
            guard BiscuitPresentation.runModal(alert) == .alertFirstButtonReturn else {
                refreshRows()
                return false
            }
            do {
                try store.setImageLimit(limit, confirmTrim: true)
            } catch {
                refreshRows()
                present(error)
                return false
            }
        } catch {
            refreshRows()
            present(error)
            return false
        }
        refreshRows()
        return true
    }


    @objc private func editHistoryImage(_ sender: NSButton) {
        guard let id = sender.itemID else { return }
        editImage(id)
    }

    @objc private func recopy(_ sender: NSButton) {
        guard let id = sender.itemID,
              let store,
              let item = store.items.first(where: { $0.id == id }) else { return }
        do {
            try store.copyToPasteboard(id, pasteboard: pasteboard)
            onCopied(item.kind, item.kind == .text ? item.text : nil)
        } catch { present(error) }
    }


    @objc private func deleteItem(_ sender: NSButton) {
        guard let id = sender.itemID else { return }
        do { try store?.delete(id) } catch { present(error) }
        refreshRows()
    }

    @objc private func exportItem(_ sender: NSButton) {
        guard let store,
              let id = sender.itemID,
              let item = store.items.first(where: { $0.id == id }),
              let window else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = item.kind == .text ? "biscuit-text.txt" : (item.imageFilename ?? "biscuit-image.img")
        BiscuitLocalization.applyInterfaceDirection(to: panel)
        BiscuitPresentation.beginSheet(panel, for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do { try store.export(item, to: url) } catch { self?.present(error) }
        }
    }

    @objc private func exportAll(_ sender: NSButton) {
        guard let store, let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = BiscuitLocalization.string("Export Here")
        BiscuitLocalization.applyInterfaceDirection(to: panel)
        BiscuitPresentation.beginSheet(panel, for: window) { [weak self] response in
            guard response == .OK, let parent = panel.url else { return }
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let destination = parent.appendingPathComponent("biscuit-library-\(formatter.string(from: Date()))", isDirectory: true)
            do { try store.exportAll(to: destination) } catch { self?.present(error) }
        }
    }


    private func present(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = BiscuitLocalization.string("Library operation failed")
        alert.informativeText = error.localizedDescription
        BiscuitLocalization.applyInterfaceDirection(to: alert)
        _ = BiscuitPresentation.runModal(alert)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = BiscuitLocalization.locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

private extension NSButton {
    var itemID: UUID? {
        get { identifier.flatMap { UUID(uuidString: $0.rawValue) } }
        set { identifier = newValue.map { NSUserInterfaceItemIdentifier($0.uuidString) } }
    }

    func identified(with id: UUID) -> NSButton {
        itemID = id
        return self
    }
}

#if BISCUIT_IMAGE_TITLE_LIFECYCLE_CHECKS
import AppKit
import Foundation

@MainActor
@main
enum ImageTitleLifecycleChecks {
    private struct PendingTitleRequest {
        let isStillConsented: @MainActor () -> Bool
        let completion: @MainActor (Result<String, Error>) -> Void
    }

    @MainActor
    private final class Fixture {
        let defaults: UserDefaults
        let dataDirectory: URL
        var leases = ImageFileMutationLeases()
        var requestCount = 0
        var pendingTitles: [PendingTitleRequest] = []

        lazy var controller = LibraryController(
            dataDirectory: dataDirectory,
            onRemovingImages: { [weak self] urls in
                self?.leases.removeImages(urls) ?? []
            },
            onCopied: { _, _ in },
            imageTitleEnabled: { [weak self] in
                guard let self else { return false }
                return SettingsPreferences.imageTitlesEnabled(defaults: self.defaults)
            },
            requestImageTitle: { [weak self] _, isStillConsented, completion in
                guard let self else { return nil }
                guard isStillConsented() else {
                    ImageTitleLifecycleChecks.fail("title request was submitted after consent became invalid")
                }
                self.requestCount += 1
                self.pendingTitles.append(PendingTitleRequest(
                    isStillConsented: isStillConsented,
                    completion: completion
                ))
                return nil
            },
            scheduleImageFileMutation: { [weak self] url, perform in
                guard let self else {
                    perform()
                    return
                }
                switch self.leases.scheduleMutation(afterDragsFor: url, perform: perform) {
                case .immediate:
                    perform()
                case .deferred, .discarded:
                    break
                }
            },
            onImageFileURLChanged: { _, _, _ in },
            recognizeImageText: { _ in "unused recognizer" },
            pasteboard: NSPasteboard(name: NSPasteboard.Name("biscuit-image-title-check-\(UUID().uuidString)"))
        )

        init(defaults: UserDefaults, dataDirectory: URL) {
            self.defaults = defaults
            self.dataDirectory = dataDirectory
        }

        func completeTitle(_ index: Int, with title: String) {
            pendingTitles[index].completion(.success(title))
        }

        func endDrag(_ url: URL) throws {
            switch leases.endDrag(for: url) {
            case .none:
                break
            case .delete(let fileURL):
                try FileManager.default.removeItem(at: fileURL)
            case .perform(let mutations):
                mutations.forEach { $0() }
            }
        }
    }

    static func main() {
        let suiteName = ProcessInfo.processInfo.environment["BISCUIT_PREFERENCES_SUITE"]
            ?? "org.biscuit.image-title-check.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fail("could not create isolated preferences")
        }
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("biscuit-image-title-check-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let sourceImage = root.appendingPathComponent("synthetic-capture.png")
            let imageData = try makePNG()
            try imageData.write(to: sourceImage)

            try verifyCaptureTimeConsent(sourceImage, root: root, defaults: defaults)
            try verifyGeneratedTitleRenameAndDragLease(sourceImage, root: root, defaults: defaults, imageData: imageData)
            try verifyRevocationAndDeletion(sourceImage, root: root, defaults: defaults)
            try verifyUTF8FilenameCollisionBound(sourceImage, root: root)
            print("Image title lifecycle checks passed")
        } catch {
            fail("\(error.localizedDescription)")
        }
    }

    private static func verifyCaptureTimeConsent(_ sourceImage: URL, root: URL, defaults: UserDefaults) throws {
        let fixture = Fixture(defaults: defaults, dataDirectory: root.appendingPathComponent("consent", isDirectory: true))

        let capturedWhileOff = try fixture.controller.smokeBeginImageOCR(sourceImage)
        SettingsPreferences.setImageTitlesEnabled(true, defaults: defaults)
        fixture.controller.imageTitlePreferenceChanged(enabled: true)
        fixture.controller.smokeFinishImageOCR("Synthetic OCR from an image captured while titles were off.", for: capturedWhileOff)
        check(fixture.requestCount == 0, "turning titles on before OCR completes must not backfill an opt-out capture")
        check(fixture.controller.store?.items.first(where: { $0.id == capturedWhileOff })?.title == nil,
              "opt-out capture must remain untitled")

        let capturedBeforeRevocation = try fixture.controller.smokeBeginImageOCR(sourceImage)
        SettingsPreferences.setImageTitlesEnabled(false, defaults: defaults)
        fixture.controller.imageTitlePreferenceChanged(enabled: false)
        SettingsPreferences.setImageTitlesEnabled(true, defaults: defaults)
        fixture.controller.imageTitlePreferenceChanged(enabled: true)
        fixture.controller.smokeFinishImageOCR("Synthetic OCR whose consent was revoked while OCR was pending.", for: capturedBeforeRevocation)
        check(fixture.requestCount == 0, "off/on during OCR must not revive the capture-time consent snapshot")
        check(fixture.controller.store?.items.first(where: { $0.id == capturedBeforeRevocation })?.text
              == "Synthetic OCR whose consent was revoked while OCR was pending.",
              "local OCR text remains stored after title consent is revoked")
    }

    private static func verifyGeneratedTitleRenameAndDragLease(
        _ sourceImage: URL,
        root: URL,
        defaults: UserDefaults,
        imageData: Data
    ) throws {
        SettingsPreferences.setImageTitlesEnabled(true, defaults: defaults)
        let fixture = Fixture(defaults: defaults, dataDirectory: root.appendingPathComponent("rename", isDirectory: true))
        fixture.controller.imageTitlePreferenceChanged(enabled: true)
        let id = try fixture.controller.smokeBeginImageOCR(sourceImage)
        guard let original = fixture.controller.store?.items.first(where: { $0.id == id }),
              let oldURL = fixture.controller.store?.imageURL(for: original) else {
            throw CheckFailure(description: "captured image was not stored")
        }
        let oldDate = original.createdAt
        fixture.leases.beginDrag(for: oldURL)
        let recognizedText = "Synthetic OCR: a warm cup beside a book."
        fixture.controller.smokeFinishImageOCR(recognizedText, for: id)
        check(fixture.requestCount == 1, "enabled capture submits one title request")
        check(fixture.pendingTitles.first?.isStillConsented() == true, "title request is submitted with valid per-image consent")

        fixture.completeTitle(0, with: "Warm Cup")
        let unchanged = fixture.controller.store?.items.first(where: { $0.id == id })
        check(unchanged?.title == nil, "managed-file rename waits while its drag lease is active")
        check(FileManager.default.fileExists(atPath: oldURL.path), "original managed file remains available during the drag")
        check(fixture.controller.store?.items.filter({ $0.kind == .image }).count == 1,
              "title generation must not create a second stored image")

        try fixture.endDrag(oldURL)
        guard let renamed = fixture.controller.store?.items.first(where: { $0.id == id }),
              let newURL = fixture.controller.store?.imageURL(for: renamed) else {
            throw CheckFailure(description: "titled image was not retained")
        }
        check(renamed.title == "Warm Cup", "provider title is persisted")
        check(renamed.id == id && renamed.createdAt == oldDate && renamed.text == recognizedText,
              "rename preserves image identity, date, and OCR text")
        check(newURL != oldURL && !FileManager.default.fileExists(atPath: oldURL.path),
              "title renames the existing managed file")
        check(fixture.controller.store?.search("Warm Cup").contains(where: { $0.id == id }) == true,
              "generated title is searchable")
        let renamedData = try Data(contentsOf: newURL)
        check(renamedData == imageData, "renamed image bytes remain unchanged")
        let reloadedStore = try LibraryStore(dataDirectory: fixture.dataDirectory)
        guard let reloaded = reloadedStore.items.first(where: { $0.id == id }) else {
            throw CheckFailure(description: "renamed image was not present after store reload")
        }
        check(reloaded.id == id && reloaded.createdAt == oldDate && reloaded.title == "Warm Cup"
              && reloaded.imageFilename == renamed.imageFilename && reloaded.text == recognizedText,
              "title, filename, identity, date, and OCR text survive LibraryStore reload")

    }

    private static func verifyRevocationAndDeletion(_ sourceImage: URL, root: URL, defaults: UserDefaults) throws {
        SettingsPreferences.setImageTitlesEnabled(true, defaults: defaults)
        let fixture = Fixture(defaults: defaults, dataDirectory: root.appendingPathComponent("revocation", isDirectory: true))
        fixture.controller.imageTitlePreferenceChanged(enabled: true)
        let id = try fixture.controller.smokeBeginImageOCR(sourceImage)
        fixture.controller.smokeFinishImageOCR("Synthetic OCR pending title response.", for: id)
        guard let item = fixture.controller.store?.items.first(where: { $0.id == id }),
              let url = fixture.controller.store?.imageURL(for: item) else {
            throw CheckFailure(description: "pending title image was not stored")
        }
        check(fixture.requestCount == 1, "enabled capture submits one title request")
        SettingsPreferences.setImageTitlesEnabled(false, defaults: defaults)
        fixture.controller.imageTitlePreferenceChanged(enabled: false)
        SettingsPreferences.setImageTitlesEnabled(true, defaults: defaults)
        fixture.controller.imageTitlePreferenceChanged(enabled: true)
        check(!fixture.pendingTitles[0].isStillConsented(), "off/on revokes pending title consent by revision")
        fixture.completeTitle(0, with: "Must Not Commit")
        check(fixture.controller.store?.items.first(where: { $0.id == id })?.title == nil,
              "a delayed result cannot commit after consent revocation")
        check(FileManager.default.fileExists(atPath: url.path), "revocation leaves the managed image in place")

        let deleted = try fixture.controller.smokeBeginImageOCR(sourceImage)
        guard let deletedItem = fixture.controller.store?.items.first(where: { $0.id == deleted }),
              let deletedURL = fixture.controller.store?.imageURL(for: deletedItem) else {
            throw CheckFailure(description: "deletion fixture image was not stored")
        }
        fixture.controller.smokeFinishImageOCR("Synthetic OCR pending deletion.", for: deleted)
        let pendingIndex = fixture.pendingTitles.count - 1
        fixture.leases.beginDrag(for: deletedURL)
        try fixture.controller.store?.delete(deleted)
        check(FileManager.default.fileExists(atPath: deletedURL.path), "deletion waits for its active drag lease")
        try fixture.endDrag(deletedURL)
        check(!FileManager.default.fileExists(atPath: deletedURL.path), "deferred deletion removes the managed file after drag release")
        fixture.completeTitle(pendingIndex, with: "Deleted Image")
        check(fixture.controller.store?.items.contains(where: { $0.id == deleted }) == false,
              "a delayed title result cannot restore a deleted item")
    }


    private static func verifyUTF8FilenameCollisionBound(_ sourceImage: URL, root: URL) throws {
        let store = try LibraryStore(dataDirectory: root.appendingPathComponent("filenames", isDirectory: true))
        let first = try store.addImage(sourceImage)
        let second = try store.addImage(sourceImage)
        let longTitle = String(repeating: "𐐀", count: 120)
        _ = try store.updateImageTitle(longTitle, for: first.id)
        _ = try store.updateImageTitle(longTitle, for: second.id)
        guard let secondFilename = store.items.first(where: { $0.id == second.id })?.imageFilename else {
            throw CheckFailure(description: "collision-suffixed title filename was not saved")
        }
        check(secondFilename.hasSuffix("-2.png"), "collision resolution includes a suffix and preserved extension")
        check(secondFilename.utf8.count <= 255, "UTF-8 filename byte limit includes suffix and extension")
        check(store.items.filter({ $0.kind == .image }).count == 2, "filename collision handling retains each original image once")
    }

    private static func makePNG() throws -> Data {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 2,
            pixelsHigh: 2,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let pixels = bitmap.bitmapData else {
            throw CheckFailure(description: "could not create synthetic image pixels")
        }
        for index in 0..<(bitmap.bytesPerRow * bitmap.pixelsHigh) { pixels[index] = 0xff }
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw CheckFailure(description: "could not encode synthetic PNG")
        }
        return png
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fail(message) }
    }

    private static func fail(_ message: String) -> Never {
        fputs("Image title lifecycle check failed: \(message)\n", stderr)
        exit(1)
    }

    private struct CheckFailure: Error, LocalizedError {
        let description: String
        var errorDescription: String? { description }
    }
}
#endif

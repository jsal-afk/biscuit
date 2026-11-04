import AppKit
import Foundation

@MainActor
enum LibraryExportBehaviorChecks {
    private struct CheckFailure: Error, LocalizedError {
        let description: String
        var errorDescription: String? { description }
    }

    static func run() throws {
        try verifyLibraryStoreImageExport()
        print("LibraryStore image export replacement checks passed")
    }

    private static func verifyLibraryStoreImageExport() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("biscuit-library-export-check-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: root) }

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
            throw CheckFailure(description: "could not create the synthetic image pixels")
        }
        for index in 0..<(bitmap.bytesPerRow * bitmap.pixelsHigh) {
            pixels[index] = UInt8(index % 251)
        }
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw CheckFailure(description: "could not encode the synthetic image")
        }
        let fixtureURL = root.appendingPathComponent("fixture.png")
        try png.write(to: fixtureURL)

        let store = try LibraryStore(dataDirectory: root.appendingPathComponent("store", isDirectory: true))
        let item = try store.addImage(fixtureURL, recognizedText: "export replacement fixture")
        guard let sourceURL = store.imageURL(for: item) else {
            throw CheckFailure(description: "LibraryStore did not retain the source image")
        }
        let sourceBytes = try Data(contentsOf: sourceURL)
        let destinationDirectory = root.appendingPathComponent("destinations", isDirectory: true)
        try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: false)

        let newDestination = destinationDirectory.appendingPathComponent("new-image.png")
        try store.export(item, to: newDestination)
        let newDestinationBytes = try Data(contentsOf: newDestination)
        try check(newDestinationBytes == sourceBytes, "new image export preserves exact source bytes")

        let replacementDestination = destinationDirectory.appendingPathComponent("replace-image.png")
        let previousBytes = Data("pre-existing destination".utf8)
        try previousBytes.write(to: replacementDestination)
        try store.export(item, to: replacementDestination)
        let replacementBytes = try Data(contentsOf: replacementDestination)
        try check(replacementBytes == sourceBytes, "image export replaces an existing destination with exact source bytes")
        let sourceAfterReplacement = try Data(contentsOf: sourceURL)
        try check(sourceAfterReplacement == sourceBytes, "replacement leaves the managed source bytes unchanged")

        try store.export(item, to: sourceURL)
        let sourceAfterSamePathExport = try Data(contentsOf: sourceURL)
        try check(sourceAfterSamePathExport == sourceBytes, "exporting an image to its own managed path is a safe no-op")

        let protectedDestination = destinationDirectory.appendingPathComponent("protected-image.png")
        let protectedBytes = Data("preserve on replacement failure".utf8)
        try protectedBytes.write(to: protectedDestination)
        var protected = false
        defer {
            if protected {
                try? fileManager.setAttributes([.immutable: false], ofItemAtPath: protectedDestination.path)
            }
        }
        try fileManager.setAttributes([.immutable: true], ofItemAtPath: protectedDestination.path)
        protected = true
        var replacementFailed = false
        do {
            try store.export(item, to: protectedDestination)
        } catch {
            replacementFailed = true
        }
        try fileManager.setAttributes([.immutable: false], ofItemAtPath: protectedDestination.path)
        protected = false
        let protectedBytesAfterFailure = try Data(contentsOf: protectedDestination)
        try check(replacementFailed, "a blocked filesystem replacement reports failure")
        try check(protectedBytesAfterFailure == protectedBytes,
                  "failed atomic replacement preserves the old destination bytes")
        let leftoverStaging = try fileManager.contentsOfDirectory(atPath: destinationDirectory.path)
            .filter { $0.hasPrefix(".biscuit-export-") }
        try check(leftoverStaging.isEmpty, "the tested immutable-destination failure cleans its staging directory")
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ label: String) throws {
        guard condition() else { throw CheckFailure(description: label) }
    }
}

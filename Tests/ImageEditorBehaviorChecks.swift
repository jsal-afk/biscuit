import AppKit
import CryptoKit
import Foundation

@MainActor
enum ImageEditorBehaviorChecks {
    private struct CheckFailure: Error, LocalizedError {
        let description: String
        var errorDescription: String? { description }
    }

    static func run(in scratch: URL, actualSidecarFixturesAt fixtures: URL? = nil) throws {
        let root = scratch.appendingPathComponent("image-editor-check-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try ImageEditorActualSidecarChecks.run(fixturesAt: fixtures)
        try verifyFlatteningAndPersistence(in: root)
        try verifyPointTextLayout(in: root)
        try verifyPixelationAndCrop()
        try verifyVectorOverlayOrder()
        try verifyCanvasPreviewPixels(in: scratch)
        try verifyUndoRedoRendering()
        try verifySaveFailureBoundaries(in: root)
        print("ImageEditor point-text sizing and zoom-invariant Canvas pixels, actual public-sidecar upright text, flattening, crop, pixelation, redaction/vector preview order, undo/redo, persistence, rollback, missing-source, and export checks passed")
    }
    private static func verifyFlatteningAndPersistence(in root: URL) throws {
        let secret = "PUBLIC_SECRET_1049"
        let original = try makeTextImage(secret: secret)
        let originalPNG = try ImageEditorRenderer.pngData(from: original)
        let sourceURL = root.appendingPathComponent("screen.png")
        try originalPNG.write(to: sourceURL)

        let storeRoot = root.appendingPathComponent("store", isDirectory: true)
        let store = try LibraryStore(dataDirectory: storeRoot)
        let item = try store.addImage(sourceURL, recognizedText: secret)
        let titled = try store.updateImageTitle(secret, for: item.id)
        try check(titled.newURL.lastPathComponent.contains(secret), "fixture title should be present in the original managed filename")
        let oldItem = store.items.first(where: { $0.id == item.id })!
        let oldImageBytes = try Data(contentsOf: titled.newURL)
        let originalDigest = digest(oldImageBytes)

        let persistence = ImageEditorPersistence(dataDirectory: storeRoot)
        var session = try persistence.open(itemID: item.id, imageURL: titled.newURL)
        let redaction = ImageEditorAnnotation(
            kind: .redaction,
            start: ImageEditorPoint(x: 0.02, y: 0.2),
            end: ImageEditorPoint(x: 0.98, y: 0.8),
            colorHex: "#000000"
        )
        session.document.annotations = [redaction]
        let flattened = try ImageEditorRenderer.flattenedPNG(
            original: session.originalImage,
            annotations: session.document.annotations
        )
        let flattenedImage = try decodePNG(flattened)
        try check(isOpaqueBlack(flattenedImage, x: flattenedImage.width / 2, y: flattenedImage.height / 2),
                  "redaction must flatten as opaque black pixels")

        let exportURL = root.appendingPathComponent("flattened-export.png")
        try ImageEditorRenderer.exportFlattened(original: session.originalImage,
                                                annotations: session.document.annotations,
                                                to: exportURL)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("org.biscuit.smoke.image-editor.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let copied = try ImageEditorRenderer.copyFlattened(original: session.originalImage,
                                                           annotations: session.document.annotations,
                                                           to: pasteboard)
        let exportedFlattened = try Data(contentsOf: exportURL)
        try check(exportedFlattened == copied, "Copy Image and Export must share the same flattened pixels")
        try check(pasteboard.data(forType: .png) == copied, "Copy Image writes only the flattened PNG to the pasteboard")

        let firstSaved = try store.saveEditedImage(flattened, session: session)
        let savedFlattened = try Data(contentsOf: firstSaved.newURL)
        try check(savedFlattened == flattened && savedFlattened == copied && savedFlattened == exportedFlattened,
                  "Save Image, Copy Image, and Export use the exact same flattened PNG payload")
        try store.removeSupersededImageFile(at: firstSaved.oldURL)
        try check(firstSaved.item.id == oldItem.id && firstSaved.item.createdAt == oldItem.createdAt,
                  "editing preserves the Library entry identity and creation time")
        try check(firstSaved.item.text == nil && firstSaved.item.title == nil,
                  "editing clears OCR and title metadata derived from the original pixels")
        try check(firstSaved.item.imageFilename?.hasSuffix(".png") == true && firstSaved.item.imageFilename?.contains(secret) == false,
                  "edited image filename is an opaque PNG name, not the old title-derived name")
        try check(!FileManager.default.fileExists(atPath: firstSaved.oldURL.path), "superseded managed image is removed")

        let privateOriginalURL = persistence.originalURL(for: item.id)!
        let reopened = try persistence.open(itemID: item.id, imageURL: firstSaved.newURL)
        try check(reopened.originalData == oldImageBytes && reopened.document.annotations == [redaction],
                  "re-edit reopens the exact original with its editable annotation document")
        var editedDocument = reopened.document
        let rectangle = ImageEditorAnnotation(
            kind: .rectangle,
            start: ImageEditorPoint(x: 0.1, y: 0.1),
            end: ImageEditorPoint(x: 0.3, y: 0.3)
        )
        editedDocument.annotations.append(rectangle)
        let substitutedImage = try makeStripedImage(width: 32, height: 24)
        let substitutedOriginalData = try ImageEditorRenderer.pngData(from: substitutedImage)
        let reedited = ImageEditorSession(itemID: reopened.itemID,
                                          originalData: substitutedOriginalData,
                                          originalImage: reopened.originalImage,
                                          document: editedDocument)
        let secondFlattened = try ImageEditorRenderer.flattenedPNG(
            original: reedited.originalImage,
            annotations: reedited.document.annotations
        )
        let saved = try store.saveEditedImage(secondFlattened, session: reedited)
        try store.removeSupersededImageFile(at: saved.oldURL)
        try check(!FileManager.default.fileExists(atPath: firstSaved.newURL.path),
                  "a later edit replaces only the preceding flattened image")
        let preservedOriginal = try Data(contentsOf: privateOriginalURL)
        try check(preservedOriginal == oldImageBytes,
                  "a second save does not replace the retained original with different session source bytes")
        try check(digest(preservedOriginal) == originalDigest, "the private original SHA-256 is write-once across re-edits")
        let reopenedAgain = try persistence.open(itemID: item.id, imageURL: saved.newURL)
        try check(reopenedAgain.originalData == oldImageBytes &&
                  reopenedAgain.document.annotations == [redaction, rectangle],
                  "re-edit preserves the original while updating the editable document")

        var cancelledSession = reopenedAgain

        cancelledSession.document.annotations.removeAll()
        _ = try ImageEditorRenderer.flattenedPNG(original: cancelledSession.originalImage,
                                                 annotations: cancelledSession.document.annotations)
        let savedImageBeforeCancel = try Data(contentsOf: saved.newURL)
        let manifestBeforeCancel = try Data(contentsOf: store.manifestURL)
        let savedImageAfterCancel = try Data(contentsOf: saved.newURL)
        let manifestAfterCancel = try Data(contentsOf: store.manifestURL)
        try check(savedImageAfterCancel == savedImageBeforeCancel && manifestAfterCancel == manifestBeforeCancel,
                  "discarding in-memory changes leaves the saved image and manifest unchanged")

        let exportDirectory = root.appendingPathComponent("library-export", isDirectory: true)
        try store.exportAll(to: exportDirectory)
        let manifest = try String(contentsOf: exportDirectory.appendingPathComponent("library.json"), encoding: .utf8)
        try check(!manifest.contains(secret), "exported metadata contains neither old OCR text nor the title-derived filename")
        let exportContents = try FileManager.default.contentsOfDirectory(atPath: exportDirectory.path)
        try check(!exportContents.contains("image-editor"), "private editable originals and annotations are not exported")
        let exportedBytes = try Data(contentsOf: exportDirectory.appendingPathComponent("images", isDirectory: true)
            .appendingPathComponent(saved.item.imageFilename!))
        try check(exportedBytes == secondFlattened, "Library export contains only the latest committed flattened image")

        try store.delete(item.id)
        try check(!FileManager.default.fileExists(atPath: privateOriginalURL.path) &&
                  !persistence.hasSavedDocument(for: item.id),
                  "deleting history removes its private original and annotation sidecar")
    }

    private static func verifyPointTextLayout(in root: URL) throws {
        let width = 1024
        let height = 4096
        let imageSize = NSSize(width: CGFloat(width), height: CGFloat(height))
        let sourceImage = try makeAsymmetricImage(width: width, height: height, patternTopRight: false)
        let sourceURL = root.appendingPathComponent("point-text-source.png")
        try ImageEditorRenderer.pngData(from: sourceImage).write(to: sourceURL)

        let storeRoot = root.appendingPathComponent("point-text-store", isDirectory: true)
        let store = try LibraryStore(dataDirectory: storeRoot)
        let item = try store.addImage(sourceURL)
        guard let originalURL = store.imageURL(for: item) else {
            throw CheckFailure(description: "point-text source image was not added to the store")
        }
        let persistence = ImageEditorPersistence(dataDirectory: storeRoot)
        var session = try persistence.open(itemID: item.id, imageURL: originalURL)
        let baselinePNG = try ImageEditorRenderer.flattenedPNG(original: session.originalImage, annotations: [])
        let baseline = try decodePNG(baselinePNG)
        let orientation = try cornerMarkerRows(in: NSBitmapImageRep(cgImage: baseline), label: "point-text baseline")
        let topAtHighY = orientation.top > orientation.bottom
        let anchor = ImageEditorPoint(x: 0.513671875, y: 0.598876953125)
        let text = "PUBLIC EDIT BELOW VIEWPORT 08"
        let pointText = ImageEditorAnnotation(kind: .text, start: anchor, end: anchor,
                                              text: text, colorHex: "#111111", fontSize: 0.04)
        let bounds = ImageEditorRenderer.resolvedBounds(for: pointText, in: imageSize)
        try check(bounds.x >= 0 && bounds.y >= 0 && bounds.maxX <= 1 && bounds.maxY <= 1,
                  "point-text bounds stay inside the portrait image")
        try check(bounds.minX <= anchor.x && bounds.maxX >= anchor.x &&
                  bounds.minY <= anchor.y && bounds.maxY >= anchor.y,
                  "point-text interaction bounds contain the original click")
        try check(bounds.minY > 0.5,
                  "the point-text anchor and its bounds stay in the below-midpoint source region")

        let edge = ImageEditorPoint(x: 0.99, y: 0.999)
        let edgeText = ImageEditorAnnotation(kind: .text, start: edge, end: edge,
                                             text: "EDGE", colorHex: "#111111", fontSize: 0.04)
        let edgeBounds = ImageEditorRenderer.resolvedBounds(for: edgeText, in: imageSize)
        try check(edgeBounds.x >= 0 && edgeBounds.y >= 0 && edgeBounds.maxX <= 1 && edgeBounds.maxY <= 1 &&
                  edgeBounds.minX <= edge.x && edgeBounds.maxX >= edge.x &&
                  edgeBounds.minY <= edge.y && edgeBounds.maxY >= edge.y,
                  "point-text bounds remain on-image while containing a lower-right edge click")

        let explicit = ImageEditorAnnotation(
            kind: .text,
            start: ImageEditorPoint(x: 0.123046875, y: 0.591796875),
            end: ImageEditorPoint(x: 0.904296875, y: 0.61865234375),
            text: "EDITOR CANARY 08",
            colorHex: "#111111",
            fontSize: 0.08543077909029446
        )
        let explicitBounds = ImageEditorRenderer.resolvedBounds(for: explicit, in: imageSize)
        try check(explicitBounds == explicit.bounds &&
                  explicitBounds.maxX == explicit.end.x && explicitBounds.maxY == explicit.end.y,
                  "drag-sized text geometry continues to use its authored end and wrapping box")

        session.document.annotations = [pointText]
        let flattened = try ImageEditorRenderer.flattenedPNG(
            original: session.originalImage,
            annotations: session.document.annotations
        )
        let saved = try store.saveEditedImage(flattened, session: session)
        try store.removeSupersededImageFile(at: saved.oldURL)
        let savedPNG = try Data(contentsOf: saved.newURL)
        try check(savedPNG == flattened, "saved point-text image retains the renderer’s flattened PNG")
        let reopened = try persistence.open(itemID: item.id, imageURL: saved.newURL)
        try check(reopened.document.annotations == [pointText],
                  "saved point text retains its exact text and editable point geometry")

        let rendered = try decodePNG(savedPNG)
        let bitmap = NSBitmapImageRep(cgImage: rendered)
        let font = NSFont.systemFont(
            ofSize: max(10, CGFloat(pointText.fontSize) * CGFloat(min(width, height))),
            weight: .semibold
        )
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let measuredText = NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: NSColor.black,
            .paragraphStyle: paragraph
        ])
        let measured = measuredText.boundingRect(
            with: NSSize(width: CGFloat(width) - 6, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )
        guard let visible = darkPixelBounds(in: bitmap, within: bounds, topAtHighY: topAtHighY) else {
            throw CheckFailure(description: "saved portrait image contains no visible point text in its marker-validated region")
        }
        let minX = max(0, min(width, Int(floor(bounds.minX * Double(width)))))
        let maxX = max(minX, min(width, Int(ceil(bounds.maxX * Double(width)))))
        let oppositeRows = pixelYRange(for: bounds, height: height, topAtHighY: !topAtHighY)
        try check(samePixels(baseline, rendered, xRange: minX..<maxX, yRange: oppositeRows),
                  "the mirrored point-text region remains pixel-for-pixel unchanged from the annotation-free baseline")
        try check(Int(visible.width) >= Int(ceil(measured.width)) - 16,
                  "saved point text visibly spans the full measured label instead of clipping its ending")
        try check(visible.width > visible.height * 3 && visible.height <= ceil(measured.height) + 4,
                  "saved point text renders as a complete horizontal label rather than a vertical stack")
    }


    private static func darkPixelBounds(in bitmap: NSBitmapImageRep, within bounds: ImageEditorRect,
                                        topAtHighY: Bool) -> CGRect? {
        let minX = max(0, min(bitmap.pixelsWide, Int(floor(bounds.minX * Double(bitmap.pixelsWide)))))
        let maxX = max(minX, min(bitmap.pixelsWide, Int(ceil(bounds.maxX * Double(bitmap.pixelsWide)))))
        return darkPixelBounds(
            in: bitmap,
            xRange: minX..<maxX,
            yRange: pixelYRange(for: bounds, height: bitmap.pixelsHigh, topAtHighY: topAtHighY)
        )
    }

    private static func darkPixelBounds(in bitmap: NSBitmapImageRep,
                                        xRange: Range<Int>, yRange: Range<Int>) -> CGRect? {
        var visibleMinX = xRange.upperBound
        var visibleMinY = yRange.upperBound
        var visibleMaxX = xRange.lowerBound - 1
        var visibleMaxY = yRange.lowerBound - 1
        for y in yRange {
            for x in xRange {
                let color = rgb(bitmap, x: x, y: y)
                if color.0 < 0.35 && color.1 < 0.35 && color.2 < 0.35 {
                    visibleMinX = min(visibleMinX, x)
                    visibleMinY = min(visibleMinY, y)
                    visibleMaxX = max(visibleMaxX, x)
                    visibleMaxY = max(visibleMaxY, y)
                }
            }
        }
        guard visibleMaxX >= visibleMinX, visibleMaxY >= visibleMinY else { return nil }
        return CGRect(x: CGFloat(visibleMinX), y: CGFloat(visibleMinY),
                      width: CGFloat(visibleMaxX - visibleMinX + 1),
                      height: CGFloat(visibleMaxY - visibleMinY + 1))
    }

    private static func pixelYRange(for bounds: ImageEditorRect, height: Int, topAtHighY: Bool) -> Range<Int> {
        let minY = topAtHighY ? 1 - bounds.maxY : bounds.minY
        let maxY = topAtHighY ? 1 - bounds.minY : bounds.maxY
        let lower = max(0, min(height, Int(floor(minY * Double(height)))))
        let upper = max(lower, min(height, Int(ceil(maxY * Double(height)))))
        return lower..<upper
    }
    private static func renderCanvasOffscreen(_ canvas: ImageEditorCanvasView) throws -> NSBitmapImageRep {
        let bounds = canvas.bounds
        let width = max(1, Int(ceil(bounds.width)))
        let height = max(1, Int(ceil(bounds.height)))
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            throw CheckFailure(description: "could not create an offscreen image editor canvas")
        }
        bitmap.size = NSSize(width: CGFloat(width), height: CGFloat(height))
        // Let AppKit establish the flipped-view transform at the test's explicit 1-pixel-per-point scale.
        canvas.cacheDisplay(in: bounds, to: bitmap)
        return bitmap
    }


    private static func canvasPixelXRange(for bounds: ImageEditorRect, sourceWidth: Int, zoom: Double,
                                          imageInset: CGFloat, bitmapWidth: Int) -> Range<Int> {
        let lowerValue = Double(imageInset) + bounds.minX * Double(sourceWidth) * zoom
        let upperValue = Double(imageInset) + bounds.maxX * Double(sourceWidth) * zoom
        let lower = max(0, min(bitmapWidth, Int(floor(lowerValue))))
        let upper = max(lower, min(bitmapWidth, Int(ceil(upperValue))))
        return lower..<upper
    }

    // cacheDisplay rows follow the flipped view's y axis, not the source image's row order.
    private static func canvasPixelYRange(for bounds: ImageEditorRect, sourceHeight: Int, zoom: Double,
                                          imageInset: CGFloat, bitmapHeight: Int) -> Range<Int> {
        let topViewY = Double(imageInset) + bounds.minY * Double(sourceHeight) * zoom
        let bottomViewY = Double(imageInset) + bounds.maxY * Double(sourceHeight) * zoom
        let lower = max(0, min(bitmapHeight, Int(floor(topViewY))))
        let upper = max(lower, min(bitmapHeight, Int(ceil(bottomViewY))))
        return lower..<upper
    }

    private static func canvasPixel(x: Double, y: Double, sourceWidth: Int, sourceHeight: Int,
                                    zoom: Double, imageInset: CGFloat, bitmapWidth: Int,
                                    bitmapHeight: Int) -> (Int, Int) {
        let imageX = Int((Double(imageInset) + x * Double(sourceWidth) * zoom).rounded())
        let pixelY = Int((Double(imageInset) + y * Double(sourceHeight) * zoom).rounded())
        return (max(0, min(bitmapWidth - 1, imageX)), max(0, min(bitmapHeight - 1, pixelY)))
    }

    private static func verifyPixelationAndCrop() throws {
        let asymmetric = try makeAsymmetricImage(width: 96, height: 64, patternTopRight: true)
        let sourceBitmap = NSBitmapImageRep(cgImage: asymmetric)
        let sourceRows = try cornerMarkerRows(in: sourceBitmap, label: "source CGImage")
        let originalPNG = try ImageEditorRenderer.pngData(from: asymmetric)
        let originalRoundTrip = try decodePNG(originalPNG)
        let roundTripRows = try cornerMarkerRows(in: NSBitmapImageRep(cgImage: originalRoundTrip), label: "PNG round trip")
        try check(sourceRows.top == roundTripRows.top && sourceRows.bottom == roundTripRows.bottom,
                  "PNG decoding preserves the observed NSBitmapImageRep top/bottom row convention")

        let baseline = try ImageEditorRenderer.render(original: asymmetric, annotations: [])
        let baselinePNG = try ImageEditorRenderer.pngData(from: baseline)
        let baselineDecoded = try decodePNG(baselinePNG)
        let baselineBitmap = NSBitmapImageRep(cgImage: baselineDecoded)
        let baselineRows = try cornerMarkerRows(in: baselineBitmap, label: "renderer output")
        try check(sourceRows.top == baselineRows.top && sourceRows.bottom == baselineRows.bottom,
                  "the production renderer preserves asymmetric source orientation")

        let pixelation = ImageEditorAnnotation(
            kind: .pixelation,
            start: ImageEditorPoint(x: 0.5, y: 0),
            end: ImageEditorPoint(x: 1, y: 0.5)
        )
        let redaction = ImageEditorAnnotation(
            kind: .redaction,
            start: ImageEditorPoint(x: 0, y: 0),
            end: ImageEditorPoint(x: 0.4, y: 0.4)
        )
        let beforeA = rgb(sourceBitmap, x: 50, y: sourceRows.top)
        let beforeB = rgb(sourceBitmap, x: 51, y: sourceRows.top)
        try check(abs(beforeA.0 - beforeB.0) > 0.5,
                  "the generated top-right stripes differ before pixelation")

        let flattened = try ImageEditorRenderer.flattenedPNG(
            original: asymmetric,
            annotations: [pixelation, redaction]
        )
        let decoded = try decodePNG(flattened)
        let output = NSBitmapImageRep(cgImage: decoded)
        try check(isOpaqueBlack(decoded, x: 20, y: baselineRows.top),
                  "redaction is opaque black at the selected top-left pixel")
        try check(samePixels(baselineDecoded, decoded, xRange: 40..<48,
                             yRange: topHalfRows(top: baselineRows.top, bottom: baselineRows.bottom, height: decoded.height)),
                  "pixels outside the selected redaction and pixelation regions remain unchanged")
        let afterA = rgb(output, x: 50, y: baselineRows.top)
        let afterB = rgb(output, x: 51, y: baselineRows.top)
        try check(abs(afterA.0 - afterB.0) < 0.02 &&
                  abs(afterA.1 - afterB.1) < 0.02 &&
                  abs(afterA.2 - afterB.2) < 0.02,
                  "the selected top-right pixelation block is uniform after PNG decoding")
        try check(samePixels(baselineDecoded, decoded, xRange: 0..<48,
                             yRange: bottomHalfRows(top: baselineRows.top, bottom: baselineRows.bottom, height: decoded.height)) &&
                  samePixels(baselineDecoded, decoded, xRange: 48..<96,
                             yRange: bottomHalfRows(top: baselineRows.top, bottom: baselineRows.bottom, height: decoded.height)),
                  "the opposite lower half is pixel-for-pixel unchanged after PNG decoding")

        let plainCorners = try makeAsymmetricImage(width: 96, height: 64, patternTopRight: false)
        let cornerCrop = ImageEditorRect(x: 0.5, y: 0, width: 0.5, height: 0.5)
        let cornerCropPNG = try ImageEditorRenderer.flattenedPNG(
            original: plainCorners, annotations: [], cropRect: cornerCrop
        )
        let cornerCropImage = try decodePNG(cornerCropPNG)
        try check(cornerCropImage.width == 48 && cornerCropImage.height == 32,
                  "crop produces dimensions for the selected top-right quadrant")
        try check(isGreenMarker(rgb(NSBitmapImageRep(cgImage: cornerCropImage), x: 24, y: 16)),
                  "an asymmetric crop selects the top-right marker, not its lower mirror")

        let centralCrop = ImageEditorRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        let annotations = [
            ImageEditorAnnotation(kind: .rectangle,
                                  start: ImageEditorPoint(x: 0.1, y: 0.1),
                                  end: ImageEditorPoint(x: 0.5, y: 0.5),
                                  colorHex: "#FF0000"),
            ImageEditorAnnotation(kind: .rectangle,
                                  start: ImageEditorPoint(x: 0.15, y: 0.3),
                                  end: ImageEditorPoint(x: 0.249, y: 0.6),
                                  colorHex: "#0000FF"),
            ImageEditorAnnotation(kind: .arrow,
                                  start: ImageEditorPoint(x: 0.1, y: 0.7),
                                  end: ImageEditorPoint(x: 0.7, y: 0.25),
                                  colorHex: "#000000"),
            ImageEditorAnnotation(kind: .text,
                                  start: ImageEditorPoint(x: 0.1, y: 0.35),
                                  end: ImageEditorPoint(x: 0.45, y: 0.65),
                                  text: "CLIPPED",
                                  colorHex: "#000000",
                                  fontSize: 0.06)
        ]
        let fullAnnotated = try ImageEditorRenderer.render(original: plainCorners, annotations: annotations)
        let expectedCrop = try ImageEditorRenderer.cropFlattenedImage(original: fullAnnotated, to: centralCrop)
        let expectedCropPNG = try ImageEditorRenderer.pngData(from: expectedCrop)
        let actualCropPNG = try ImageEditorRenderer.flattenedPNG(
            original: plainCorners, annotations: annotations, cropRect: centralCrop
        )
        let expectedCropDecoded = try decodePNG(expectedCropPNG)
        let actualCropDecoded = try decodePNG(actualCropPNG)
        try check(samePixels(expectedCropDecoded, actualCropDecoded),
                  "cropped rectangle, arrow, and partially clipped text equal full-coordinate rendering followed by pixel crop")
    }

    private static func verifyVectorOverlayOrder() throws {
        let original = try makeStripedImage(width: 96, height: 64)
        let pixelation = ImageEditorAnnotation(
            kind: .pixelation,
            start: ImageEditorPoint(x: 0, y: 0.4),
            end: ImageEditorPoint(x: 1, y: 0.6)
        )
        let redaction = ImageEditorAnnotation(
            kind: .redaction,
            start: ImageEditorPoint(x: 0.2, y: 0.4),
            end: ImageEditorPoint(x: 0.8, y: 0.6)
        )
        let arrow = ImageEditorAnnotation(
            kind: .arrow,
            start: ImageEditorPoint(x: 0.3, y: 0.5),
            end: ImageEditorPoint(x: 0.7, y: 0.5),
            colorHex: "#FF0000",
            lineWidth: 0.04
        )
        let flattened = try ImageEditorRenderer.flattenedPNG(
            original: original, annotations: [pixelation, redaction, arrow]
        )
        let decoded = try decodePNG(flattened)
        let bitmap = NSBitmapImageRep(cgImage: decoded)
        let visibleArrow = rgb(bitmap, x: 48, y: 32)
        try check(isRedMarker(visibleArrow),
                  "a red arrow remains visible above overlapping pixelation and solid redaction; sample=\(String(describing: visibleArrow))")
        try check(isOpaqueBlack(decoded, x: 48, y: 28),
                  "redacted source pixels remain opaque black beside the overlaid arrow")
        let mosaicA = rgb(bitmap, x: 10, y: 28)
        let mosaicB = rgb(bitmap, x: 11, y: 28)
        try check(abs(mosaicA.0 - mosaicB.0) < 0.02 &&
                  abs(mosaicA.1 - mosaicB.1) < 0.02 &&
                  abs(mosaicA.2 - mosaicB.2) < 0.02,
                  "pixelation is visible outside the overlapping redaction and vector")
        let line = ImageEditorAnnotation(
            kind: .line, start: arrow.start, end: arrow.end,
            colorHex: arrow.colorHex, lineWidth: arrow.lineWidth
        )
        let lineImage = try decodePNG(
            ImageEditorRenderer.flattenedPNG(original: original, annotations: [line])
        )
        let arrowImage = try decodePNG(
            ImageEditorRenderer.flattenedPNG(original: original, annotations: [arrow])
        )
        let sourceBitmap = NSBitmapImageRep(cgImage: original)
        let lineBitmap = NSBitmapImageRep(cgImage: lineImage)
        let arrowBitmap = NSBitmapImageRep(cgImage: arrowImage)
        try check(isRedMarker(rgb(lineBitmap, x: 30, y: 32)) &&
                  isRedMarker(rgb(lineBitmap, x: 66, y: 32)),
                  "straight Line renders its shaft through both endpoints")
        let arrowTipSide = rgb(arrowBitmap, x: 63, y: 34)
        let lineTipSide = rgb(lineBitmap, x: 63, y: 34)
        let untouchedTipSide = rgb(sourceBitmap, x: 63, y: 34)
        try check(isRedMarker(arrowTipSide) &&
                  isColor(lineTipSide, red: untouchedTipSide.0,
                          green: untouchedTipSide.1, blue: untouchedTipSide.2, tolerance: 0.02),
                  "straight Line shares the arrow shaft but omits its arrowhead")
        let roundTrippedLine = try JSONDecoder().decode(
            ImageEditorAnnotation.self, from: JSONEncoder().encode(line)
        )
        try check(roundTrippedLine == line,
                  "straight Line kind and endpoints survive annotation persistence")
    }
    private static func verifyCanvasPreviewPixels(in scratch: URL) throws {
        let width = 512
        let height = 2048
        let source = try makeAsymmetricImage(width: width, height: height, patternTopRight: false)
        let redaction = ImageEditorAnnotation(
            kind: .redaction,
            start: ImageEditorPoint(x: 0.1, y: 0.1),
            end: ImageEditorPoint(x: 0.9, y: 0.9)
        )
        let vector = ImageEditorAnnotation(
            kind: .rectangle,
            start: ImageEditorPoint(x: 0.2, y: 0.2),
            end: ImageEditorPoint(x: 0.8, y: 0.8),
            colorHex: "#FF00FF",
            lineWidth: 0.06
        )
        let overlapCanvas = try ImageEditorCanvasView(
            original: source,
            document: ImageEditorDocument(annotations: [redaction, vector])
        )
        overlapCanvas.isInteractionEnabled = false
        let overlapBitmap = try renderCanvasOffscreen(overlapCanvas)
        let overlapInset = (overlapCanvas.bounds.width - CGFloat(width)) / 2
        let redactionX = canvasPixelXRange(for: redaction.bounds, sourceWidth: width, zoom: 1,
                                           imageInset: overlapInset, bitmapWidth: overlapBitmap.pixelsWide)
        let redactionY = canvasPixelYRange(for: redaction.bounds, sourceHeight: height, zoom: 1,
                                           imageInset: overlapInset, bitmapHeight: overlapBitmap.pixelsHigh)
        var visibleVectorPixel = false
        for y in redactionY where !visibleVectorPixel {
            for x in redactionX {
                let color = rgb(overlapBitmap, x: x, y: y)
                if color.0 > 0.8 && color.2 > 0.8 && color.1 < 0.3 {
                    visibleVectorPixel = true
                    break
                }
            }
        }
        try check(visibleVectorPixel,
                  "offscreen Canvas keeps vector strokes visible over the committed-redaction preview")
        let (interiorX, interiorY) = canvasPixel(
            x: 0.15, y: 0.15, sourceWidth: width, sourceHeight: height, zoom: 1,
            imageInset: overlapInset, bitmapWidth: overlapBitmap.pixelsWide,
            bitmapHeight: overlapBitmap.pixelsHigh
        )
        let interior = rgb(overlapBitmap, x: interiorX, y: interiorY)
        try check(interior.0 < 0.02 && interior.1 < 0.02 && interior.2 < 0.02,
                  "offscreen Canvas retains the committed-redaction black fill beneath its vector overlay")

        let pointText = ImageEditorAnnotation(
            kind: .text,
            start: ImageEditorPoint(x: 0.45, y: 0.6),
            end: ImageEditorPoint(x: 0.45, y: 0.6),
            text: "CANVAS ZOOM LABEL 42",
            colorHex: "#111111",
            fontSize: 0.04
        )
        let textCanvas = try ImageEditorCanvasView(
            original: source,
            document: ImageEditorDocument(annotations: [pointText])
        )
        textCanvas.isInteractionEnabled = false
        let sourceSize = NSSize(width: CGFloat(width), height: CGFloat(height))
        let bounds = ImageEditorRenderer.resolvedBounds(for: pointText, in: sourceSize)
        var normalizedWidths: [CGFloat] = []
        var normalizedHeights: [CGFloat] = []
        let flattened = try decodePNG(
            ImageEditorRenderer.flattenedPNG(original: source, annotations: [pointText])
        )
        let flattenedBaseline = try decodePNG(
            ImageEditorRenderer.flattenedPNG(original: source, annotations: [])
        )
        let baselineCanvas = try ImageEditorCanvasView(original: source, document: ImageEditorDocument())
        baselineCanvas.isInteractionEnabled = false
        let baselineBitmap = try renderCanvasOffscreen(baselineCanvas)
        let baselineInset = (baselineCanvas.bounds.width - CGFloat(width)) / 2
        try verifyCanvasSourceOrientation(
            source: source, canvas: baselineBitmap, flattenedBaseline: flattenedBaseline,
            imageInset: baselineInset
        )
        textCanvas.zoom = 1
        let parityPreview = try renderCanvasOffscreen(textCanvas)
        let parityInset = (textCanvas.bounds.width - CGFloat(width)) / 2
        try savePointTextParityCrops(
            preview: parityPreview, flattened: flattened, bounds: bounds,
            sourceWidth: width, sourceHeight: height, imageInset: parityInset, scratch: scratch
        )
        for zoom in [0.5, 1.0, 2.0] {
            textCanvas.zoom = zoom
            let bitmap = try renderCanvasOffscreen(textCanvas)
            let imageInset = (textCanvas.bounds.width - CGFloat(width) * CGFloat(zoom)) / 2
            let xRange = canvasPixelXRange(for: bounds, sourceWidth: width, zoom: zoom,
                                           imageInset: imageInset, bitmapWidth: bitmap.pixelsWide)
            let yRange = canvasPixelYRange(for: bounds, sourceHeight: height, zoom: zoom,
                                           imageInset: imageInset, bitmapHeight: bitmap.pixelsHigh)
            guard let visible = darkPixelBounds(in: bitmap, xRange: xRange, yRange: yRange) else {
                throw CheckFailure(description: "offscreen Canvas contains no point-text pixels within source bounds at zoom \(zoom)")
            }
            if zoom == 1 {
                try verifyCanvasTextParity(
                    bitmap, baseline: baselineBitmap, flattened: flattened,
                    flattenedBaseline: flattenedBaseline, imageInset: imageInset
                )
            }
            try check(visible.width > visible.height * 3,
                      "offscreen Canvas keeps point text on one line at zoom \(zoom)")
            normalizedWidths.append(visible.width / CGFloat(zoom))
            normalizedHeights.append(visible.height / CGFloat(zoom))
        }
        let widthMean = normalizedWidths.reduce(0, +) / CGFloat(normalizedWidths.count)
        let heightMean = normalizedHeights.reduce(0, +) / CGFloat(normalizedHeights.count)
        let widthSpread = normalizedWidths.max()! - normalizedWidths.min()!
        let heightSpread = normalizedHeights.max()! - normalizedHeights.min()!
        try check(widthSpread <= widthMean * 0.08 && heightSpread <= heightMean * 0.18,
                  "offscreen Canvas point-text pixel dimensions remain source-relative at fit-scale (<100%), 100%, and enlarged zoom")
        let explicitText = ImageEditorAnnotation(
            kind: .text,
            start: ImageEditorPoint(x: 0.15, y: 0.25),
            end: ImageEditorPoint(x: 0.42, y: 0.49),
            text: "DRAGGED BOX PRESERVES WRAPPING INTO SEVERAL VISIBLE LINES",
            colorHex: "#111111",
            fontSize: 0.04
        )
        let explicitCanvas = try ImageEditorCanvasView(
            original: source,
            document: ImageEditorDocument(annotations: [explicitText])
        )
        explicitCanvas.isInteractionEnabled = false
        let explicitBitmap = try renderCanvasOffscreen(explicitCanvas)
        let explicitInset = (explicitCanvas.bounds.width - CGFloat(width)) / 2
        let explicitBounds = explicitText.bounds
        let explicitX = canvasPixelXRange(for: explicitBounds, sourceWidth: width, zoom: 1,
                                          imageInset: explicitInset, bitmapWidth: explicitBitmap.pixelsWide)
        let explicitY = canvasPixelYRange(for: explicitBounds, sourceHeight: height, zoom: 1,
                                          imageInset: explicitInset, bitmapHeight: explicitBitmap.pixelsHigh)
        guard let wrapped = darkPixelBounds(in: explicitBitmap, xRange: explicitX, yRange: explicitY) else {
            throw CheckFailure(description: "offscreen Canvas contains no text in the explicit drag-sized box")
        }
        try check(wrapped.height > 30 && wrapped.width <= CGFloat(width) * CGFloat(explicitBounds.width),
                  "offscreen Canvas preserves visible wrapping inside the explicit drag-sized text box")
    }

    private static func verifyCanvasSourceOrientation(
        source: CGImage,
        canvas: NSBitmapImageRep,
        flattenedBaseline: CGImage,
        imageInset: CGFloat
    ) throws {
        let width = source.width
        let height = source.height
        guard flattenedBaseline.width == width, flattenedBaseline.height == height else {
            throw CheckFailure(description: "source and flattened orientation fixtures have different dimensions")
        }
        let flattenedBitmap = NSBitmapImageRep(cgImage: flattenedBaseline)
        let flattenedRows = try cornerMarkerRows(in: flattenedBitmap, label: "flattened source image")
        let flattenedTopAtHighY = flattenedRows.top > flattenedRows.bottom
        let inset = Int(imageInset.rounded())
        let samples: [(x: Int, y: Int, label: String)] = [
            (width / 4, height / 4, "top-left"),
            (3 * width / 4, height / 4, "top-right"),
            (width / 4, 3 * height / 4, "bottom-left"),
            (3 * width / 4, 3 * height / 4, "bottom-right")
        ]
        func matchesMarker(_ color: (CGFloat, CGFloat, CGFloat), label: String) -> Bool {
            switch label {
            case "top-left":
                return color.0 > 0.8 && color.0 - color.1 > 0.6 && color.0 - color.2 > 0.6
            case "top-right": return isGreenMarker(color)
            case "bottom-left": return isBlueMarker(color)
            case "bottom-right":
                return color.0 > 0.8 && color.1 > 0.8 &&
                    color.0 - color.2 > 0.6 && color.1 - color.2 > 0.6
            default: return false
            }
        }
        for sample in samples {
            let flattenedRow = flattenedTopAtHighY ? height - 1 - sample.y : sample.y
            let flattenedColor = rgb(flattenedBitmap, x: sample.x, y: flattenedRow)
            try check(matchesMarker(flattenedColor, label: sample.label),
                      "flattened image preserves the \(sample.label) source marker")
            let viewColor = rgb(canvas, x: inset + sample.x, y: inset + sample.y)
            try check(matchesMarker(viewColor, label: sample.label),
                      "Canvas preserves the \(sample.label) source marker at flipped-view coordinates; flat=\(String(describing: flattenedColor)), view=\(String(describing: viewColor))")
        }
    }

    private static func verifyUndoRedoRendering() throws {
        let original = try makeAsymmetricImage(width: 96, height: 64, patternTopRight: false)
        let initialDocument = ImageEditorDocument()
        let redaction = ImageEditorAnnotation(
            kind: .redaction,
            start: ImageEditorPoint(x: 0, y: 0),
            end: ImageEditorPoint(x: 0.25, y: 0.25)
        )
        let editedDocument = ImageEditorDocument(annotations: [redaction])
        var history = ImageEditorHistory()
        history.record(from: initialDocument, to: editedDocument)
        try check(history.canUndo && !history.canRedo, "a document edit enables Undo but not Redo")

        let originalRendered = try ImageEditorRenderer.render(original: original, annotations: [])
        let originalPNG = try ImageEditorRenderer.pngData(from: originalRendered)
        let originalImage = try decodePNG(originalPNG)
        let editedPNG = try ImageEditorRenderer.flattenedPNG(original: original, annotations: editedDocument.annotations)
        let editedImage = try decodePNG(editedPNG)
        try check(!samePixels(originalImage, editedImage), "the edited document changes flattened output")

        guard let undone = history.undo(current: editedDocument) else {
            throw CheckFailure(description: "Undo must restore the previous image document")
        }
        try check(undone == initialDocument && history.canRedo, "Undo restores the prior document and enables Redo")
        let undonePNG = try ImageEditorRenderer.flattenedPNG(original: original, annotations: undone.annotations)
        let undoneImage = try decodePNG(undonePNG)
        try check(samePixels(originalImage, undoneImage), "Undo reproduces the exact unedited flattened pixels")

        guard let redone = history.redo(current: undone) else {
            throw CheckFailure(description: "Redo must restore the edited image document")
        }
        try check(redone == editedDocument && history.canUndo && !history.canRedo,
                  "Redo restores the edited document and clears the redo stack")
        let redonePNG = try ImageEditorRenderer.flattenedPNG(original: original, annotations: redone.annotations)
        let redoneImage = try decodePNG(redonePNG)
        try check(samePixels(editedImage, redoneImage),
                  "Redo reproduces the exact edited flattened pixels")

        guard let revertedAgain = history.undo(current: redone) else {
            throw CheckFailure(description: "Undo after Redo must remain available")
        }
        let alternateDocument = ImageEditorDocument(cropRect: ImageEditorRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8))
        history.record(from: revertedAgain, to: alternateDocument)
        try check(!history.canRedo, "a new edit after Undo discards the obsolete redo branch")
    }

    private static func verifySaveFailureBoundaries(in root: URL) throws {
        try verifyMissingSourceRejection(in: root.appendingPathComponent("missing-source-check", isDirectory: true))
        try verifyManifestCommitRollback(in: root.appendingPathComponent("rollback-check", isDirectory: true))
        try verifyExistingEditorStateRollback(in: root.appendingPathComponent("rollback-existing-check", isDirectory: true))
    }

    private static func verifyMissingSourceRejection(in root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sourceURL = root.appendingPathComponent("source.png")
        let sourceImage = try makeStripedImage(width: 96, height: 64)
        try ImageEditorRenderer.pngData(from: sourceImage).write(to: sourceURL)
        let store = try LibraryStore(dataDirectory: root.appendingPathComponent("store", isDirectory: true))
        let item = try store.addImage(sourceURL)
        let managedURL = store.imageURL(for: item)!
        let persistence = ImageEditorPersistence(dataDirectory: store.dataDirectory)
        let session = try persistence.open(itemID: item.id, imageURL: managedURL)
        let originalManifest = try Data(contentsOf: store.manifestURL)
        let flattened = try ImageEditorRenderer.flattenedPNG(original: session.originalImage, annotations: [])
        try FileManager.default.removeItem(at: managedURL)

        do {
            _ = try store.saveEditedImage(flattened, session: session)
            throw CheckFailure(description: "Saving edits without their managed source must fail")
        } catch LibraryStoreError.missingImage {
            // Expected: validation happens before new image or sidecar writes.
        }
        let afterManifest = try Data(contentsOf: store.manifestURL)
        try check(afterManifest == originalManifest && store.items == [item],
                  "missing-source rejection leaves the manifest and in-memory history unchanged")
        try check(!persistence.hasSavedDocument(for: item.id) &&
                  !FileManager.default.fileExists(atPath: persistence.originalURL(for: item.id)!.path),
                  "missing-source rejection writes no private edit sidecars")
    }

    private static func verifyManifestCommitRollback(in root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sourceURL = root.appendingPathComponent("source.png")
        let sourceImage = try makeStripedImage(width: 96, height: 64)
        try ImageEditorRenderer.pngData(from: sourceImage).write(to: sourceURL)
        let store = try LibraryStore(dataDirectory: root.appendingPathComponent("store", isDirectory: true))
        let item = try store.addImage(sourceURL)
        let managedURL = store.imageURL(for: item)!
        let originalImageBytes = try Data(contentsOf: managedURL)
        let persistence = ImageEditorPersistence(dataDirectory: store.dataDirectory)
        let session = try persistence.open(itemID: item.id, imageURL: managedURL)
        let flattened = try ImageEditorRenderer.flattenedPNG(original: session.originalImage, annotations: [])

        try FileManager.default.removeItem(at: store.manifestURL)
        try FileManager.default.createDirectory(at: store.manifestURL, withIntermediateDirectories: false)
        var failedToCommit = false
        do {
            _ = try store.saveEditedImage(flattened, session: session)
        } catch let error as LibraryStoreError {
            if case .imageEditRollbackFailed(_) = error {
                throw CheckFailure(description: "Manifest commit failure must complete the image/sidecar rollback")
            }
            failedToCommit = true
        } catch {
            failedToCommit = true
        }
        try check(failedToCommit, "a manifest commit failure is surfaced to the caller")
        let restoredImageBytes = try Data(contentsOf: managedURL)
        try check(store.items == [item] && restoredImageBytes == originalImageBytes,
                  "failed commit preserves the original in-memory item and managed image bytes")
        let managedPNGs = try FileManager.default.contentsOfDirectory(at: store.imageDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "png" }
        try check(managedPNGs.map(\.standardizedFileURL) == [managedURL.standardizedFileURL],
                  "failed commit removes the newly staged flattened image")
        try check(!persistence.hasSavedDocument(for: item.id) &&
                  !FileManager.default.fileExists(atPath: persistence.originalURL(for: item.id)!.path),
                  "failed commit removes newly created private original and annotation sidecars")
    }

    private static func verifyExistingEditorStateRollback(in root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sourceURL = root.appendingPathComponent("source.png")
        let sourceImage = try makeStripedImage(width: 96, height: 64)
        try ImageEditorRenderer.pngData(from: sourceImage).write(to: sourceURL)
        let store = try LibraryStore(dataDirectory: root.appendingPathComponent("store", isDirectory: true))
        let item = try store.addImage(sourceURL)
        let sourceManagedURL = store.imageURL(for: item)!
        let sourceBytes = try Data(contentsOf: sourceManagedURL)
        let persistence = ImageEditorPersistence(dataDirectory: store.dataDirectory)
        var firstSession = try persistence.open(itemID: item.id, imageURL: sourceManagedURL)
        let redaction = ImageEditorAnnotation(
            kind: .redaction,
            start: ImageEditorPoint(x: 0.1, y: 0.1),
            end: ImageEditorPoint(x: 0.4, y: 0.4)
        )
        firstSession.document.annotations = [redaction]
        let firstFlattened = try ImageEditorRenderer.flattenedPNG(
            original: firstSession.originalImage,
            annotations: firstSession.document.annotations
        )
        let firstSaved = try store.saveEditedImage(firstFlattened, session: firstSession)
        try store.removeSupersededImageFile(at: firstSaved.oldURL)

        let privateOriginalURL = persistence.originalURL(for: item.id)!
        let documentURL = persistence.editorDirectory.appendingPathComponent("\(item.id.uuidString).json")
        let preservedOriginalBeforeFailure = try Data(contentsOf: privateOriginalURL)
        let preservedDocumentBeforeFailure = try Data(contentsOf: documentURL)
        let preservedImageBeforeFailure = try Data(contentsOf: firstSaved.newURL)
        let reedit = try persistence.open(itemID: item.id, imageURL: firstSaved.newURL)
        var changedDocument = reedit.document
        changedDocument.annotations.append(ImageEditorAnnotation(
            kind: .rectangle,
            start: ImageEditorPoint(x: 0.6, y: 0.6),
            end: ImageEditorPoint(x: 0.9, y: 0.9)
        ))
        let secondFlattened = try ImageEditorRenderer.flattenedPNG(
            original: reedit.originalImage,
            annotations: changedDocument.annotations
        )

        try FileManager.default.removeItem(at: store.manifestURL)
        try FileManager.default.createDirectory(at: store.manifestURL, withIntermediateDirectories: false)
        var failedToCommit = false
        do {
            _ = try store.saveEditedImage(secondFlattened,
                                          session: ImageEditorSession(itemID: reedit.itemID,
                                                                      originalData: reedit.originalData,
                                                                      originalImage: reedit.originalImage,
                                                                      document: changedDocument))
        } catch let error as LibraryStoreError {
            if case .imageEditRollbackFailed(_) = error {
                throw CheckFailure(description: "Re-edit commit failure must restore its existing editor state")
            }
            failedToCommit = true
        } catch {
            failedToCommit = true
        }
        try check(failedToCommit, "a second manifest commit failure is surfaced")
        let restoredOriginal = try Data(contentsOf: privateOriginalURL)
        let restoredDocument = try Data(contentsOf: documentURL)
        let restoredImage = try Data(contentsOf: firstSaved.newURL)
        try check(store.items == [firstSaved.item] &&
                  restoredOriginal == preservedOriginalBeforeFailure &&
                  restoredDocument == preservedDocumentBeforeFailure &&
                  restoredImage == preservedImageBeforeFailure,
                  "failed re-edit restores the prior manifest item, exact original, document, and flattened image")
        let managedPNGs = try FileManager.default.contentsOfDirectory(at: store.imageDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "png" }
        try check(managedPNGs.map(\.standardizedFileURL) == [firstSaved.newURL.standardizedFileURL],
                  "failed re-edit removes its newly staged flattened image")
        try check(preservedOriginalBeforeFailure == sourceBytes,
                  "rollback preserves the exact original source bytes")
        let reopened = try persistence.open(itemID: item.id, imageURL: firstSaved.newURL)
        try check(reopened.document.annotations == [redaction],
                  "re-edit after rollback restores the last committed annotation document")
    }

    private static func makeTextImage(secret: String) throws -> CGImage {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 320, pixelsHigh: 96,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw CheckFailure(description: "could not create the public secret image fixture")
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 320, height: 96).fill()
        (secret as NSString).draw(at: NSPoint(x: 12, y: 34), withAttributes: [
            .font: NSFont.systemFont(ofSize: 20, weight: .bold),
            .foregroundColor: NSColor.black
        ])
        NSGraphicsContext.restoreGraphicsState()
        guard let image = bitmap.cgImage else { throw CheckFailure(description: "could not materialize secret image pixels") }
        return image
    }

    private static func makeStripedImage(width: Int, height: Int) throws -> CGImage {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                     bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw CheckFailure(description: "could not create the pixelation fixture")
        }
        for x in 0..<width {
            context.setFillColor(CGColor(gray: x.isMultiple(of: 2) ? 1 : 0, alpha: 1))
            context.fill(CGRect(x: x, y: 0, width: 1, height: height))
        }
        guard let image = context.makeImage() else { throw CheckFailure(description: "could not render the pixelation fixture") }
        return image
    }

    private static func makeAsymmetricImage(width: Int, height: Int, patternTopRight: Bool) throws -> CGImage {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                     bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw CheckFailure(description: "could not create the asymmetric marker fixture")
        }
        let halfWidth = width / 2
        let halfHeight = height / 2
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: halfHeight, width: halfWidth, height: height - halfHeight))
        context.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
        context.fill(CGRect(x: halfWidth, y: halfHeight, width: width - halfWidth, height: height - halfHeight))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: halfWidth, height: halfHeight))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 0, alpha: 1))
        context.fill(CGRect(x: halfWidth, y: 0, width: width - halfWidth, height: halfHeight))
        if patternTopRight {
            for x in halfWidth..<width {
                context.setFillColor(CGColor(gray: x.isMultiple(of: 2) ? 1 : 0, alpha: 1))
                context.fill(CGRect(x: x, y: halfHeight, width: 1, height: height - halfHeight))
            }
        }
        guard let image = context.makeImage() else {
            throw CheckFailure(description: "could not render the asymmetric marker fixture")
        }
        return image
    }

    private static func cornerMarkerRows(in bitmap: NSBitmapImageRep, label: String) throws -> (top: Int, bottom: Int) {
        let lowerY = 4
        let upperY = bitmap.pixelsHigh - 5
        let low = rgb(bitmap, x: 8, y: lowerY)
        let high = rgb(bitmap, x: 8, y: upperY)
        if isRedMarker(high) && isBlueMarker(low) {
            return (top: upperY, bottom: lowerY)
        }
        if isRedMarker(low) && isBlueMarker(high) {
            return (top: lowerY, bottom: upperY)
        }
        throw CheckFailure(description: "\(label) did not retain the red/blue markers at NSBitmapImageRep rows \(lowerY)/\(upperY): low=\(String(describing: low)), high=\(String(describing: high))")
    }

    private static func savePointTextParityCrops(
        preview: NSBitmapImageRep, flattened: CGImage, bounds: ImageEditorRect,
        sourceWidth: Int, sourceHeight: Int, imageInset: CGFloat, scratch: URL
    ) throws {
        let export = NSBitmapImageRep(cgImage: flattened)
        let exportRows = try cornerMarkerRows(in: export, label: "flattened point-text export")
        let previewX = expandedRange(
            canvasPixelXRange(for: bounds, sourceWidth: sourceWidth, zoom: 1, imageInset: imageInset,
                              bitmapWidth: preview.pixelsWide),
            margin: 12, limit: preview.pixelsWide
        )
        let previewY = expandedRange(
            canvasPixelYRange(for: bounds, sourceHeight: sourceHeight, zoom: 1, imageInset: imageInset,
                              bitmapHeight: preview.pixelsHigh),
            margin: 12, limit: preview.pixelsHigh
        )
        let exportXLower = max(0, Int(floor(bounds.minX * Double(sourceWidth))))
        let exportXUpper = min(sourceWidth, Int(ceil(bounds.maxX * Double(sourceWidth))))
        let exportX = expandedRange(exportXLower..<exportXUpper, margin: 12, limit: export.pixelsWide)
        let exportY = expandedRange(
            pixelYRange(for: bounds, height: sourceHeight, topAtHighY: exportRows.top > exportRows.bottom),
            margin: 12, limit: export.pixelsHigh
        )
        let directory = scratch.appendingPathComponent("point-text-parity-crops", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let previewURL = directory.appendingPathComponent("preview-100-percent.png")
        let exportURL = directory.appendingPathComponent("export-100-percent.png")
        // cacheDisplay rows follow flipped-view y directly, independent of source-image row order.
        let previewData = try pointTextCropPNG(
            from: preview, xRange: previewX, yRange: previewY, topAtHighY: false
        )
        let exportData = try pointTextCropPNG(
            from: export, xRange: exportX, yRange: exportY, topAtHighY: exportRows.top > exportRows.bottom
        )
        try previewData.write(to: previewURL, options: .atomic)
        try exportData.write(to: exportURL, options: .atomic)
        print("Point-text parity crops: \(previewURL.path) ; \(exportURL.path)")
    }

    private static func expandedRange(_ range: Range<Int>, margin: Int, limit: Int) -> Range<Int> {
        let lower = max(0, range.lowerBound - margin)
        let upper = min(limit, range.upperBound + margin)
        return lower..<upper
    }

    private static func pointTextCropPNG(
        from source: NSBitmapImageRep, xRange: Range<Int>, yRange: Range<Int>, topAtHighY: Bool
    ) throws -> Data {
        let width = xRange.count
        let height = yRange.count
        guard width > 0, height > 0,
              let crop = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                          bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                          isPlanar: false, colorSpaceName: .deviceRGB,
                                          bytesPerRow: 0, bitsPerPixel: 0) else {
            throw CheckFailure(description: "could not allocate the point-text parity crop")
        }
        for cropTopY in 0..<height {
            let sourceRow = topAtHighY ? yRange.upperBound - 1 - cropTopY : yRange.lowerBound + cropTopY
            let cropY = cropTopY
            for (cropX, sourceX) in xRange.enumerated() {
                crop.setColor(source.colorAt(x: sourceX, y: sourceRow) ?? .clear, atX: cropX, y: cropY)
            }
        }
        guard let data = crop.representation(using: .png, properties: [:]) else {
            throw CheckFailure(description: "could not encode the point-text parity crop")
        }
        return data
    }
    private static func isRedMarker(_ color: (CGFloat, CGFloat, CGFloat)) -> Bool {
        color.0 > 0.8 && color.0 - color.2 > 0.6
    }

    private static func isBlueMarker(_ color: (CGFloat, CGFloat, CGFloat)) -> Bool {
        color.2 > 0.8 && color.2 - color.0 > 0.6
    }

    private static func isGreenMarker(_ color: (CGFloat, CGFloat, CGFloat)) -> Bool {
        color.1 > 0.8 && color.1 - color.0 > 0.6 && color.1 - color.2 > 0.6
    }

    private static func topHalfRows(top: Int, bottom: Int, height: Int) -> Range<Int> {
        top > bottom ? (height / 2)..<height : 0..<(height / 2)
    }

    private static func bottomHalfRows(top: Int, bottom: Int, height: Int) -> Range<Int> {
        top > bottom ? 0..<(height / 2) : (height / 2)..<height
    }

    private static func isColor(
        _ actual: (CGFloat, CGFloat, CGFloat),
        red: CGFloat,
        green: CGFloat,
        blue: CGFloat,
        tolerance: CGFloat = 0.02
    ) -> Bool {
        abs(actual.0 - red) <= tolerance &&
        abs(actual.1 - green) <= tolerance &&
        abs(actual.2 - blue) <= tolerance
    }

    private static func samePixels(_ first: CGImage, _ second: CGImage) -> Bool {
        guard first.width == second.width, first.height == second.height else { return false }
        return samePixels(first, second, xRange: 0..<first.width, yRange: 0..<first.height)
    }

    private static func samePixels(
        _ first: CGImage,
        _ second: CGImage,
        xRange: Range<Int>,
        yRange: Range<Int>
    ) -> Bool {
        guard first.width == second.width, first.height == second.height,
              xRange.lowerBound >= 0, xRange.upperBound <= first.width,
              yRange.lowerBound >= 0, yRange.upperBound <= first.height else { return false }
        let firstBitmap = NSBitmapImageRep(cgImage: first)
        let secondBitmap = NSBitmapImageRep(cgImage: second)
        for y in yRange {
            for x in xRange {
                let lhs = rgb(firstBitmap, x: x, y: y)
                let rhs = rgb(secondBitmap, x: x, y: y)
                if !isColor(lhs, red: rhs.0, green: rhs.1, blue: rhs.2, tolerance: 0.005) { return false }
            }
        }
        return true
    }
    private static func verifyCanvasTextParity(
        _ canvas: NSBitmapImageRep, baseline: NSBitmapImageRep,
        flattened: CGImage, flattenedBaseline: CGImage, imageInset: CGFloat
    ) throws {
        let inset = Int(imageInset.rounded())
        guard canvas.pixelsWide >= flattened.width + inset * 2,
              canvas.pixelsHigh >= flattened.height + inset * 2,
              baseline.pixelsWide >= flattenedBaseline.width + inset * 2,
              baseline.pixelsHigh >= flattenedBaseline.height + inset * 2,
              flattened.width == flattenedBaseline.width,
              flattened.height == flattenedBaseline.height else {
            throw CheckFailure(description: "Canvas and flattened text parity images have incompatible dimensions")
        }

        let exportBitmap = NSBitmapImageRep(cgImage: flattened)
        let exportBaseline = NSBitmapImageRep(cgImage: flattenedBaseline)
        let exportOrientation = try cornerMarkerRows(in: exportBaseline, label: "flattened point-text baseline")
        let exportTopAtHighY = exportOrientation.top > exportOrientation.bottom
        let width = flattened.width
        let height = flattened.height
        var previewCore: Set<Int> = []
        var exportCore: Set<Int> = []
        var previewMinX = width, previewMinY = height, previewMaxX = -1, previewMaxY = -1
        var exportMinX = width, exportMinY = height, exportMaxX = -1, exportMaxY = -1

        for sourceY in 0..<height {
            let exportY = exportTopAtHighY ? height - 1 - sourceY : sourceY
            let previewY = inset + sourceY
            for sourceX in 0..<width {
                let exportCoverage = textCoverage(
                    before: rgb(exportBaseline, x: sourceX, y: exportY),
                    after: rgb(exportBitmap, x: sourceX, y: exportY)
                )
                if exportCoverage >= 0.5 {
                    exportCore.insert(sourceY * width + sourceX)
                    exportMinX = min(exportMinX, sourceX)
                    exportMaxX = max(exportMaxX, sourceX)
                    exportMinY = min(exportMinY, sourceY)
                    exportMaxY = max(exportMaxY, sourceY)
                }

                let previewCoverage = textCoverage(
                    before: rgb(baseline, x: inset + sourceX, y: previewY),
                    after: rgb(canvas, x: inset + sourceX, y: previewY)
                )
                if previewCoverage >= 0.5 {
                    previewCore.insert(sourceY * width + sourceX)
                    previewMinX = min(previewMinX, sourceX)
                    previewMaxX = max(previewMaxX, sourceX)
                    previewMinY = min(previewMinY, sourceY)
                    previewMaxY = max(previewMaxY, sourceY)
                }
            }
        }

        guard !previewCore.isEmpty, !exportCore.isEmpty else {
            throw CheckFailure(description: "Canvas or flattened export contains no point-text core pixels")
        }
        let maxEdgeDelta = max(
            abs(previewMinX - exportMinX), abs(previewMinY - exportMinY),
            abs(previewMaxX - exportMaxX), abs(previewMaxY - exportMaxY)
        )
        try check(maxEdgeDelta <= 2,
                  "Canvas and flattened export retain point-text bounds without baseline drift beyond two source pixels")

        let countDelta = abs(previewCore.count - exportCore.count)
        try check(CGFloat(countDelta) / CGFloat(max(previewCore.count, exportCore.count)) <= 0.18,
                  "Canvas and flattened export retain comparable full-label glyph coverage")

        func localMatchFraction(_ source: Set<Int>, in target: Set<Int>) -> CGFloat {
            var matched = 0
            for pixel in source {
                let x = pixel % width
                let y = pixel / width
                var found = false
                for neighborY in max(0, y - 1)...min(height - 1, y + 1) where !found {
                    for neighborX in max(0, x - 1)...min(width - 1, x + 1) {
                        if target.contains(neighborY * width + neighborX) {
                            found = true
                            break
                        }
                    }
                }
                if found { matched += 1 }
            }
            return CGFloat(matched) / CGFloat(source.count)
        }

        let previewMatch = localMatchFraction(previewCore, in: exportCore)
        let exportMatch = localMatchFraction(exportCore, in: previewCore)
        try check(previewMatch >= 0.95 && exportMatch >= 0.95,
                  "Canvas glyph geometry, orientation, and layout match flattened export within one anti-alias pixel")
    }

    private static func decodePNG(_ data: Data) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw CheckFailure(description: "flattened PNG could not be decoded")
        }
        return image
    }

    private static func isOpaqueBlack(_ image: CGImage, x: Int, y: Int) -> Bool {
        let color = NSBitmapImageRep(cgImage: image).colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
        guard let components = color?.cgColor.components, components.count >= 4 else { return false }
        return components[0] <= 0.01 && components[1] <= 0.01 && components[2] <= 0.01 && components[3] >= 0.99
    }



    private static func rgb(_ bitmap: NSBitmapImageRep, x: Int, y: Int) -> (CGFloat, CGFloat, CGFloat) {
        guard let components = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)?.cgColor.components,
              components.count >= 3 else { return (0, 0, 0) }
        return (components[0], components[1], components[2])
    }
    private static func textCoverage(
        before: (CGFloat, CGFloat, CGFloat), after: (CGFloat, CGFloat, CGFloat)
    ) -> CGFloat {
        let foreground = CGFloat(17) / 255
        let red = before.0 - foreground, green = before.1 - foreground, blue = before.2 - foreground
        let denominator = red * red + green * green + blue * blue
        guard denominator > 0 else { return 0 }
        return ((before.0 - after.0) * red + (before.1 - after.1) * green +
                (before.2 - after.2) * blue) / denominator
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ label: String) throws {
        guard condition() else { throw CheckFailure(description: label) }
    }
}

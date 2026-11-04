import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers


public enum ImageEditorTool: String, CaseIterable, Codable {
    case select
    case crop
    case arrow
    case line
    case rectangle
    case ellipse
    case text
    case highlight
    case redaction
    case pixelation
}

public struct ImageEditorPoint: Codable, Equatable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public enum ImageEditorAnnotationKind: String, Codable, CaseIterable {
    case arrow
    case line
    case rectangle
    case ellipse
    case text
    case highlight
    case redaction
    case pixelation
}

public struct ImageEditorRect: Equatable, Codable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public var minX: Double { x }
    public var minY: Double { y }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// Annotation coordinates are normalized to the original image, with (0, 0) at its top-left.
public struct ImageEditorAnnotation: Codable, Identifiable, Equatable {
    public var id: UUID
    public var kind: ImageEditorAnnotationKind
    public var start: ImageEditorPoint
    public var end: ImageEditorPoint
    public var points: [ImageEditorPoint]
    public var text: String
    public var colorHex: String
    public var lineWidth: Double
    public var fontSize: Double

    public init(
        id: UUID = UUID(),
        kind: ImageEditorAnnotationKind,
        start: ImageEditorPoint,
        end: ImageEditorPoint,
        points: [ImageEditorPoint] = [],
        text: String = "",
        colorHex: String = "#E53935",
        lineWidth: Double = 0.004,
        fontSize: Double = 0.04
    ) {
        self.id = id
        self.kind = kind
        self.start = start
        self.end = end
        self.points = points
        self.text = text
        self.colorHex = colorHex
        self.lineWidth = lineWidth
        self.fontSize = fontSize
    }

    public var bounds: ImageEditorRect {
        if kind == .highlight, let first = points.first {
            let minX = points.reduce(first.x) { min($0, $1.x) }
            let maxX = points.reduce(first.x) { max($0, $1.x) }
            let minY = points.reduce(first.y) { min($0, $1.y) }
            let maxY = points.reduce(first.y) { max($0, $1.y) }
            return ImageEditorRect(x: minX, y: minY, width: max(0.001, maxX - minX), height: max(0.001, maxY - minY))
        }
        let minX = min(start.x, end.x)
        let minY = min(start.y, end.y)
        let maxX = max(start.x, end.x)
        let maxY = max(start.y, end.y)
        let minimum = kind == .text ? 0.025 : 0.004
        return ImageEditorRect(x: minX, y: minY, width: max(minimum, maxX - minX), height: max(minimum, maxY - minY))
    }

    fileprivate var isRasterEffect: Bool { kind == .redaction || kind == .pixelation }
}

public struct ImageEditorDocument: Codable, Equatable {
    public var annotations: [ImageEditorAnnotation]
    public var cropRect: ImageEditorRect?

    public init(annotations: [ImageEditorAnnotation] = [], cropRect: ImageEditorRect? = nil) {
        self.annotations = annotations
        self.cropRect = cropRect
    }
}

public enum ImageEditorError: LocalizedError {
    case unreadableImage
    case imageTooLarge
    case invalidDocument
    case missingOriginal
    case missingItem
    case unsupportedImage
    case encodingFailed
    case rollbackFailed
    case pasteboardFailed

    public var errorDescription: String? {
        switch self {
        case .unreadableImage: return BiscuitLocalization.string("This image could not be opened for editing.")
        case .imageTooLarge: return BiscuitLocalization.string("This image is too large to edit safely.")
        case .invalidDocument: return BiscuitLocalization.string("The saved image-editing document is invalid. Its files were left untouched.")
        case .missingOriginal: return BiscuitLocalization.string("The private original for this edited image is missing. The current image was not changed.")
        case .missingItem: return BiscuitLocalization.string("This image is no longer in the library.")
        case .unsupportedImage: return BiscuitLocalization.string("This image format could not be decoded.")
        case .encodingFailed: return BiscuitLocalization.string("The flattened image could not be encoded.")
        case .rollbackFailed: return BiscuitLocalization.string("Image-edit metadata could not be restored after a failed save.")
        case .pasteboardFailed: return BiscuitLocalization.string("The edited image could not be copied to the clipboard.")
        }
    }
}

public struct ImageEditorSession {
    public let itemID: UUID
    public let originalData: Data
    public let originalImage: CGImage
    public var document: ImageEditorDocument

    public init(itemID: UUID, originalData: Data, originalImage: CGImage, document: ImageEditorDocument) {
        self.itemID = itemID
        self.originalData = originalData
        self.originalImage = originalImage
        self.document = document
    }
}

struct ImageEditorHistory {
    private(set) var undoStack: [ImageEditorDocument] = []
    private(set) var redoStack: [ImageEditorDocument] = []

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    mutating func record(from current: ImageEditorDocument, to next: ImageEditorDocument) {
        guard current != next else { return }
        undoStack.append(current)
        if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack.removeAll(keepingCapacity: true)
    }

    mutating func undo(current: ImageEditorDocument) -> ImageEditorDocument? {
        guard let previous = undoStack.popLast() else { return nil }
        redoStack.append(current)
        return previous
    }

    mutating func redo(current: ImageEditorDocument) -> ImageEditorDocument? {
        guard let next = redoStack.popLast() else { return nil }
        undoStack.append(current)
        return next
    }
}

public struct ImageEditorPersistenceSnapshot {
    fileprivate let hadOriginal: Bool
    fileprivate let documentData: Data?
}

/// Private editable state lives outside the Library export tree.
public struct ImageEditorPersistence {
    public let dataDirectory: URL
    public let editorDirectory: URL
    public let originalsDirectory: URL

    public init(dataDirectory: URL) {
        self.dataDirectory = dataDirectory
        self.editorDirectory = dataDirectory.appendingPathComponent("image-editor", isDirectory: true)
        self.originalsDirectory = editorDirectory.appendingPathComponent("originals", isDirectory: true)
    }

    public func open(itemID: UUID, imageURL: URL) throws -> ImageEditorSession {
        let documentURL = documentURL(for: itemID)
        if FileManager.default.fileExists(atPath: documentURL.path) {
            guard let originalURL = originalURL(for: itemID),
                  FileManager.default.fileExists(atPath: originalURL.path) else { throw ImageEditorError.missingOriginal }
            do {
                let originalData = try Data(contentsOf: originalURL)
                let document = try JSONDecoder().decode(ImageEditorDocument.self, from: Data(contentsOf: documentURL))
                guard Self.valid(document) else { throw ImageEditorError.invalidDocument }
                return ImageEditorSession(itemID: itemID, originalData: originalData,
                                          originalImage: try Self.decode(originalData), document: document)
            } catch let error as ImageEditorError {
                throw error
            } catch {
                throw ImageEditorError.invalidDocument
            }
        }
        do {
            let originalData = try Data(contentsOf: imageURL)
            return ImageEditorSession(itemID: itemID, originalData: originalData,
                                      originalImage: try Self.decode(originalData), document: ImageEditorDocument())
        } catch let error as ImageEditorError {
            throw error
        } catch {
            throw ImageEditorError.unreadableImage
        }
    }

    public func saveOriginalAndDocument(_ session: ImageEditorSession) throws {
        try ensureDirectories()
        guard Self.valid(session.document) else { throw ImageEditorError.invalidDocument }
        let originalURL = originalsDirectory.appendingPathComponent("\(session.itemID.uuidString).source", isDirectory: false)
        let documentURL = documentURL(for: session.itemID)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(session.document)
        if !FileManager.default.fileExists(atPath: originalURL.path) {
            try session.originalData.write(to: originalURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: originalURL.path)
        }
        try encoded.write(to: documentURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: documentURL.path)
    }
    public func snapshot(itemID: UUID) throws -> ImageEditorPersistenceSnapshot {
        let originalURL = originalURL(for: itemID)!
        let documentURL = documentURL(for: itemID)
        let hadOriginal = FileManager.default.fileExists(atPath: originalURL.path)
        let document = FileManager.default.fileExists(atPath: documentURL.path) ? try Data(contentsOf: documentURL) : nil
        return ImageEditorPersistenceSnapshot(hadOriginal: hadOriginal, documentData: document)
    }

    public func restore(_ snapshot: ImageEditorPersistenceSnapshot, itemID: UUID) throws {
        let originalURL = originalURL(for: itemID)!
        if !snapshot.hadOriginal, FileManager.default.fileExists(atPath: originalURL.path) {
            try FileManager.default.removeItem(at: originalURL)
        }
        try restoreFile(snapshot.documentData, to: documentURL(for: itemID))
    }

    private func restoreFile(_ data: Data?, to url: URL) throws {
        if let data {
            try ensureDirectories()
            try data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } else if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    public func remove(itemIDs: [UUID]) throws {
        for id in itemIDs {
            for url in [documentURL(for: id), originalURL(for: id)].compactMap({ $0 }) {
                do {
                    try FileManager.default.removeItem(at: url)
                } catch {
                    if FileManager.default.fileExists(atPath: url.path) { throw error }
                }
            }
        }
    }

    public func hasSavedDocument(for itemID: UUID) -> Bool {
        FileManager.default.fileExists(atPath: documentURL(for: itemID).path)
    }

    public func originalURL(for itemID: UUID) -> URL? {
        originalsDirectory.appendingPathComponent("\(itemID.uuidString).source", isDirectory: false)
    }

    private func documentURL(for itemID: UUID) -> URL {
        editorDirectory.appendingPathComponent("\(itemID.uuidString).json", isDirectory: false)
    }

    private func ensureDirectories() throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: editorDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fileManager.createDirectory(at: originalsDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: editorDirectory.path)
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: originalsDirectory.path)
    }

    private static func decode(_ data: Data) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue else {
            throw ImageEditorError.unsupportedImage
        }
        guard width > 0, height > 0 else { throw ImageEditorError.unsupportedImage }
        guard width <= 80_000_000 / height else { throw ImageEditorError.imageTooLarge }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: true] as CFDictionary) else {
            throw ImageEditorError.unsupportedImage
        }
        guard image.width > 0, image.height > 0,
              image.width <= 80_000_000 / image.height else { throw ImageEditorError.imageTooLarge }
        return image
    }

    private static func valid(_ document: ImageEditorDocument) -> Bool {
        if let crop = document.cropRect {
            let values = [crop.x, crop.y, crop.width, crop.height]
            guard values.allSatisfy(\.isFinite), crop.x >= 0, crop.y >= 0,
                  crop.width > 0, crop.height > 0, crop.maxX <= 1, crop.maxY <= 1 else { return false }
        }
        var ids = Set<UUID>()
        for annotation in document.annotations {
            guard ids.insert(annotation.id).inserted,
                  annotation.text.utf8.count <= 16_384,
                  annotation.points.count <= 100_000,
                  annotation.lineWidth.isFinite, annotation.lineWidth > 0, annotation.lineWidth <= 0.25,
                  annotation.fontSize.isFinite, annotation.fontSize > 0, annotation.fontSize <= 0.25,
                  annotation.colorHex.count == 7, annotation.colorHex.first == "#",
                  annotation.colorHex.dropFirst().allSatisfy({ $0.isHexDigit }) else { return false }
            let values = [annotation.start.x, annotation.start.y, annotation.end.x, annotation.end.y] + annotation.points.flatMap { [$0.x, $0.y] }
            guard values.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }) else { return false }
        }
        return true
    }
}

public enum ImageEditorRenderer {
    private static let maximumPixels = 80_000_000
    private static let pixelationBlockSize = 12
    fileprivate struct TextLayout {
        let bounds: ImageEditorRect
        let attributedText: NSAttributedString
        let insets: NSSize
    }

    static func resolvedBounds(for annotation: ImageEditorAnnotation, in sourceSize: NSSize) -> ImageEditorRect {
        guard annotation.kind == .text, annotation.start == annotation.end else { return annotation.bounds }
        return pointTextLayout(for: annotation, sourceSize: sourceSize)?.bounds ?? annotation.bounds
    }

    fileprivate static func pointTextLayout(for annotation: ImageEditorAnnotation, sourceSize: NSSize) -> TextLayout? {
        guard annotation.kind == .text, annotation.start == annotation.end,
              sourceSize.width.isFinite, sourceSize.height.isFinite,
              sourceSize.width > 0, sourceSize.height > 0 else { return nil }
        return pointTextLayout(for: annotation, sourceSize: sourceSize, color: color(for: annotation.colorHex))
    }

    private static func pointTextLayout(for annotation: ImageEditorAnnotation, sourceSize: NSSize, color: NSColor) -> TextLayout? {
        let insets = NSSize(width: min(3, sourceSize.width / 2),
                            height: min(2, sourceSize.height / 2))
        let contentWidth = max(1, sourceSize.width - insets.width * 2)
        let attributed = attributedText(
            for: annotation,
            fontSize: fontSize(for: annotation, sourceSize: sourceSize),
            color: color
        )
        let measured = attributed.boundingRect(
            with: NSSize(width: contentWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )
        let width = min(sourceSize.width, ceil(max(1, measured.width)) + insets.width * 2)
        let height = min(sourceSize.height, ceil(max(1, measured.height)) + insets.height * 2)
        let normalizedWidth = Double(width / sourceSize.width)
        let normalizedHeight = Double(height / sourceSize.height)
        let x = min(max(0, annotation.start.x), max(0, 1 - normalizedWidth))
        let y = min(max(0, annotation.start.y), max(0, 1 - normalizedHeight))
        let bounds = ImageEditorRect(x: x, y: y, width: normalizedWidth, height: normalizedHeight)
        return TextLayout(bounds: bounds, attributedText: attributed, insets: insets)
    }
    fileprivate static func textLayout(for annotation: ImageEditorAnnotation, sourceSize: NSSize) -> TextLayout? {
        guard annotation.kind == .text,
              sourceSize.width.isFinite, sourceSize.height.isFinite,
              sourceSize.width > 0, sourceSize.height > 0 else { return nil }
        let color = color(for: annotation.colorHex)
        if annotation.start == annotation.end {
            return pointTextLayout(for: annotation, sourceSize: sourceSize, color: color)
        }
        let attributed = attributedText(
            for: annotation,
            fontSize: fontSize(for: annotation, sourceSize: sourceSize),
            color: color
        )
        return TextLayout(bounds: annotation.bounds, attributedText: attributed, insets: NSSize(width: 3, height: 2))
    }
    fileprivate static func relocatingTextLayout(_ layout: TextLayout, to bounds: ImageEditorRect) -> TextLayout {
        TextLayout(bounds: bounds, attributedText: layout.attributedText, insets: layout.insets)
    }

    private static func fontSize(for annotation: ImageEditorAnnotation, sourceSize: NSSize) -> CGFloat {
        max(10, CGFloat(annotation.fontSize) * min(sourceSize.width, sourceSize.height))
    }

    private static func attributedText(for annotation: ImageEditorAnnotation, fontSize: CGFloat, color: NSColor) -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        return NSAttributedString(string: annotation.text, attributes: [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ])
    }


    public static func render(
        original: CGImage,
        annotations: [ImageEditorAnnotation],
        cropRect: ImageEditorRect? = nil
    ) throws -> CGImage {
        let bitmap = try renderedEffects(original: original, annotations: annotations)
        drawVectorAnnotations(annotations, on: bitmap, width: original.width, height: original.height)
        guard let renderedImage = bitmap.cgImage else { throw ImageEditorError.encodingFailed }
        return try cropFlattenedImage(original: renderedImage, to: cropRect)
    }

    public static func renderEffects(original: CGImage, annotations: [ImageEditorAnnotation]) throws -> CGImage {
        let bitmap = try renderedEffects(original: original, annotations: annotations)
        guard let result = bitmap.cgImage else { throw ImageEditorError.encodingFailed }
        return result
    }

    public static func pngData(from image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
            throw ImageEditorError.encodingFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ImageEditorError.encodingFailed }
        return data as Data
    }
    public static func flattenedPNG(
        original: CGImage,
        annotations: [ImageEditorAnnotation],
        cropRect: ImageEditorRect? = nil
    ) throws -> Data {
        try pngData(from: render(original: original, annotations: annotations, cropRect: cropRect))
    }

    @discardableResult
    public static func exportFlattened(
        original: CGImage,
        annotations: [ImageEditorAnnotation],
        cropRect: ImageEditorRect? = nil,
        to destination: URL
    ) throws -> Data {
        let data = try flattenedPNG(original: original, annotations: annotations, cropRect: cropRect)
        try data.write(to: destination, options: .atomic)
        return data
    }

    @discardableResult
    public static func copyFlattened(
        original: CGImage,
        annotations: [ImageEditorAnnotation],
        cropRect: ImageEditorRect? = nil,
        to pasteboard: NSPasteboard
    ) throws -> Data {
        let data = try flattenedPNG(original: original, annotations: annotations, cropRect: cropRect)
        pasteboard.clearContents()
        guard pasteboard.setData(data, forType: .png) else { throw ImageEditorError.pasteboardFailed }
        return data
    }
    static func cropFlattenedImage(original: CGImage, to crop: ImageEditorRect?) throws -> CGImage {
        guard let crop else { return original }
        guard crop.x.isFinite, crop.y.isFinite, crop.width.isFinite, crop.height.isFinite,
              crop.x >= 0, crop.y >= 0, crop.width > 0, crop.height > 0,
              crop.maxX <= 1, crop.maxY <= 1 else { throw ImageEditorError.invalidDocument }
        let width = max(1, Int((Double(original.width) * crop.width).rounded()))
        let height = max(1, Int((Double(original.height) * crop.height).rounded()))
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { throw ImageEditorError.encodingFailed }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        let sourceSize = NSSize(width: original.width, height: original.height)
        let sourceRect = NSRect(x: crop.x * Double(original.width),
                                y: (1 - crop.maxY) * Double(original.height),
                                width: crop.width * Double(original.width),
                                height: crop.height * Double(original.height))
        let destinationSize = NSSize(width: width, height: height)
        NSImage(cgImage: original, size: sourceSize).draw(in: NSRect(origin: .zero, size: destinationSize),
                                                         from: sourceRect, operation: .copy, fraction: 1)
        guard let result = bitmap.cgImage else { throw ImageEditorError.encodingFailed }
        return result
    }



    private static func renderedEffects(original: CGImage, annotations: [ImageEditorAnnotation]) throws -> NSBitmapImageRep {
        guard original.width > 0, original.height > 0,
              original.width <= maximumPixels / original.height else { throw ImageEditorError.imageTooLarge }
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: original.width, pixelsHigh: original.height,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { throw ImageEditorError.encodingFailed }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        let size = NSSize(width: CGFloat(original.width), height: CGFloat(original.height))
        NSImage(cgImage: original, size: size).draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        for annotation in annotations where annotation.kind == .pixelation {
            pixelate(annotation, bitmap: bitmap, width: original.width, height: original.height)
        }
        if annotations.contains(where: { $0.kind == .redaction }) {
            NSGraphicsContext.saveGraphicsState()
            guard let redactionContext = NSGraphicsContext(bitmapImageRep: bitmap) else {
                NSGraphicsContext.restoreGraphicsState()
                throw ImageEditorError.encodingFailed
            }
            NSGraphicsContext.current = redactionContext
            NSColor.black.setFill()
            for annotation in annotations where annotation.kind == .redaction {
                NSBezierPath(rect: pixelRect(annotation, width: original.width, height: original.height)).fill()
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        return bitmap
    }

    private static func pixelate(_ annotation: ImageEditorAnnotation, bitmap: NSBitmapImageRep, width: Int, height: Int) {
        let rect = annotation.bounds
        let x0 = max(0, min(width - 1, Int(floor(rect.minX * Double(width)))))
        let x1 = max(x0 + 1, min(width, Int(ceil(rect.maxX * Double(width)))))
        let topY0 = max(0, min(height - 1, Int(floor(rect.minY * Double(height)))))
        let topY1 = max(topY0 + 1, min(height, Int(ceil(rect.maxY * Double(height)))))
        for topY in stride(from: topY0, to: topY1, by: pixelationBlockSize) {
            for x in stride(from: x0, to: x1, by: pixelationBlockSize) {
                let endX = min(x1, x + pixelationBlockSize)
                let endY = min(topY1, topY + pixelationBlockSize)
                var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
                var count: CGFloat = 0
                for sampleY in stride(from: topY, to: endY, by: max(1, (endY - topY) / 4)) {
                    for sampleX in stride(from: x, to: endX, by: max(1, (endX - x) / 4)) {
                        guard let color = bitmap.colorAt(x: sampleX, y: sampleY)?.usingColorSpace(.deviceRGB),
                              let components = color.cgColor.components, components.count >= 3 else { continue }
                        red += components[0]; green += components[1]; blue += components[2]
                        alpha += components.count > 3 ? components[3] : 1
                        count += 1
                    }
                }
                guard count > 0 else { continue }
                let mosaic = NSColor(calibratedRed: red / count, green: green / count, blue: blue / count, alpha: alpha / count)
                for pixelY in topY..<endY {
                    for pixelX in x..<endX { bitmap.setColor(mosaic, atX: pixelX, y: pixelY) }
                }
            }
        }
    }

    private static func drawVectorAnnotations(_ annotations: [ImageEditorAnnotation], on bitmap: NSBitmapImageRep, width: Int, height: Int) {
        guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        let sourceSize = NSSize(width: CGFloat(width), height: CGFloat(height))
        for annotation in annotations where !annotation.isRasterEffect {
            draw(annotation,
                 in: NSRect(x: 0, y: 0, width: sourceSize.width, height: sourceSize.height),
                 flipped: false,
                 sourceSize: sourceSize)
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    fileprivate static func draw(_ annotation: ImageEditorAnnotation, in imageRect: NSRect, flipped: Bool,
                                 sourceSize: NSSize, textLayout cachedTextLayout: TextLayout? = nil,
                                 textContext: NSGraphicsContext? = nil) {
        let width = imageRect.width
        let height = imageRect.height
        let scale = min(width, height)
        let color = color(for: annotation.colorHex)
        let layout = cachedTextLayout ?? textLayout(for: annotation, sourceSize: sourceSize)
        let bounds = layout?.bounds ?? annotation.bounds
        let y = flipped ? bounds.minY : 1 - bounds.maxY
        let rect = NSRect(x: imageRect.minX + CGFloat(bounds.minX) * width,
                          y: imageRect.minY + CGFloat(y) * height,
                          width: CGFloat(bounds.width) * width,
                          height: CGFloat(bounds.height) * height)
        let strokeWidth = max(1.5, CGFloat(annotation.lineWidth) * scale)
        switch annotation.kind {
        case .arrow, .line:
            let start = point(annotation.start, in: imageRect, flipped: flipped)
            let end = point(annotation.end, in: imageRect, flipped: flipped)
            let shaft = NSBezierPath()
            shaft.move(to: start); shaft.line(to: end)
            shaft.lineWidth = strokeWidth
            shaft.lineCapStyle = .round
            color.setStroke(); shaft.stroke()
            if annotation.kind == .arrow {
                let angle = atan2(Double(end.y - start.y), Double(end.x - start.x))
                let head = max(8, annotation.lineWidth * Double(scale) * 4)
                let left = NSPoint(x: end.x - CGFloat(head * cos(angle - 0.45)), y: end.y - CGFloat(head * sin(angle - 0.45)))
                let right = NSPoint(x: end.x - CGFloat(head * cos(angle + 0.45)), y: end.y - CGFloat(head * sin(angle + 0.45)))
                let arrowHead = NSBezierPath()
                arrowHead.move(to: left); arrowHead.line(to: end); arrowHead.line(to: right)
                arrowHead.lineWidth = strokeWidth; arrowHead.lineCapStyle = .round
                arrowHead.lineJoinStyle = .round; arrowHead.stroke()
            }
        case .rectangle, .ellipse:
            let path = annotation.kind == .rectangle ? NSBezierPath(rect: rect) : NSBezierPath(ovalIn: rect)
            path.lineWidth = strokeWidth
            color.setStroke(); path.stroke()
        case .text:
            let attributed = layout?.attributedText ?? attributedText(
                for: annotation,
                fontSize: fontSize(for: annotation, sourceSize: sourceSize),
                color: color
            )
            let textInsets = layout?.insets ?? NSSize(width: 3, height: 2)
            drawText(
                attributed, in: rect, bounds: bounds, insets: textInsets,
                sourceSize: sourceSize, imageRect: imageRect, flipped: flipped, textContext: textContext
            )
        case .highlight:
            guard !annotation.points.isEmpty else { return }
            let path = NSBezierPath()
            for (index, pointValue) in annotation.points.enumerated() {
                let p = point(pointValue, in: imageRect, flipped: flipped)
                if index == 0 { path.move(to: p) } else { path.line(to: p) }
            }
            color.withAlphaComponent(0.42).setStroke()
            path.lineWidth = max(8, strokeWidth)
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.stroke()
        case .redaction, .pixelation:
            break
        }
    }

    private static func drawText(
        _ attributed: NSAttributedString, in rect: NSRect, bounds: ImageEditorRect, insets: NSSize,
        sourceSize: NSSize, imageRect: NSRect, flipped: Bool, textContext: NSGraphicsContext?
    ) {
        guard sourceSize.width > 0, sourceSize.height > 0,
              let originalContext = NSGraphicsContext.current else { return }
        let localRect = NSRect(x: 0, y: 0,
                               width: CGFloat(bounds.width) * sourceSize.width,
                               height: CGFloat(bounds.height) * sourceSize.height)
        let context = (textContext ?? originalContext).cgContext
        let scaleX = imageRect.width / sourceSize.width
        let scaleY = imageRect.height / sourceSize.height
        // Canvas passes the top-origin annotation rect; flattened rendering passes its bottom-origin equivalent.
        // Apply the destination axis change once so point-text glyphs remain upright in both paths.
        let transform = CGAffineTransform(
            a: scaleX,
            b: 0,
            c: 0,
            d: flipped ? -scaleY : scaleY,
            tx: rect.minX,
            ty: flipped ? rect.maxY : rect.minY
        )
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        context.saveGState()
        defer { context.restoreGState() }
        if let textContext { NSGraphicsContext.current = textContext }
        context.textMatrix = .identity
        context.concatenate(transform)
        attributed.draw(in: localRect.insetBy(dx: insets.width, dy: insets.height))
    }

    fileprivate static func color(for hex: String) -> NSColor {
        guard hex.count == 7, hex.first == "#", let value = UInt32(hex.dropFirst(), radix: 16) else { return .systemRed }
        return NSColor(calibratedRed: CGFloat((value >> 16) & 0xff) / 255,
                       green: CGFloat((value >> 8) & 0xff) / 255,
                       blue: CGFloat(value & 0xff) / 255, alpha: 1)
    }

    fileprivate static func point(_ value: ImageEditorPoint, in rect: NSRect, flipped: Bool) -> NSPoint {
        NSPoint(x: rect.minX + CGFloat(value.x) * rect.width,
                y: rect.minY + CGFloat(flipped ? value.y : 1 - value.y) * rect.height)
    }

    fileprivate static func pixelRect(_ annotation: ImageEditorAnnotation, width: Int, height: Int) -> NSRect {
        let bounds = annotation.bounds
        return NSRect(x: CGFloat(bounds.minX * Double(width)),
                      y: CGFloat((1 - bounds.maxY) * Double(height)),
                      width: CGFloat(bounds.width * Double(width)),
                      height: CGFloat(bounds.height * Double(height)))
    }
}


@MainActor
final class ImageEditorCanvasView: NSView {
    private(set) var original: CGImage
    private(set) var effectsImage: CGImage {
        didSet {
            effectsNSImage = NSImage(
                cgImage: effectsImage,
                size: NSSize(width: CGFloat(original.width), height: CGFloat(original.height))
            )
        }
    }
    private var effectsNSImage: NSImage
    private(set) var annotations: [ImageEditorAnnotation]
    private(set) var cropRect: ImageEditorRect?
    private(set) var cropDraft: ImageEditorRect?
    private(set) var selectedID: UUID?
    var tool: ImageEditorTool = .select { didSet { needsDisplay = true } }
    var selectedColor = "#E53935"
    var lineWidth = 0.004
    var fontSize = 0.04
    var textValue = BiscuitLocalization.string("Text")
    var zoom = 1.0 { didSet { updateZoom() } }
    var isInteractionEnabled = true
    var onDocumentChanged: (([ImageEditorAnnotation]) -> Void)?
    var onCropChanged: ((ImageEditorRect?) -> Void)?
    var onCropDraftChanged: (() -> Void)?
    private let imageInset: CGFloat = 12

    private var imageRect = NSRect.zero
    private var dragStart: NSPoint?
    private var dragCurrent: NSPoint?
    private var previewAnnotationID: UUID?
    private var dragAnnotationIndex: Int?
    private var dragMode: DragMode = .drawing
    private var originalAnnotation: ImageEditorAnnotation?
    private var freehandPoints: [ImageEditorPoint] = []
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?

    private enum DragMode { case drawing, moving, resizing }
    private struct CachedTextLayout {
        let annotation: ImageEditorAnnotation
        let layout: ImageEditorRenderer.TextLayout
    }

    private var textLayoutCache: [UUID: CachedTextLayout] = [:]

    init(original: CGImage, document: ImageEditorDocument) throws {
        self.original = original
        self.annotations = document.annotations
        self.cropRect = document.cropRect
        self.cropDraft = nil
        let effectsImage = try ImageEditorRenderer.renderEffects(original: original, annotations: document.annotations)
        self.effectsImage = effectsImage
        self.effectsNSImage = NSImage(
            cgImage: effectsImage,
            size: NSSize(width: CGFloat(original.width), height: CGFloat(original.height))
        )
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        setAccessibilityLabel(BiscuitLocalization.string("Image editing canvas"))
        updateZoom()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard isInteractionEnabled else { return }
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "z" {
            if event.modifierFlags.contains(.shift) { onRedo?() } else { onUndo?() }
            return
        }
        if event.keyCode == 51 || event.keyCode == 117 {
            deleteSelection()
            return
        }
        super.keyDown(with: event)
    }

    func replaceDocument(_ document: ImageEditorDocument, rasterEffectsChanged: Bool = true) throws {
        annotations = document.annotations
        textLayoutCache.removeAll(keepingCapacity: true)
        cropRect = document.cropRect
        cropDraft = nil
        if rasterEffectsChanged { effectsImage = try ImageEditorRenderer.renderEffects(original: original, annotations: annotations) }
        needsDisplay = true
        onCropDraftChanged?()
    }

    var hasCropDraft: Bool { cropDraft != nil }
    var hasCropRect: Bool { cropRect != nil }

    func beginCrop() {
        cropDraft = nil
        needsDisplay = true
        onCropDraftChanged?()
    }

    func applyCrop() {
        guard let cropDraft else { return }
        cropRect = cropDraft
        self.cropDraft = nil
        onCropChanged?(cropRect)
        needsDisplay = true
        onCropDraftChanged?()
    }

    func cancelCrop() {
        guard cropDraft != nil else { return }
        cropDraft = nil
        needsDisplay = true
        onCropDraftChanged?()
    }

    func resetCrop() {
        guard cropRect != nil else { return }
        cropRect = nil
        cropDraft = nil
        onCropChanged?(nil)
        needsDisplay = true
        onCropDraftChanged?()
    }

    private func updateZoom() {
        let width = CGFloat(original.width) * CGFloat(zoom)
        let height = CGFloat(original.height) * CGFloat(zoom)
        setFrameSize(NSSize(width: width + imageInset * 2, height: height + imageInset * 2))
        needsDisplay = true
    }

    func setSelected(_ id: UUID?) { selectedID = id; needsDisplay = true }
    func updateSelectedText(_ value: String) {
        guard isInteractionEnabled else { return }
        guard let selectedID, let index = annotations.firstIndex(where: { $0.id == selectedID }),
              annotations[index].kind == .text else { return }
        annotations[index].text = value
        onDocumentChanged?(annotations)
        needsDisplay = true
    }

    func updateSelectedStyle(colorHex: String? = nil, lineWidth: Double? = nil, fontSize: Double? = nil) {
        guard isInteractionEnabled else { return }
        guard let selectedID, let index = annotations.firstIndex(where: { $0.id == selectedID }) else { return }
        if let colorHex { annotations[index].colorHex = colorHex }
        if let lineWidth { annotations[index].lineWidth = lineWidth }
        if let fontSize, annotations[index].kind == .text { annotations[index].fontSize = fontSize }
        onDocumentChanged?(annotations)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.windowBackgroundColor.setFill(); bounds.fill()
        let sourceSize = NSSize(width: CGFloat(original.width), height: CGFloat(original.height))
        let imageSize = NSSize(width: sourceSize.width * CGFloat(zoom),
                               height: sourceSize.height * CGFloat(zoom))
        imageRect = NSRect(x: imageInset, y: imageInset, width: imageSize.width, height: imageSize.height)
        let needsTextContext = annotations.contains(where: { $0.kind == .text }) ||
            (dragMode == .drawing && tool == .text && dragStart != nil)
        let textContext = needsTextContext
            ? NSGraphicsContext.current.map { NSGraphicsContext(cgContext: $0.cgContext, flipped: false) }
            : nil
        // Keep image pixels aligned with the flipped view and the flattened PNG's source orientation.
        effectsNSImage.draw(in: imageRect, from: .zero, operation: .copy, fraction: 1,
                            respectFlipped: true, hints: nil)
        for annotation in annotations where !annotation.isRasterEffect {
            ImageEditorRenderer.draw(annotation, in: imageRect, flipped: true, sourceSize: sourceSize,
                                     textLayout: textLayout(for: annotation), textContext: textContext)
        }
        if tool == .crop, let start = dragStart, let end = dragCurrent {
            drawCropOverlay(cropSelection(from: start, to: end))
        } else if let cropDraft {
            drawCropOverlay(cropDraft)
        } else if let cropRect {
            drawCropOverlay(cropRect)
        }
        if let selectedID, let annotation = annotations.first(where: { $0.id == selectedID }) {
            drawSelection(for: annotation)
        }
        if let dragStart, let dragCurrent, dragMode == .drawing, tool != .highlight, tool != .crop {
            let preview = makeAnnotation(from: dragStart, to: dragCurrent, points: freehandPoints,
                                         id: previewAnnotationID ?? UUID())
            ImageEditorRenderer.draw(preview, in: imageRect, flipped: true, sourceSize: sourceSize,
                                     textLayout: textLayout(for: preview), textContext: textContext)
            if preview.kind == .redaction {
                NSColor.black.setFill()
                NSBezierPath(rect: canvasRect(preview)).fill()
            }
            drawSelection(for: preview)
        } else if let dragStart, dragMode == .drawing, tool == .highlight, !freehandPoints.isEmpty {
            let preview = makeAnnotation(from: dragStart, to: dragStart, points: freehandPoints,
                                         id: previewAnnotationID ?? UUID())
            ImageEditorRenderer.draw(preview, in: imageRect, flipped: true, sourceSize: sourceSize,
                                     textLayout: textLayout(for: preview), textContext: textContext)
        }
    }
    private func cropSelection(from start: NSPoint, to end: NSPoint) -> ImageEditorRect {
        let first = normalized(start), second = normalized(end)
        let minX = min(first.x, second.x), minY = min(first.y, second.y)
        return ImageEditorRect(x: minX, y: minY,
                               width: abs(first.x - second.x), height: abs(first.y - second.y))
    }

    private func drawCropOverlay(_ crop: ImageEditorRect) {
        guard crop.width > 0, crop.height > 0 else { return }
        let rect = NSRect(x: imageRect.minX + CGFloat(crop.x) * imageRect.width,
                          y: imageRect.minY + CGFloat(crop.y) * imageRect.height,
                          width: CGFloat(crop.width) * imageRect.width,
                          height: CGFloat(crop.height) * imageRect.height)
        NSColor.black.withAlphaComponent(0.42).setFill()
        NSRect(x: imageRect.minX, y: imageRect.minY, width: imageRect.width, height: max(0, rect.minY - imageRect.minY)).fill()
        NSRect(x: imageRect.minX, y: rect.maxY, width: imageRect.width, height: max(0, imageRect.maxY - rect.maxY)).fill()
        NSRect(x: imageRect.minX, y: rect.minY, width: max(0, rect.minX - imageRect.minX), height: rect.height).fill()
        NSRect(x: rect.maxX, y: rect.minY, width: max(0, imageRect.maxX - rect.maxX), height: rect.height).fill()
        let outline = NSBezierPath(rect: rect)
        outline.lineWidth = 2
        outline.setLineDash([5, 4], count: 2, phase: 0)
        NSColor.white.setStroke()
        outline.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        guard isInteractionEnabled else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard imageRect.contains(point) else { return }
        if let previousPreviewID = previewAnnotationID,
           !annotations.contains(where: { $0.id == previousPreviewID }) {
            textLayoutCache.removeValue(forKey: previousPreviewID)
        }
        previewAnnotationID = nil
        if tool == .select {
            if let index = hitTestAnnotation(at: point) {
                dragAnnotationIndex = index
                originalAnnotation = annotations[index]
                selectedID = annotations[index].id
                dragStart = point
                dragCurrent = point
                dragMode = handleHit(annotation: annotations[index], point: point) ? .resizing : .moving
            } else {
                selectedID = nil
                dragStart = nil
                dragCurrent = nil
            }
            needsDisplay = true
            return
        }
        previewAnnotationID = UUID()
        dragStart = point
        dragCurrent = point
        dragMode = .drawing
        freehandPoints = [normalized(point)]
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard isInteractionEnabled else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard let start = dragStart else { return }
        dragCurrent = point
        if tool == .select, let index = dragAnnotationIndex, let originalAnnotation {
            let changed = adjusted(originalAnnotation, from: start, to: point, resizing: dragMode == .resizing)
            annotations[index] = changed
            if changed.isRasterEffect, let raster = try? ImageEditorRenderer.renderEffects(original: original, annotations: annotations) {
                effectsImage = raster
            }
        } else if tool == .highlight {
            let next = normalized(point)
            if let last = freehandPoints.last, hypot(last.x - next.x, last.y - next.y) > 0.002 { freehandPoints.append(next) }
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard isInteractionEnabled else {
            if let previewAnnotationID {
                textLayoutCache.removeValue(forKey: previewAnnotationID)
            }
            previewAnnotationID = nil
            dragStart = nil; dragCurrent = nil; dragAnnotationIndex = nil; originalAnnotation = nil
            freehandPoints = []
            return
        }
        let activePreviewID = previewAnnotationID
        defer {
            if let activePreviewID, !annotations.contains(where: { $0.id == activePreviewID }) {
                textLayoutCache.removeValue(forKey: activePreviewID)
            }
            previewAnnotationID = nil
            dragStart = nil; dragCurrent = nil; dragAnnotationIndex = nil; originalAnnotation = nil
            freehandPoints = []; needsDisplay = true
        }
        if tool == .select {
            onDocumentChanged?(annotations)
            return
        }
        guard let start = dragStart else { return }
        let end = convert(event.locationInWindow, from: nil)
        if tool == .crop {
            let selection = cropSelection(from: start, to: end)
            guard selection.width * Double(original.width) >= 16,
                  selection.height * Double(original.height) >= 16 else { return }
            cropDraft = selection
            onCropDraftChanged?()
            return
        }
        let annotation = makeAnnotation(from: start, to: end, points: freehandPoints,
                                        id: previewAnnotationID ?? UUID())
        let bounds = annotation.bounds
        let drawingSpan = annotation.kind == .line ? max(bounds.width, bounds.height) : bounds.width
        guard drawingSpan > 0.004 || annotation.kind == .highlight else { return }
        if annotation.kind == .text && annotation.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return }
        annotations.append(annotation)
        selectedID = annotation.id
        do {
            effectsImage = try ImageEditorRenderer.renderEffects(original: original, annotations: annotations)
        } catch {
            annotations.removeLast()
            NSSound.beep()
        }
        onDocumentChanged?(annotations)
    }

    func deleteSelection() {
        guard let selectedID else { return }
        textLayoutCache.removeValue(forKey: selectedID)
        annotations.removeAll { $0.id == selectedID }
        self.selectedID = nil
        do { effectsImage = try ImageEditorRenderer.renderEffects(original: original, annotations: annotations) }
        catch { NSSound.beep() }
        onDocumentChanged?(annotations)
        needsDisplay = true
    }

    func restoreDocument(_ document: ImageEditorDocument) throws {
        annotations = document.annotations
        textLayoutCache.removeAll(keepingCapacity: true)
        cropRect = document.cropRect
        cropDraft = nil
        effectsImage = try ImageEditorRenderer.renderEffects(original: original, annotations: annotations)
        if let selectedID, !annotations.contains(where: { $0.id == selectedID }) { self.selectedID = nil }
        needsDisplay = true
        onCropDraftChanged?()
    }

    private func makeAnnotation(from start: NSPoint, to end: NSPoint, points: [ImageEditorPoint],
                                id: UUID = UUID()) -> ImageEditorAnnotation {
        let kind: ImageEditorAnnotationKind
        switch tool {
        case .select: kind = .rectangle
        case .crop: kind = .rectangle
        case .arrow: kind = .arrow
        case .line: kind = .line
        case .rectangle: kind = .rectangle
        case .ellipse: kind = .ellipse
        case .text: kind = .text
        case .highlight: kind = .highlight
        case .redaction: kind = .redaction
        case .pixelation: kind = .pixelation
        }
        let text = textValue.isEmpty ? BiscuitLocalization.string("Text") : textValue
        return ImageEditorAnnotation(id: id, kind: kind, start: normalized(start), end: normalized(end), points: points,
                                     text: text, colorHex: selectedColor, lineWidth: lineWidth, fontSize: fontSize)
    }

    private func normalized(_ point: NSPoint) -> ImageEditorPoint {
        ImageEditorPoint(x: Double(max(0, min(1, (point.x - imageRect.minX) / imageRect.width))),
                         y: Double(max(0, min(1, (point.y - imageRect.minY) / imageRect.height))))
    }

    private func hitTestAnnotation(at point: NSPoint) -> Int? {
        for index in annotations.indices.reversed() {
            let annotation = annotations[index]
            let rect = canvasRect(annotation).insetBy(dx: -7, dy: -7)
            if rect.contains(point) { return index }
        }
        return nil
    }

    private func handleHit(annotation: ImageEditorAnnotation, point: NSPoint) -> Bool {
        let rect = canvasRect(annotation)
        let handle = NSRect(x: rect.maxX - 5, y: rect.maxY - 5, width: 10, height: 10)
        return handle.insetBy(dx: -5, dy: -5).contains(point)
    }

    private func textLayout(for annotation: ImageEditorAnnotation) -> ImageEditorRenderer.TextLayout? {
        guard annotation.kind == .text else { return nil }
        let sourceSize = NSSize(width: CGFloat(original.width), height: CGFloat(original.height))
        if let cached = textLayoutCache[annotation.id] {
            if cached.annotation == annotation { return cached.layout }
            if hasSameTextContent(cached.annotation, annotation) {
                let bounds: ImageEditorRect
                if annotation.start == annotation.end {
                    let previous = cached.layout.bounds
                    let x = min(max(0, annotation.start.x), max(0, 1 - previous.width))
                    let y = min(max(0, annotation.start.y), max(0, 1 - previous.height))
                    bounds = ImageEditorRect(x: x, y: y, width: previous.width, height: previous.height)
                } else {
                    bounds = annotation.bounds
                }
                let layout = ImageEditorRenderer.relocatingTextLayout(cached.layout, to: bounds)
                textLayoutCache[annotation.id] = CachedTextLayout(annotation: annotation, layout: layout)
                return layout
            }
        }
        
        guard let layout = ImageEditorRenderer.textLayout(for: annotation, sourceSize: sourceSize) else {
            return nil
        }
        textLayoutCache[annotation.id] = CachedTextLayout(annotation: annotation, layout: layout)
        return layout
    }

    private func hasSameTextContent(_ first: ImageEditorAnnotation, _ second: ImageEditorAnnotation) -> Bool {
        first.kind == second.kind &&
        first.text == second.text &&
        first.colorHex == second.colorHex &&
        first.fontSize == second.fontSize &&
        (first.start == first.end) == (second.start == second.end)
    }

    private func resolvedBounds(for annotation: ImageEditorAnnotation) -> ImageEditorRect {
        guard annotation.kind == .text, annotation.start == annotation.end else { return annotation.bounds }
        return textLayout(for: annotation)?.bounds ?? annotation.bounds
    }

    private func canvasRect(_ annotation: ImageEditorAnnotation) -> NSRect {
        let bounds = resolvedBounds(for: annotation)
        return NSRect(x: imageRect.minX + CGFloat(bounds.minX) * imageRect.width,
                      y: imageRect.minY + CGFloat(bounds.minY) * imageRect.height,
                      width: CGFloat(bounds.width) * imageRect.width,
                      height: CGFloat(bounds.height) * imageRect.height)
    }

    private func adjusted(_ source: ImageEditorAnnotation, from start: NSPoint, to end: NSPoint, resizing: Bool) -> ImageEditorAnnotation {
        var result = source
        let dx = Double((end.x - start.x) / imageRect.width)
        let dy = Double((end.y - start.y) / imageRect.height)
        if resizing {
            let bounds = resolvedBounds(for: source)
            if source.kind == .arrow || source.kind == .line {
                result.end = ImageEditorPoint(x: max(0, min(1, source.end.x + dx)),
                                              y: max(0, min(1, source.end.y + dy)))
            } else if source.kind == .highlight {
                result.points = source.points.map { ImageEditorPoint(x: max(0, min(1, $0.x + dx)), y: max(0, min(1, $0.y + dy))) }
            } else {
                result.start = ImageEditorPoint(x: bounds.minX, y: bounds.minY)
                result.end = ImageEditorPoint(x: max(bounds.minX + 0.004, min(1, bounds.maxX + dx)),
                                              y: max(bounds.minY + 0.004, min(1, bounds.maxY + dy)))
            }
        } else if source.kind == .highlight {
            result.points = source.points.map { ImageEditorPoint(x: max(0, min(1, $0.x + dx)), y: max(0, min(1, $0.y + dy))) }
        } else {
            result.start = ImageEditorPoint(x: max(0, min(1, source.start.x + dx)), y: max(0, min(1, source.start.y + dy)))
            result.end = ImageEditorPoint(x: max(0, min(1, source.end.x + dx)), y: max(0, min(1, source.end.y + dy)))
        }
        return result
    }

    private func drawSelection(for annotation: ImageEditorAnnotation) {
        let rect = canvasRect(annotation)
        let path = NSBezierPath(rect: rect.insetBy(dx: -4, dy: -4))
        path.setLineDash([4, 3], count: 2, phase: 0)
        path.lineWidth = 1
        NSColor.controlAccentColor.setStroke(); path.stroke()
        let handle = NSRect(x: rect.maxX - 4, y: rect.maxY - 4, width: 8, height: 8)
        NSColor.white.setFill(); NSBezierPath(ovalIn: handle).fill()
        NSColor.controlAccentColor.setStroke(); NSBezierPath(ovalIn: handle).stroke()
    }
}

@MainActor
public final class ImageEditorWindowController: NSWindowController, NSWindowDelegate {
    public let itemID: UUID
    private var session: ImageEditorSession
    private let onSave: (ImageEditorSession, Data, @escaping (Result<Void, Error>) -> Void) -> Void
    private let onClose: (UUID) -> Void
    private var canvas: ImageEditorCanvasView?
    private var canvasScrollView: NSScrollView?
    private var fitsWindow = true
    private var editorContentView: NSView?
    private var history = ImageEditorHistory()
    private var savedDocument: ImageEditorDocument
    private var saveButton: NSButton?
    private var undoButton: NSButton?
    private var redoButton: NSButton?
    private var applyCropButton: NSButton?
    private var cancelCropButton: NSButton?
    private var resetCropButton: NSButton?
    private var zoomSlider: NSSlider?
    private var statusLabel: NSTextField?
    private var closeAfterSave = false
    private var isSaving = false

    public init(
        itemID: UUID,
        title: String,
        imageURL: URL,
        persistence: ImageEditorPersistence,
        onSave: @escaping (ImageEditorSession, Data, @escaping (Result<Void, Error>) -> Void) -> Void,
        onClose: @escaping (UUID) -> Void
    ) throws {
        self.itemID = itemID
        self.session = try persistence.open(itemID: itemID, imageURL: imageURL)
        self.savedDocument = self.session.document
        self.onSave = onSave
        self.onClose = onClose
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = title.isEmpty
            ? BiscuitLocalization.string("Edit Image")
            : BiscuitLocalization.format("Edit Image — %1$@", arguments: [title])
        window.minSize = NSSize(width: 680, height: 460)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildWindow()
        BiscuitLocalization.applyInterfaceDirection(to: window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    public func present() {
        guard let window else { return }
        guard BiscuitPresentation.show(window) else { return }
        NSApp.activate(ignoringOtherApps: true)
    }

    private var isDirty: Bool { session.document != savedDocument }

    private func buildWindow() {
        guard let window else { return }
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 8
        root.translatesAutoresizingMaskIntoConstraints = false

        let toolbar = NSStackView()
        toolbar.orientation = .vertical
        toolbar.alignment = .leading
        toolbar.spacing = 5
        toolbar.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)

        let toolRow = NSStackView()
        toolRow.orientation = .horizontal
        toolRow.alignment = .centerY
        toolRow.spacing = 5
        for (tool, title) in [(ImageEditorTool.select, "Select"), (.crop, "Crop"), (.arrow, "Arrow"), (.line, "Line"), (.rectangle, "Box"), (.ellipse, "Oval"), (.text, "Text"), (.highlight, "Highlight"), (.redaction, "Redact"), (.pixelation, "Pixelate")] {
            let button = NSButton(title: BiscuitLocalization.string(title), target: self, action: #selector(selectTool(_:)))
            button.tag = ImageEditorTool.allCases.firstIndex(of: tool) ?? 0
            button.bezelStyle = .texturedRounded
            button.toolTip = BiscuitLocalization.string(title)
            toolRow.addArrangedSubview(button)
        }
        let applyCrop = NSButton(title: BiscuitLocalization.string("Apply Crop"), target: self, action: #selector(applyCrop(_:)))
        let cancelCrop = NSButton(title: BiscuitLocalization.string("Cancel Crop"), target: self, action: #selector(cancelCrop(_:)))
        let resetCrop = NSButton(title: BiscuitLocalization.string("Reset Crop"), target: self, action: #selector(resetCrop(_:)))
        applyCropButton = applyCrop; cancelCropButton = cancelCrop; resetCropButton = resetCrop
        toolRow.addArrangedSubview(applyCrop); toolRow.addArrangedSubview(cancelCrop); toolRow.addArrangedSubview(resetCrop)

        let styleRow = NSStackView()
        styleRow.orientation = .horizontal
        styleRow.alignment = .centerY
        styleRow.spacing = 5
        let colors = NSPopUpButton()
        colors.addItems(withTitles: ["Red", "Blue", "Black", "White", "Yellow"].map { BiscuitLocalization.string($0) })
        colors.target = self
        colors.action = #selector(colorChanged(_:))
        styleRow.addArrangedSubview(colors)
        let widthSlider = NSSlider(value: 0.004, minValue: 0.001, maxValue: 0.02, target: self, action: #selector(widthChanged(_:)))
        widthSlider.widthAnchor.constraint(equalToConstant: 72).isActive = true
        widthSlider.toolTip = BiscuitLocalization.string("Stroke width")
        styleRow.addArrangedSubview(widthSlider)
        let textSize = NSSlider(value: 0.04, minValue: 0.015, maxValue: 0.12, target: self, action: #selector(textSizeChanged(_:)))
        textSize.widthAnchor.constraint(equalToConstant: 72).isActive = true
        textSize.toolTip = BiscuitLocalization.string("Text size")
        styleRow.addArrangedSubview(textSize)
        let text = NSTextField(string: BiscuitLocalization.string("Text"))
        text.placeholderString = BiscuitLocalization.string("Text to place")
        text.widthAnchor.constraint(equalToConstant: 100).isActive = true
        text.target = self
        text.action = #selector(textChanged(_:))
        styleRow.addArrangedSubview(text)
        let zoomOut = NSButton(title: "−", target: self, action: #selector(zoomOut(_:)))
        zoomOut.toolTip = BiscuitLocalization.string("Zoom out")
        let zoomControl = NSSlider(value: 1, minValue: 0.02, maxValue: 4, target: self, action: #selector(zoomChanged(_:)))
        zoomControl.widthAnchor.constraint(equalToConstant: 80).isActive = true
        zoomControl.toolTip = BiscuitLocalization.string("Zoom scale; 100% is one image pixel per point")
        zoomSlider = zoomControl
        let zoomIn = NSButton(title: "+", target: self, action: #selector(zoomIn(_:)))
        zoomIn.toolTip = BiscuitLocalization.string("Zoom in")
        let fit = NSButton(title: BiscuitLocalization.string("Fit"), target: self, action: #selector(fitCanvas(_:)))
        let actualSize = NSButton(title: "100%", target: self, action: #selector(actualSize(_:)))
        actualSize.toolTip = BiscuitLocalization.string("Actual size (one image pixel per point)")
        styleRow.addArrangedSubview(zoomOut); styleRow.addArrangedSubview(zoomControl); styleRow.addArrangedSubview(zoomIn)
        styleRow.addArrangedSubview(fit); styleRow.addArrangedSubview(actualSize)
        let undo = NSButton(title: BiscuitLocalization.string("Undo"), target: self, action: #selector(undo(_:)))
        let redo = NSButton(title: BiscuitLocalization.string("Redo"), target: self, action: #selector(redo(_:)))
        undoButton = undo; redoButton = redo
        styleRow.addArrangedSubview(undo); styleRow.addArrangedSubview(redo)
        styleRow.addArrangedSubview(NSView())
        let copy = NSButton(title: BiscuitLocalization.string("Copy Image"), target: self, action: #selector(copyImage(_:)))
        let export = NSButton(title: BiscuitLocalization.string("Export…"), target: self, action: #selector(exportImage(_:)))
        let cancel = NSButton(title: BiscuitLocalization.string("Cancel"), target: self, action: #selector(cancel(_:)))
        let save = NSButton(title: BiscuitLocalization.string("Save"), target: self, action: #selector(save(_:)))
        save.keyEquivalent = "\r"
        saveButton = save
        styleRow.addArrangedSubview(copy); styleRow.addArrangedSubview(export); styleRow.addArrangedSubview(cancel); styleRow.addArrangedSubview(save)
        toolbar.addArrangedSubview(toolRow)
        toolbar.addArrangedSubview(styleRow)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        let createdCanvas = try? ImageEditorCanvasView(original: session.originalImage, document: session.document)
        guard let createdCanvas else {
            let failure = NSTextField(labelWithString: ImageEditorError.encodingFailed.localizedDescription)
            window.contentView = failure
            return
        }
        createdCanvas.tool = .select
        createdCanvas.textValue = text.stringValue
        createdCanvas.zoom = zoomSlider?.doubleValue ?? 1
        createdCanvas.onDocumentChanged = { [weak self] annotations in
            guard let self else { return }
            var document = self.session.document
            document.annotations = annotations
            self.record(document)
        }
        createdCanvas.onCropChanged = { [weak self] cropRect in
            guard let self else { return }
            var document = self.session.document
            document.cropRect = cropRect
            self.record(document)
        }
        createdCanvas.onCropDraftChanged = { [weak self] in self?.updateButtons() }
        createdCanvas.onUndo = { [weak self] in self?.undo(nil) }
        createdCanvas.onRedo = { [weak self] in self?.redo(nil) }
        canvas = createdCanvas
        scroll.documentView = createdCanvas
        canvasScrollView = scroll

        let status = NSTextField(labelWithString: BiscuitLocalization.string("Changes stay local. Save updates the library; Export and Copy use a flattened image."))
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        statusLabel = status
        root.addArrangedSubview(toolbar)
        root.addArrangedSubview(scroll)
        root.addArrangedSubview(status)
        let content = NSView()
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            root.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
            toolbar.widthAnchor.constraint(equalTo: root.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: root.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 300),
            status.widthAnchor.constraint(equalTo: root.widthAnchor)
        ])
        window.contentView = content
        editorContentView = content
        content.layoutSubtreeIfNeeded()
        scroll.layoutSubtreeIfNeeded()
        fitCanvasToViewport()
        window.makeFirstResponder(createdCanvas)
        updateButtons()
    }

    private func record(_ document: ImageEditorDocument) {
        let old = session.document
        guard old != document else { return }
        history.record(from: old, to: document)
        session.document = document
        let rasterEffectsChanged = old.annotations.filter(\.isRasterEffect) != document.annotations.filter(\.isRasterEffect)
        do { try canvas?.replaceDocument(document, rasterEffectsChanged: rasterEffectsChanged) }
        catch { statusLabel?.stringValue = error.localizedDescription }
        updateButtons()
    }

    private func updateButtons() {
        setControlEnabled(in: editorContentView, enabled: !isSaving)
        canvas?.isInteractionEnabled = !isSaving
        undoButton?.isEnabled = history.canUndo && !isSaving
        redoButton?.isEnabled = history.canRedo && !isSaving
        applyCropButton?.isEnabled = !isSaving && (canvas?.hasCropDraft ?? false)
        cancelCropButton?.isEnabled = !isSaving && (canvas?.hasCropDraft ?? false)
        resetCropButton?.isEnabled = !isSaving && (canvas?.hasCropRect ?? false)
        saveButton?.isEnabled = !isSaving && isDirty
    }

    private func setControlEnabled(in view: NSView?, enabled: Bool) {
        guard let view else { return }
        for child in view.subviews {
            if let control = child as? NSControl { control.isEnabled = enabled }
            setControlEnabled(in: child, enabled: enabled)
        }
    }

    @objc private func selectTool(_ sender: NSButton) {
        guard ImageEditorTool.allCases.indices.contains(sender.tag) else { return }
        let tool = ImageEditorTool.allCases[sender.tag]
        canvas?.tool = tool
        if tool == .crop {
            canvas?.beginCrop()
            statusLabel?.stringValue = BiscuitLocalization.string("Drag a crop region, then Apply Crop. Cancel Crop leaves the current crop unchanged.")
        } else if tool == .redaction {
            statusLabel?.stringValue = BiscuitLocalization.string("Redaction is solid black in the flattened output.")
        } else if tool == .pixelation {
            statusLabel?.stringValue = BiscuitLocalization.string("Pixelation is flattened into the exported image.")
        } else {
            statusLabel?.stringValue = BiscuitLocalization.string("Draw on the image. Select an annotation to move or resize it.")
        }
    }

    @objc private func applyCrop(_ sender: Any?) { canvas?.applyCrop() }
    @objc private func cancelCrop(_ sender: Any?) { canvas?.cancelCrop() }
    @objc private func resetCrop(_ sender: Any?) { canvas?.resetCrop() }

    @objc private func colorChanged(_ sender: NSPopUpButton) {
        let values = ["#E53935", "#1565C0", "#111111", "#FFFFFF", "#FFEB3B"]
        let color = values[max(0, min(values.count - 1, sender.indexOfSelectedItem))]
        canvas?.selectedColor = color
        canvas?.updateSelectedStyle(colorHex: color)
    }

    @objc private func widthChanged(_ sender: NSSlider) {
        canvas?.lineWidth = sender.doubleValue
        canvas?.updateSelectedStyle(lineWidth: sender.doubleValue)
    }

    @objc private func textSizeChanged(_ sender: NSSlider) {
        canvas?.fontSize = sender.doubleValue
        canvas?.updateSelectedStyle(fontSize: sender.doubleValue)
    }

    @objc private func textChanged(_ sender: NSTextField) {
        canvas?.textValue = sender.stringValue
        canvas?.updateSelectedText(sender.stringValue)
    }

    @objc private func zoomChanged(_ sender: NSSlider) { setZoom(sender.doubleValue, fitting: false) }
    @objc private func zoomIn(_ sender: Any?) { setZoom((zoomSlider?.doubleValue ?? 1) * 1.25, fitting: false) }
    @objc private func zoomOut(_ sender: Any?) { setZoom((zoomSlider?.doubleValue ?? 1) / 1.25, fitting: false) }
    @objc private func fitCanvas(_ sender: Any?) { fitCanvasToViewport() }
    @objc private func actualSize(_ sender: Any?) { setZoom(1, fitting: false) }

    private func fitCanvasToViewport() {
        guard let canvas, let canvasScrollView else { return }
        let viewport = canvasScrollView.contentSize
        guard viewport.width > 1, viewport.height > 1 else { return }
        let fit = min(Double((viewport.width - 24) / CGFloat(canvas.original.width)),
                      Double((viewport.height - 24) / CGFloat(canvas.original.height)))
        let zoom = max(0.0001, min(4, fit))
        zoomSlider?.minValue = min(0.02, zoom)
        setZoom(zoom, fitting: true)
    }

    private func setZoom(_ value: Double, fitting: Bool) {
        guard let zoomSlider else { return }
        fitsWindow = fitting
        zoomSlider.doubleValue = max(zoomSlider.minValue, min(zoomSlider.maxValue, value))
        canvas?.zoom = zoomSlider.doubleValue
    }

    @objc private func undo(_ sender: Any?) {
        guard let prior = history.undo(current: session.document) else { return }
        session.document = prior
        do { try canvas?.restoreDocument(prior) } catch { statusLabel?.stringValue = error.localizedDescription }
        updateButtons()
    }

    @objc private func redo(_ sender: Any?) {
        guard let next = history.redo(current: session.document) else { return }
        session.document = next
        do { try canvas?.restoreDocument(next) } catch { statusLabel?.stringValue = error.localizedDescription }
        updateButtons()
    }

    @objc private func copyImage(_ sender: Any?) {
        do {
            let data = try flattenedPNG()
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            guard pasteboard.setData(data, forType: .png) else { throw ImageEditorError.pasteboardFailed }
            statusLabel?.stringValue = BiscuitLocalization.string("Flattened image copied. Original pixels and editor annotations are not on the clipboard.")
        } catch { show(error) }
    }

    @objc private func exportImage(_ sender: Any?) {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.png]
        panel.nameFieldStringValue = "biscuit-edited-image.png"
        panel.canCreateDirectories = true
        BiscuitLocalization.applyInterfaceDirection(to: panel)
        BiscuitPresentation.beginSheet(panel, for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            do { try self.flattenedPNG().write(to: url, options: .atomic); self.statusLabel?.stringValue = BiscuitLocalization.string("Flattened PNG exported.") }
            catch { self.show(error) }
        }
    }
    @objc private func save(_ sender: Any?) {
        guard !isSaving else { return }
        guard isDirty else { closeWithoutPrompt(); return }
        do {
            let png = try flattenedPNG()
            isSaving = true
            statusLabel?.stringValue = BiscuitLocalization.string("Saving image…")
            updateButtons()
            onSave(session, png) { [weak self] result in
                guard let self else { return }
                self.isSaving = false
                switch result {
                case .success:
                    self.savedDocument = self.session.document
                    self.statusLabel?.stringValue = BiscuitLocalization.string("Saved. The original remains available for later edits.")
                    self.updateButtons()
                    if self.closeAfterSave { self.closeWithoutPrompt() }
                case .failure(let error):
                    self.closeAfterSave = false
                    self.statusLabel?.stringValue = error.localizedDescription
                    self.updateButtons()
                }
            }
        } catch { show(error) }
    }

    @objc private func cancel(_ sender: Any?) {
        guard !isSaving else { return }
        if isDirty { confirmDiscardOrSave() } else { closeWithoutPrompt() }
    }

    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !isSaving else { return false }
        guard isDirty else { closeWithoutPrompt(); return false }
        confirmDiscardOrSave()
        return false
    }
    public func windowDidResize(_ notification: Notification) {
        if fitsWindow { fitCanvasToViewport() }
    }

    private func confirmDiscardOrSave() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = BiscuitLocalization.string("Save image edits?")
        alert.informativeText = BiscuitLocalization.string("Canceling discards these changes and leaves the saved image unchanged.")
        alert.addButton(withTitle: BiscuitLocalization.string("Save"))
        alert.addButton(withTitle: BiscuitLocalization.string("Discard Changes"))
        alert.addButton(withTitle: BiscuitLocalization.string("Keep Editing"))
        BiscuitLocalization.applyInterfaceDirection(to: alert)
        switch BiscuitPresentation.runModal(alert) {
        case .alertFirstButtonReturn:
            closeAfterSave = true
            save(nil)
        case .alertSecondButtonReturn:
            closeWithoutPrompt()
        default:
            break
        }
    }

    private func closeWithoutPrompt() {
        guard let window else { return }
        window.delegate = nil
        window.close()
        onClose(itemID)
    }

    private func flattenedPNG() throws -> Data {
        try ImageEditorRenderer.flattenedPNG(
            original: session.originalImage,
            annotations: session.document.annotations,
            cropRect: session.document.cropRect
        )
    }

    private func show(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = BiscuitLocalization.string("Image editing failed")
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: BiscuitLocalization.string("OK"))
        BiscuitLocalization.applyInterfaceDirection(to: alert)
        if let window { BiscuitPresentation.beginSheet(alert, for: window) } else { _ = BiscuitPresentation.runModal(alert) }
    }
}


import AppKit
import Foundation
import ImageIO

enum ImageEditorActualSidecarChecks {
    private struct CheckFailure: Error, LocalizedError {
        let description: String
        var errorDescription: String? { description }
    }

    @MainActor static func run(fixturesAt explicitDirectory: URL? = nil) throws {
        // Use the captured public-band source and saved sidecar, not a synthetic crop fixture.
        let fixtures = try fixtureDirectory(explicitlyAt: explicitDirectory)
        let sourceData = try Data(contentsOf: fixtures.appendingPathComponent("public-band-07.png"))
        let sidecarData = try Data(contentsOf: fixtures.appendingPathComponent("public-band-07-sidecar.json"))

        guard let source = CGImageSourceCreateWithData(sourceData as CFData, nil),
              let original = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw CheckFailure(description: "actual public-band source fixture is not a readable image")
        }
        let document = try JSONDecoder().decode(ImageEditorDocument.self, from: sidecarData)
        let textAnnotations = document.annotations.filter { $0.kind == .text }
        guard Set(textAnnotations.map(\.text)) == Set(["QA-POINT-50", "QA-POINT-100"]),
              document.annotations.contains(where: { $0.kind == .line }),
              let pixelation = document.annotations.first(where: { $0.kind == .pixelation }),
              let crop = document.cropRect else {
            throw CheckFailure(description: "captured public-band sidecar no longer contains its crop, line, pixelation, and two point-text annotations")
        }

        try verifyActualPixelation(original: original, annotation: pixelation)
        try verifyUprightFlattenedText(original: original, document: document, textAnnotations: textAnnotations, crop: crop)
        try verifyUprightCanvasText(original: original, document: document, textAnnotations: textAnnotations)
    }

    private static func fixtureDirectory(explicitlyAt explicitDirectory: URL?) throws -> URL {
        let directory = explicitDirectory ?? Bundle.main.resourceURL?
            .appendingPathComponent("Fixtures/ImageEditor", isDirectory: true)
        guard let directory,
              FileManager.default.fileExists(atPath: directory.appendingPathComponent("public-band-07.png").path),
              FileManager.default.fileExists(atPath: directory.appendingPathComponent("public-band-07-sidecar.json").path) else {
            throw CheckFailure(description: "bundled actual public-band image-editor fixtures are unavailable")
        }
        return directory
    }

    private static func verifyActualPixelation(original: CGImage, annotation: ImageEditorAnnotation) throws {
        let source = NSBitmapImageRep(cgImage: original)
        let effectImage = try ImageEditorRenderer.renderEffects(original: original, annotations: [annotation])
        let effect = NSBitmapImageRep(cgImage: effectImage)
        let bounds = annotation.bounds
        let x0 = max(0, min(original.width - 1, Int(floor(bounds.minX * Double(original.width)))))
        let x1 = max(x0 + 1, min(original.width, Int(ceil(bounds.maxX * Double(original.width)))))
        let y0 = max(0, min(original.height - 1, Int(floor(bounds.minY * Double(original.height)))))
        let y1 = max(y0 + 1, min(original.height, Int(ceil(bounds.maxY * Double(original.height)))))
        var changedPixels = 0
        var sourceColors = Set<UInt32>()
        for y in y0..<y1 {
            for x in x0..<x1 {
                let before = try colorKey(source, x: x, y: y)
                let after = try colorKey(effect, x: x, y: y)
                if before != after { changedPixels += 1 }
                if sourceColors.count < 8 { sourceColors.insert(before) }
            }
        }
        try check(sourceColors.count > 2, "actual sidecar pixelation region contains public-band text/high-detail pixels")
        try check(changedPixels > 0, "actual sidecar pixelation changes source pixels")

        var containsSolidMosaicBlock = false
        blockSearch: for y in stride(from: y0, to: y1, by: 12) {
            for x in stride(from: x0, to: x1, by: 12) {
                let endX = min(x1, x + 12)
                let endY = min(y1, y + 12)
                var beforeColors = Set<UInt32>()
                var afterColors = Set<UInt32>()
                for sampleY in y..<endY {
                    for sampleX in x..<endX {
                        beforeColors.insert(try colorKey(source, x: sampleX, y: sampleY))
                        afterColors.insert(try colorKey(effect, x: sampleX, y: sampleY))
                    }
                }
                if beforeColors.count > 1 && afterColors.count == 1 {
                    containsSolidMosaicBlock = true
                    break blockSearch
                }
            }
        }
        try check(containsSolidMosaicBlock, "actual sidecar pixelation produces a uniform mosaic block over source detail")
    }

    private static func verifyUprightFlattenedText(
        original: CGImage,
        document: ImageEditorDocument,
        textAnnotations: [ImageEditorAnnotation],
        crop: ImageEditorRect
    ) throws {
        let nonTextAnnotations = document.annotations.filter { $0.kind != .text }
        let baseFull = try ImageEditorRenderer.render(original: original, annotations: nonTextAnnotations)
        let sourceSize = NSSize(width: original.width, height: original.height)
        let referenceBitmap = NSBitmapImageRep(cgImage: baseFull)
        guard let context = NSGraphicsContext(bitmapImageRep: referenceBitmap) else {
            throw CheckFailure(description: "could not create an upright text reference bitmap")
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        for annotation in textAnnotations {
            let bounds = ImageEditorRenderer.resolvedBounds(for: annotation, in: sourceSize)
            let fontSize = max(10, CGFloat(annotation.fontSize) * min(sourceSize.width, sourceSize.height))
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byWordWrapping
            let attributed = NSAttributedString(string: annotation.text, attributes: [
                .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
                .foregroundColor: color(for: annotation.colorHex),
                .paragraphStyle: paragraph
            ])
            let rect = NSRect(
                x: CGFloat(bounds.minX) * sourceSize.width,
                y: (1 - CGFloat(bounds.maxY)) * sourceSize.height,
                width: CGFloat(bounds.width) * sourceSize.width,
                height: CGFloat(bounds.height) * sourceSize.height
            ).insetBy(dx: 3, dy: 2)
            attributed.draw(in: rect)
        }
        NSGraphicsContext.restoreGraphicsState()

        guard let expectedFull = referenceBitmap.cgImage else {
            throw CheckFailure(description: "could not read the upright text reference bitmap")
        }
        let baseline = try ImageEditorRenderer.cropFlattenedImage(original: baseFull, to: crop)
        let expected = try ImageEditorRenderer.cropFlattenedImage(original: expectedFull, to: crop)
        let actual = try ImageEditorRenderer.render(original: original, annotations: document.annotations, cropRect: crop)
        try check(actual.width == 960 && actual.height == 680, "actual sidecar crop retains its 960×680 public-band output")
        try compareTextCoverage(actual: actual, expected: expected, baseline: baseline, annotations: textAnnotations,
                                sourceSize: sourceSize, crop: crop)
    }
    @MainActor private static func verifyUprightCanvasText(
        original: CGImage,
        document: ImageEditorDocument,
        textAnnotations: [ImageEditorAnnotation]
    ) throws {
        let nonTextAnnotations = document.annotations.filter { $0.kind != .text }
        let flat = NSBitmapImageRep(cgImage: try ImageEditorRenderer.render(
            original: original, annotations: document.annotations
        ))
        let flatBaseline = NSBitmapImageRep(cgImage: try ImageEditorRenderer.render(
            original: original, annotations: nonTextAnnotations
        ))
        let flatTopAtHighY = try topAtHighY(in: flatBaseline)
        let sourceSize = NSSize(width: CGFloat(original.width), height: CGFloat(original.height))
        let actualCanvas = try ImageEditorCanvasView(original: original, document: document)
        let baselineCanvas = try ImageEditorCanvasView(
            original: original,
            document: ImageEditorDocument(annotations: nonTextAnnotations, cropRect: document.cropRect)
        )
        actualCanvas.isInteractionEnabled = false
        baselineCanvas.isInteractionEnabled = false

        for zoom in [0.5, 1.0, 2.0] {
            try autoreleasepool {
                actualCanvas.zoom = zoom
                baselineCanvas.zoom = zoom
                let actual = try renderCanvasOffscreen(actualCanvas)
                let baseline = try renderCanvasOffscreen(baselineCanvas)
                try compareCanvasTextCoverage(
                    actual: actual, baseline: baseline, flattened: flat, flattenedBaseline: flatBaseline,
                    annotations: textAnnotations, sourceSize: sourceSize, zoom: zoom,
                    flattenedTopAtHighY: flatTopAtHighY
                )
            }
        }
    }

    @MainActor private static func renderCanvasOffscreen(_ canvas: ImageEditorCanvasView) throws -> NSBitmapImageRep {
        let bounds = canvas.bounds
        let width = max(1, Int(ceil(bounds.width)))
        let height = max(1, Int(ceil(bounds.height)))
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            throw CheckFailure(description: "could not create an offscreen actual-sidecar Canvas preview")
        }
        bitmap.size = NSSize(width: CGFloat(width), height: CGFloat(height))
        // Let AppKit establish the flipped-view transform at the test's explicit 1-pixel-per-point scale.
        canvas.cacheDisplay(in: bounds, to: bitmap)
        return bitmap
    }

    private static func compareCanvasTextCoverage(
        actual: NSBitmapImageRep,
        baseline: NSBitmapImageRep,
        flattened: NSBitmapImageRep,
        flattenedBaseline: NSBitmapImageRep,
        annotations: [ImageEditorAnnotation],
        sourceSize: NSSize,
        zoom: Double,
        flattenedTopAtHighY: Bool
    ) throws {
        var comparedPixels = 0
        var mismatchedPixels = 0
        var canvasMinX = Int.max, canvasMinY = Int.max, canvasMaxX = -1, canvasMaxY = -1
        var flatMinX = Int.max, flatMinY = Int.max, flatMaxX = -1, flatMaxY = -1
        let sourceWidth = Int(sourceSize.width)
        let sourceHeight = Int(sourceSize.height)
        for annotation in annotations {
            let bounds = ImageEditorRenderer.resolvedBounds(for: annotation, in: sourceSize)
            let foreground = colorComponents(color(for: annotation.colorHex))
            let sourceX0 = max(0, Int(floor(bounds.minX * Double(sourceWidth))))
            let sourceX1 = min(sourceWidth, Int(ceil(bounds.maxX * Double(sourceWidth))))
            let sourceY0 = max(0, Int(floor(bounds.minY * Double(sourceHeight))))
            let sourceY1 = min(sourceHeight, Int(ceil(bounds.maxY * Double(sourceHeight))))
            for sourceY in sourceY0..<sourceY1 {
                let flatY = flattenedTopAtHighY ? flattened.pixelsHigh - 1 - sourceY : sourceY
                let viewY = Int((12 + Double(sourceY) * zoom).rounded())
                // cacheDisplay rows follow the flipped view's y axis.
                let canvasY = viewY
                for sourceX in sourceX0..<sourceX1 {
                    let viewX = Int((12 + Double(sourceX) * zoom).rounded())
                    guard viewX >= 0, viewX < actual.pixelsWide,
                          canvasY >= 0, canvasY < actual.pixelsHigh,
                          sourceX < flattened.pixelsWide, flatY >= 0, flatY < flattened.pixelsHigh else { continue }
                    let canvasCoverage = textCoverage(
                        before: rgb(baseline, x: viewX, y: canvasY),
                        after: rgb(actual, x: viewX, y: canvasY),
                        foreground: foreground
                    )
                    if canvasCoverage >= 0.5 {
                        canvasMinX = min(canvasMinX, sourceX); canvasMaxX = max(canvasMaxX, sourceX)
                        canvasMinY = min(canvasMinY, sourceY); canvasMaxY = max(canvasMaxY, sourceY)
                    }
                    let flatCoverage = textCoverage(
                        before: rgb(flattenedBaseline, x: sourceX, y: flatY),
                        after: rgb(flattened, x: sourceX, y: flatY),
                        foreground: foreground
                    )
                    if flatCoverage >= 0.5 {
                        flatMinX = min(flatMinX, sourceX); flatMaxX = max(flatMaxX, sourceX)
                        flatMinY = min(flatMinY, sourceY); flatMaxY = max(flatMaxY, sourceY)
                    }
                    guard max(canvasCoverage, flatCoverage) >= 0.2 else { continue }
                    comparedPixels += 1
                    if abs(canvasCoverage - flatCoverage) > 0.35 { mismatchedPixels += 1 }
                }
            }
        }
        try check(canvasMaxX >= canvasMinX && flatMaxX >= flatMinX,
                  "actual sidecar Canvas and flattened exports contain measurable point-text cores at zoom \(zoom)")
        let maximumEdgeDelta = max(
            abs(canvasMinX - flatMinX), abs(canvasMinY - flatMinY),
            abs(canvasMaxX - flatMaxX), abs(canvasMaxY - flatMaxY)
        )
        try check(maximumEdgeDelta <= 8,
                  "actual sidecar Canvas glyph bounds track flattened bounds at zoom \(zoom) (edge delta \(maximumEdgeDelta) source pixels)")
        try check(comparedPixels > 500, "actual sidecar point text is visible in the Canvas preview at zoom \(zoom)")
        let mismatchFraction = Double(mismatchedPixels) / Double(comparedPixels)
        let allowedMismatch = zoom == 1 ? 0.08 : 0.35
        try check(mismatchFraction <= allowedMismatch,
                  "actual public-band sidecar Canvas glyphs match upright flattened pixels at zoom \(zoom) (mismatch \(mismatchedPixels)/\(comparedPixels))")
    }

    private static func topAtHighY(in bitmap: NSBitmapImageRep) throws -> Bool {
        let high = rgb(bitmap, x: 8, y: bitmap.pixelsHigh - 5)
        let low = rgb(bitmap, x: 8, y: 4)
        if isMagentaBand(high) { return true }
        if isMagentaBand(low) { return false }
        throw CheckFailure(description: "public-band source orientation markers were not preserved in the flattened baseline")
    }


    private static func isMagentaBand(_ color: (CGFloat, CGFloat, CGFloat)) -> Bool {
        color.0 > 0.25 && color.2 > 0.2 && color.1 < 0.2
    }



    private static func compareTextCoverage(
        actual: CGImage,
        expected: CGImage,
        baseline: CGImage,
        annotations: [ImageEditorAnnotation],
        sourceSize: NSSize,
        crop: ImageEditorRect
    ) throws {
        guard actual.width == expected.width, actual.height == expected.height,
              actual.width == baseline.width, actual.height == baseline.height else {
            throw CheckFailure(description: "actual and upright-reference flattened images have different dimensions")
        }
        let actualBitmap = NSBitmapImageRep(cgImage: actual)
        let expectedBitmap = NSBitmapImageRep(cgImage: expected)
        let baselineBitmap = NSBitmapImageRep(cgImage: baseline)
        let foreground = colorComponents(color(for: annotations[0].colorHex))
        var comparedPixels = 0
        var mismatchedPixels = 0
        for y in 0..<actual.height {
            for x in 0..<actual.width {
                let before = rgb(baselineBitmap, x: x, y: y)
                let actualCoverage = textCoverage(before: before, after: rgb(actualBitmap, x: x, y: y), foreground: foreground)
                let expectedCoverage = textCoverage(before: before, after: rgb(expectedBitmap, x: x, y: y), foreground: foreground)
                guard max(actualCoverage, expectedCoverage) >= 0.2 else { continue }
                comparedPixels += 1
                if abs(actualCoverage - expectedCoverage) > 0.35 { mismatchedPixels += 1 }
            }
        }
        try check(comparedPixels > 500, "actual sidecar labels produce measurable flattened glyph pixels")
        let mismatchFraction = Double(mismatchedPixels) / Double(comparedPixels)
        try check(mismatchFraction <= 0.08,
                  "actual public-band sidecar point-text glyphs are upright in the flattened pixels (mismatch \(mismatchedPixels)/\(comparedPixels), crop \(crop.x),\(crop.y), source \(sourceSize.width)×\(sourceSize.height))")
    }

    private static func color(for hex: String) -> NSColor {
        guard hex.count == 7, hex.first == "#", let value = UInt32(hex.dropFirst(), radix: 16) else { return .systemRed }
        return NSColor(calibratedRed: CGFloat((value >> 16) & 0xff) / 255,
                       green: CGFloat((value >> 8) & 0xff) / 255,
                       blue: CGFloat(value & 0xff) / 255, alpha: 1)
    }

    private static func colorComponents(_ color: NSColor) -> (CGFloat, CGFloat, CGFloat) {
        let value = color.usingColorSpace(.deviceRGB) ?? .systemRed
        let components = value.cgColor.components ?? [1, 0, 0, 1]
        return (components[0], components[1], components[2])
    }

    private static func rgb(_ bitmap: NSBitmapImageRep, x: Int, y: Int) -> (CGFloat, CGFloat, CGFloat) {
        guard let components = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)?.cgColor.components,
              components.count >= 3 else { return (0, 0, 0) }
        return (components[0], components[1], components[2])
    }

    private static func textCoverage(
        before: (CGFloat, CGFloat, CGFloat),
        after: (CGFloat, CGFloat, CGFloat),
        foreground: (CGFloat, CGFloat, CGFloat)
    ) -> CGFloat {
        let red = before.0 - foreground.0
        let green = before.1 - foreground.1
        let blue = before.2 - foreground.2
        let denominator = red * red + green * green + blue * blue
        guard denominator > 0 else { return 0 }
        return ((before.0 - after.0) * red + (before.1 - after.1) * green +
                (before.2 - after.2) * blue) / denominator
    }

    private static func colorKey(_ bitmap: NSBitmapImageRep, x: Int, y: Int) throws -> UInt32 {
        guard let components = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)?.cgColor.components,
              components.count >= 3 else {
            throw CheckFailure(description: "public-band fixture pixel could not be read")
        }
        let red = UInt32((components[0] * 255).rounded())
        let green = UInt32((components[1] * 255).rounded())
        let blue = UInt32((components[2] * 255).rounded())
        return (red << 16) | (green << 8) | blue
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ description: String) throws {
        guard condition() else { throw CheckFailure(description: description) }
    }
}

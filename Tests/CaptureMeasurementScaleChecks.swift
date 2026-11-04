import AppKit
import CoreGraphics
import Foundation

@MainActor
enum CaptureMeasurementScaleChecks {
    private struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    private static let captureMarkers: [Double] = [91_001, 91_002, 91_003, 91_004, 91_005, 91_006]

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(description: message) }
    }

    private static func makeImage(width: Int, height: Int) throws -> CGImage {
        let data = Data(repeating: 0, count: width * height * 4)
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else {
            throw Failure(description: "Could not create synthetic capture image.")
        }
        return image
    }

    static func run() async throws {
        guard let path = ProcessInfo.processInfo.environment["BISCUIT_DATA_DIR"], !path.isEmpty else {
            throw Failure(description: "Capture measurement regression requires an isolated BISCUIT_DATA_DIR.")
        }
        let dataDirectory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        let store = MeasurementLogStore(dataDirectory: dataDirectory)
        let startingCount = try await store.entries().count

        let area = CGRect(x: 0, y: 0, width: 824, height: 550)
        let stitchedImage = try makeImage(width: 1_648, height: 5_380)
        let ordinaryImage = try makeImage(width: 1_649, height: 1_100)
        let controller = CaptureController(
            onText: { _ in }, onImage: { _ in }, onCopiedText: { _ in },
            onCopiedImage: {}, onEditImage: { _ in }
        )
        let startedAt = ProcessInfo.processInfo.systemUptime

        controller.recordImageMeasurement(
            area: area, startedAt: startedAt, captureMilliseconds: captureMarkers[0],
            image: stitchedImage, outcome: .succeeded, isStitchedOutput: true
        )
        // A completed stitched image that cannot be stored still logs its real output dimensions and backing scale.
        controller.recordImageMeasurement(
            area: area, startedAt: startedAt, captureMilliseconds: captureMarkers[1],
            image: stitchedImage, outcome: .failed, isStitchedOutput: true
        )
        controller.recordImageMeasurement(
            area: area, startedAt: startedAt, captureMilliseconds: captureMarkers[2],
            image: ordinaryImage, outcome: .succeeded
        )
        controller.recordTextMeasurement(
            area: area, startedAt: startedAt, captureMilliseconds: captureMarkers[3],
            image: ordinaryImage, result: nil, outcome: .succeeded
        )
        controller.recordImageMeasurement(
            area: area, startedAt: startedAt, captureMilliseconds: captureMarkers[4],
            image: nil, outcome: .cancelled
        )
        controller.recordImageMeasurement(
            area: area, startedAt: startedAt, captureMilliseconds: captureMarkers[5],
            image: nil, outcome: .failed
        )

        var logged = try await store.entries()
        for _ in 0..<100 where logged.filter({ captureMarkers.contains($0.captureMilliseconds ?? -1) }).count < captureMarkers.count {
            try await Task.sleep(nanoseconds: 10_000_000)
            logged = try await store.entries()
        }
        let captureEntries = logged.filter { captureMarkers.contains($0.captureMilliseconds ?? -1) }
        try require(captureEntries.count == captureMarkers.count, "Expected six production measurement entries in the isolated JSONL log.")
        try require(logged.count == startingCount + captureMarkers.count, "Unexpected measurement records appeared during the isolated regression.")

        func entry(_ marker: Double, operation: MeasurementEntry.Operation, outcome: MeasurementEntry.Outcome) throws -> MeasurementEntry {
            guard let result = captureEntries.first(where: {
                $0.captureMilliseconds == marker && $0.operation == operation && $0.outcome == outcome
            }) else {
                throw Failure(description: "Missing logged measurement for marker \(marker).")
            }
            return result
        }

        let stitchedSuccess = try entry(captureMarkers[0], operation: .imageCapture, outcome: .succeeded)
        let stitchedWriteFailure = try entry(captureMarkers[1], operation: .imageCapture, outcome: .failed)
        for result in [stitchedSuccess, stitchedWriteFailure] {
            try require(result.scale == 2, "Stitched capture scale must be the horizontal backing ratio 1648/824=2; got \(String(describing: result.scale)).")
            try require(result.widthPixels == 1_648 && result.heightPixels == 5_380, "Stitched output pixel dimensions must remain unchanged.")
            try require(result.widthPoints == 824 && result.heightPoints == 550, "Stitched measurement point dimensions must remain the selected ROI.")
        }

        let ordinaryExpectedScale = max(Double(1_649) / 824, Double(1_100) / 550)
        let ordinaryImageEntry = try entry(captureMarkers[2], operation: .imageCapture, outcome: .succeeded)
        let ordinaryTextEntry = try entry(captureMarkers[3], operation: .textCapture, outcome: .succeeded)
        try require(ordinaryImageEntry.scale == ordinaryExpectedScale, "Ordinary image scale must retain its existing max-of-axes rounding behavior.")
        try require(ordinaryTextEntry.scale == ordinaryExpectedScale, "Text capture scale must retain its existing max-of-axes rounding behavior.")
        try require(ordinaryImageEntry.widthPixels == 1_649 && ordinaryImageEntry.heightPixels == 1_100,
                    "Ordinary image dimensions must remain unchanged.")
        try require(ordinaryTextEntry.widthPixels == 1_649 && ordinaryTextEntry.heightPixels == 1_100,
                    "Text capture dimensions must remain unchanged.")

        for (marker, outcome) in [(captureMarkers[4], MeasurementEntry.Outcome.cancelled), (captureMarkers[5], .failed)] {
            let noImage = try entry(marker, operation: .imageCapture, outcome: outcome)
            try require(noImage.widthPixels == nil && noImage.heightPixels == nil && noImage.scale == nil,
                        "Nil-image cancellation/failure must not invent pixel dimensions or a scale.")
        }
    }
}

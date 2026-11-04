import CoreGraphics
import Foundation

/// Exercises the production overlap matcher and stitcher using generated, uniquely labeled bands.
enum ScrollingCaptureBehaviorChecks {
    private struct CheckFailure: Error, CustomStringConvertible {
        let description: String
    }

    static func run() throws {
        try verifyBandOrderAndExactRows()
        try verifyStationaryFramesAndRecovery()
        try verifyDirectionAndCancellation()
        try verifyPixelBudget()
        print("Scrolling capture behavior checks passed")
    }

    private static func verifyBandOrderAndExactRows() throws {
        let width = 192
        let frameHeight = 240
        let bandHeight = 120
        let bandCount = 8
        let document = try makeViewport(width: width, height: bandHeight * bandCount, globalTop: 0, bandHeight: bandHeight)
        var sequence = ScrollingCaptureSequence()
        let offsets = stride(from: 0, through: bandHeight * bandCount - frameHeight, by: bandHeight)
        for (index, offset) in offsets.enumerated() {
            let frame = try makeViewport(width: width, height: frameHeight, globalTop: offset, bandHeight: bandHeight)
            let result = try sequence.append(frame)
            if index == 0 {
                try check(isFirstFrame(result), "initial viewport becomes the first image section")
            } else {
                try check(isAppended(result), "overlapping scroll frame \(index) is stitched; got \(String(describing: result))")
            }
        }
        let stitched = try sequence.finish()
        try check(stitched.width == width && stitched.height == document.height,
                  "the stitched image preserves full width and every document row")
        try check(try rasterBytes(stitched) == rasterBytes(document),
                  "uniquely labeled horizontal bands appear in order exactly once with no skipped or duplicated rows")
        try check(sequence.finished, "Done commits the stitched image once")
        try check(isClosed(try sequence.append(document)), "a completed sequence cannot produce a second image")
        do {
            _ = try sequence.finish()
            throw CheckFailure(description: "a second Done must not produce another image")
        } catch ScrollingCaptureError.sessionClosed { }
    }

    private static func verifyStationaryFramesAndRecovery() throws {
        let initial = try makeViewport(width: 96, height: 240, globalTop: 0, bandHeight: 80)
        let moved = try makeViewport(width: 96, height: 240, globalTop: 80, bandHeight: 80)
        var firstGapSequence = ScrollingCaptureSequence()
        _ = try firstGapSequence.append(initial)
        let firstJump = try makeViewport(width: 96, height: 240, globalTop: 400, bandHeight: 80)
        let firstJumpResult = try firstGapSequence.append(firstJump)
        try check(isRejectedMove(firstJumpResult), "a first move with no trustworthy overlap cannot be accepted")
        try check(firstGapSequence.needsRecovery, "a first unstitched move still blocks Done")
        var sequence = ScrollingCaptureSequence()
        _ = try sequence.append(initial)
        try check(isUnchanged(try sequence.append(initial)), "a stationary frame does not add duplicate rows")
        try check(sequence.sectionCount == 1, "stationary frames do not increase the section count")
        try check(isAppended(try sequence.append(moved)), "a later overlapping move remains recoverable")
        do {
            _ = try sequence.append(makeViewport(width: 95, height: 240, globalTop: 80, bandHeight: 80))
            throw CheckFailure(description: "a changed pixel geometry must fail the sequence")
        } catch ScrollingCaptureError.inconsistentFrameSize { }
        try check(sequence.sectionCount == 2, "a geometry change cannot replace the last accepted frame")

        let gap = try makeViewport(width: 96, height: 240, globalTop: 400, bandHeight: 80)
        let gapResult = try sequence.append(gap)
        try check(isRejectedMove(gapResult), "a movement beyond the captured overlap is rejected; got \(String(describing: gapResult))")
        try check(sequence.needsRecovery, "an unstitched viewport prevents Done from silently returning a partial image")
        do {
            _ = try sequence.finish()
            throw CheckFailure(description: "Done must not commit after an unstitched movement")
        } catch ScrollingCaptureError.needsRecovery { }

        let returned = try makeViewport(width: 96, height: 240, globalTop: 80, bandHeight: 80)
        try check(isUnchanged(try sequence.append(returned)), "returning to the last accepted viewport clears the recovery warning")
        try check(!sequence.needsRecovery, "recovery state clears only after the last accepted viewport is restored")
        let recovered = try sequence.finish()
        let expected = try makeViewport(width: 96, height: 320, globalTop: 0, bandHeight: 80)
        try check(try rasterBytes(recovered) == rasterBytes(expected),
                  "recovery excludes every unstitched gap from the committed image")
    }

    private static func verifyDirectionAndCancellation() throws {
        let first = try makeViewport(width: 96, height: 240, globalTop: 0, bandHeight: 80)
        let down = try makeViewport(width: 96, height: 240, globalTop: 80, bandHeight: 80)
        let backUp = try makeViewport(width: 96, height: 240, globalTop: 40, bandHeight: 80)
        var reversed = ScrollingCaptureSequence()
        _ = try reversed.append(first)
        _ = try reversed.append(down)
        try check(isReversed(try reversed.append(backUp)), "reversing direction is reported instead of duplicating already captured content")
        try check(reversed.needsRecovery, "Done remains blocked until the original viewport is restored")

        var cancelled = ScrollingCaptureSequence()
        _ = try cancelled.append(first)
        _ = try cancelled.append(down)
        cancelled.cancel()
        try check(isClosed(try cancelled.append(first)), "cancellation closes the sequence against late frame writes")
        do {
            _ = try cancelled.finish()
            throw CheckFailure(description: "cancelled scrolling capture must not produce an image")
        } catch ScrollingCaptureError.sessionClosed { }
        try check(cancelled.sectionCount == 0, "cancellation releases every uncommitted image section")
    }

    private static func verifyPixelBudget() throws {
        try check(ScrollingCaptureLimits.permits(width: 10_000, height: 8_000), "an image at the 80-million-pixel boundary is permitted")
        try check(!ScrollingCaptureLimits.permits(width: 10_001, height: 8_000), "one pixel beyond the pixel budget is rejected")
        try check(!ScrollingCaptureLimits.permits(width: 1, height: 32_769), "height beyond the image dimension limit is rejected")
    }

    private static func makeViewport(width: Int, height: Int, globalTop: Int, bandHeight: Int) throws -> CGImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            let globalY = globalTop + y
            let band = globalY / bandHeight
            let withinBand = globalY % bandHeight
            for x in 0..<width {
                let offset = (y * width + x) * 4
                // Each band has a unique red label; green/blue encode row position, while
                // alternating vertical bars make the overlap distinctive to the matcher.
                let label = UInt8(24 + (band * 27) % 208)
                let bar = ((x / 5 + withinBand / 6 + band) & 1) == 0
                bytes[offset] = label
                bytes[offset + 1] = UInt8(20 + globalY % 220)
                bytes[offset + 2] = bar ? 32 : 220
                bytes[offset + 3] = 255
            }
        }
        let data = Data(bytes) as CFData
        guard let provider = CGDataProvider(data: data),
              let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else { throw CheckFailure(description: "generated band fixture image could not be created") }
        return image
    }

    private static func rasterBytes(_ image: CGImage) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let rendered = bytes.withUnsafeMutableBytes { storage -> Bool in
            guard let context = CGContext(
                data: storage.baseAddress,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard rendered else { throw CheckFailure(description: "generated fixture could not be rasterized") }
        return bytes
    }

    private static func check(_ condition: Bool, _ label: String) throws {
        guard condition else { throw CheckFailure(description: label) }
    }

    private static func isFirstFrame(_ result: ScrollCaptureAppendResult) -> Bool {
        if case .firstFrame = result { return true }
        return false
    }

    private static func isAppended(_ result: ScrollCaptureAppendResult) -> Bool {
        if case .appended = result { return true }
        return false
    }

    private static func isUnchanged(_ result: ScrollCaptureAppendResult) -> Bool {
        if case .unchanged = result { return true }
        return false
    }

    private static func isRejectedMove(_ result: ScrollCaptureAppendResult) -> Bool {
        if case .noOverlap = result { return true }
        if case .ambiguousOverlap = result { return true }
        if case .reversedDirection = result { return true }
        return false
    }

    private static func isReversed(_ result: ScrollCaptureAppendResult) -> Bool {
        if case .reversedDirection = result { return true }
        return false
    }

    private static func isClosed(_ result: ScrollCaptureAppendResult) -> Bool {
        if case .closed = result { return true }
        return false
    }
}

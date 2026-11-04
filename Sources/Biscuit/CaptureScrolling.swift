import AppKit
import CoreGraphics
import Foundation

/// A scroll sequence only commits if every observed viewport remains stitchable to the
/// last accepted viewport. It never turns a gap or a reversed scroll into a plausible image.
struct ScrollingCaptureSequence: @unchecked Sendable {
    private var stitcher: ScrollImageStitcher?
    private(set) var cancelled = false
    private(set) var needsRecovery = false
    private(set) var finished = false

    var sectionCount: Int { stitcher?.sectionCount ?? 0 }

    mutating func append(_ image: CGImage) throws -> ScrollCaptureAppendResult {
        guard !cancelled, !finished else { return .closed }
        guard var stitcher else {
            self.stitcher = try ScrollImageStitcher(firstFrame: image)
            needsRecovery = false
            return .firstFrame
        }
        let result = try stitcher.append(image)
        self.stitcher = stitcher
        switch result {
        case .appended:
            needsRecovery = false
        case .unchanged:
            // The user has returned to the last accepted viewport after an unstitched move.
            needsRecovery = false
        case .noOverlap, .ambiguousOverlap, .reversedDirection:
            needsRecovery = true
        case .firstFrame, .closed:
            break
        }
        return result
    }

    mutating func finish() throws -> CGImage {
        guard !cancelled, !finished else { throw ScrollingCaptureError.sessionClosed }
        guard !needsRecovery else { throw ScrollingCaptureError.needsRecovery }
        guard let stitcher else { throw ScrollingCaptureError.noCapturedFrames }
        guard stitcher.sectionCount > 1 else { throw ScrollingCaptureError.noScrollRecorded }
        let image = try stitcher.makeImage()
        finished = true
        self.stitcher = nil
        return image
    }

    mutating func cancel() {
        guard !finished else { return }
        cancelled = true
        needsRecovery = false
        stitcher = nil
    }
}

enum ScrollCaptureAppendResult: Sendable {
    case firstFrame
    case appended(sections: Int)
    case unchanged
    case noOverlap
    case ambiguousOverlap
    case reversedDirection
    case closed
}

enum ScrollingCaptureError: LocalizedError, Sendable {
    case inconsistentFrameSize
    case imageTooLarge
    case imageEncoding
    case noCapturedFrames
    case noScrollRecorded
    case needsRecovery
    case sessionClosed

    var errorDescription: String? {
        switch self {
        case .inconsistentFrameSize:
            return BiscuitLocalization.string("The selected area changed pixel size while scrolling. Cancel and start again without moving the display layout.")
        case .imageTooLarge:
            return BiscuitLocalization.string("This long image exceeds the safe capture limit. Finish a shorter section or select a smaller area.")
        case .imageEncoding:
            return BiscuitLocalization.string("The long image could not be assembled safely. No image was saved.")
        case .noCapturedFrames:
            return BiscuitLocalization.string("The initial selected-area image is not ready yet. Try Done again.")
        case .noScrollRecorded:
            return BiscuitLocalization.string("No scrolling content was captured. Scroll inside the selected area before choosing Done.")
        case .needsRecovery:
            return BiscuitLocalization.string("Scrolling did not overlap the last captured view. Return to it, then use smaller moves or cancel.")
        case .sessionClosed:
            return BiscuitLocalization.string("This scrolling capture has already ended.")
        }
    }
}

/// Uses the same dimensional/pixel budget as one-shot screen capture, before any canvas allocation.
enum ScrollingCaptureLimits {
    static let maximumDimension = 32_768
    static let maximumPixels = 80_000_000

    static func permits(width: Int, height: Int) -> Bool {
        guard width > 0, height > 0, width <= maximumDimension, height <= maximumDimension else { return false }
        return width <= maximumPixels / height
    }
}
private enum ScrollCaptureDirection: Equatable { case down, up }

private struct ScrollImageStitcher {
    private struct Tile {
        let top: Int
        let image: CGImage
    }

    private let width: Int
    private let frameHeight: Int
    private var top = 0
    private var bottom: Int
    private var direction: ScrollCaptureDirection?
    private var tiles: [Tile]
    private var lastFingerprint: ScrollImageFingerprint
    private(set) var sectionCount = 1

    init(firstFrame: CGImage) throws {
        width = firstFrame.width
        frameHeight = firstFrame.height
        guard ScrollingCaptureLimits.permits(width: width, height: frameHeight) else {
            throw ScrollingCaptureError.imageTooLarge
        }
        bottom = frameHeight
        lastFingerprint = try ScrollImageFingerprint.make(firstFrame)
        tiles = [Tile(top: 0, image: firstFrame)]
    }

    mutating func append(_ frame: CGImage) throws -> ScrollCaptureAppendResult {
        guard frame.width == width, frame.height == frameHeight else {
            throw ScrollingCaptureError.inconsistentFrameSize
        }
        let fingerprint = try ScrollImageFingerprint.make(frame)
        switch ScrollFrameMatcher.align(lastFingerprint, fingerprint) {
        case .unchanged:
            return .unchanged
        case .noOverlap:
            return .noOverlap
        case .ambiguous:
            return .ambiguousOverlap
        case .aligned(let candidate):
            if let direction, direction != candidate.direction { return .reversedDirection }
            let proposedTop = candidate.direction == .up ? top - candidate.distance : top
            let proposedBottom = candidate.direction == .down ? bottom + candidate.distance : bottom
            let proposedHeight = proposedBottom - proposedTop
            guard ScrollingCaptureLimits.permits(width: width, height: proposedHeight) else {
                throw ScrollingCaptureError.imageTooLarge
            }
            let strip: CGImage
            let tileTop: Int
            if candidate.direction == .down {
                let crop = CGRect(x: 0, y: frameHeight - candidate.distance, width: width, height: candidate.distance)
                strip = try Self.compactCrop(frame, rect: crop)
                tileTop = bottom
                bottom = proposedBottom
            } else {
                let crop = CGRect(x: 0, y: 0, width: width, height: candidate.distance)
                strip = try Self.compactCrop(frame, rect: crop)
                top = proposedTop
                tileTop = top
            }
            direction = candidate.direction
            tiles.append(Tile(top: tileTop, image: strip))
            lastFingerprint = fingerprint
            sectionCount += 1
            return .appended(sections: sectionCount)
        }
    }

    func makeImage() throws -> CGImage {
        let outputHeight = bottom - top
        guard ScrollingCaptureLimits.permits(width: width, height: outputHeight),
              let context = CGContext(
                data: nil,
                width: width,
                height: outputHeight,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { throw ScrollingCaptureError.imageEncoding }
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: outputHeight))
        context.interpolationQuality = .none
        for tile in tiles {
            let logicalTop = tile.top - top
            let drawY = outputHeight - logicalTop - tile.image.height
            context.draw(tile.image, in: CGRect(x: 0, y: drawY, width: width, height: tile.image.height))
        }
        guard let image = context.makeImage() else { throw ScrollingCaptureError.imageEncoding }
        return image
    }

    private static func compactCrop(_ source: CGImage, rect: CGRect) throws -> CGImage {
        let crop = rect.integral
        guard let cropped = source.cropping(to: crop),
              let context = CGContext(
                data: nil,
                width: Int(crop.width),
                height: Int(crop.height),
                bitsPerComponent: 8,
                bytesPerRow: Int(crop.width) * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { throw ScrollingCaptureError.imageEncoding }
        context.interpolationQuality = .none
        context.draw(cropped, in: CGRect(origin: .zero, size: CGSize(width: crop.width, height: crop.height)))
        guard let image = context.makeImage() else { throw ScrollingCaptureError.imageEncoding }
        return image
    }
}

private struct ScrollImageFingerprint {
    struct GrayPlane {
        let width: Int
        let height: Int
        let bytes: [UInt8]
        let texturedRows: [Bool]
    }

    let full: GrayPlane
    let coarse: GrayPlane

    static func make(_ image: CGImage) throws -> Self {
        let full = try makePlane(image, width: min(160, image.width), height: image.height)
        let coarseHeight = min(1_024, image.height)
        let coarse = try makePlane(image, width: min(112, image.width), height: coarseHeight)
        return Self(full: full, coarse: coarse)
    }

    private static func makePlane(_ image: CGImage, width: Int, height: Int) throws -> GrayPlane {
        guard width > 0, height > 0,
              width <= Int.max / height,
              let colorSpace = CGColorSpace(name: CGColorSpace.genericGrayGamma2_2) else {
            throw ScrollingCaptureError.imageEncoding
        }
        var bytes = [UInt8](repeating: 0, count: width * height)
        let rendered = bytes.withUnsafeMutableBytes { storage -> Bool in
            guard let context = CGContext(
                data: storage.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { throw ScrollingCaptureError.imageEncoding }
        var textured = [Bool](repeating: false, count: height)
        for y in 0..<height {
            let start = y * width
            var sum = 0.0
            var squareSum = 0.0
            for x in 0..<width {
                let value = Double(bytes[start + x])
                sum += value
                squareSum += value * value
            }
            let mean = sum / Double(width)
            let variance = max(0, squareSum / Double(width) - mean * mean)
            textured[y] = variance > 16
        }
        return GrayPlane(width: width, height: height, bytes: bytes, texturedRows: textured)
    }
}

private struct ScrollFrameMatcher {
    private static let maximumAlignmentScore = 12.0
    enum Result {
        case unchanged
        case noOverlap
        case ambiguous
        case aligned(Candidate)
    }

    struct Candidate {
        let direction: ScrollCaptureDirection
        let distance: Int
        let score: Double
    }

    private struct PlaneCandidate {
        let direction: ScrollCaptureDirection
        let offset: Int
        let score: Double
    }

    static func align(_ previous: ScrollImageFingerprint, _ current: ScrollImageFingerprint) -> Result {
        let a = previous.coarse
        let b = current.coarse
        guard a.width == b.width, a.height == b.height, a.height > 12 else { return .noOverlap }
        let samePositionDifference = difference(a, b, aOffset: 0, bOffset: 0, rowStep: max(1, a.height / 128))
        if samePositionDifference < 0.8 { return .unchanged }

        let coarseStep = max(1, a.height / 384)
        let coarseSearchStep = max(1, a.height / 128)
        let minimumCoarseOffset = max(2, a.height / 160)
        let maximumCoarseOffset = a.height * 9 / 10
        var candidates: [PlaneCandidate] = []
        for direction in [ScrollCaptureDirection.down, .up] {
            guard minimumCoarseOffset < maximumCoarseOffset else { continue }
            for offset in stride(from: minimumCoarseOffset, through: maximumCoarseOffset, by: coarseSearchStep) {
                guard let score = score(
                    a, b, direction: direction, offset: offset, rowStep: coarseStep, columnStep: 2
                ) else { continue }
                candidates.append(PlaneCandidate(direction: direction, offset: offset, score: score))
            }
        }
        candidates.sort { $0.score < $1.score }
        guard let bestCoarse = candidates.first, bestCoarse.score < maximumAlignmentScore else {
            return .noOverlap
        }

        let fullHeight = previous.full.height
        let scale = Double(fullHeight) / Double(a.height)
        let radius = max(2, Int(ceil(scale * Double(coarseSearchStep))) + 1)
        var refined: [Candidate] = []
        for coarse in candidates.prefix(3) where coarse.score <= bestCoarse.score + 3.0 {
            let expected = Int((Double(coarse.offset) * scale).rounded())
            let lower = max(max(4, fullHeight / 100), expected - radius)
            let upper = min(fullHeight * 9 / 10, expected + radius)
            guard lower <= upper else { continue }
            for distance in lower...upper {
                guard let score = score(
                    previous.full, current.full,
                    direction: coarse.direction, offset: distance,
                    rowStep: 1, columnStep: 1
                ) else { continue }
                refined.append(Candidate(direction: coarse.direction, distance: distance, score: score))
            }
        }
        refined.sort { $0.score < $1.score }
        guard let best = refined.first, best.score < maximumAlignmentScore else { return .noOverlap }
        if let second = refined.dropFirst().first,
           second.direction != best.direction,
           abs(second.score - best.score) < 0.35 {
            return .ambiguous
        }
        if let second = refined.dropFirst().first,
           second.direction == best.direction,
           abs(second.distance - best.distance) > max(8, fullHeight / 20),
           abs(second.score - best.score) < 0.8 {
            return .ambiguous
        }
        return .aligned(best)
    }

    private static func difference(
        _ a: ScrollImageFingerprint.GrayPlane,
        _ b: ScrollImageFingerprint.GrayPlane,
        aOffset: Int,
        bOffset: Int,
        rowStep: Int
    ) -> Double {
        var total = 0.0
        var count = 0
        for y in stride(from: 0, to: a.height, by: rowStep) {
            let ai = (y + aOffset) * a.width
            let bi = (y + bOffset) * b.width
            for x in stride(from: 0, to: a.width, by: 2) {
                total += Double(abs(Int(a.bytes[ai + x]) - Int(b.bytes[bi + x])))
                count += 1
            }
        }
        return count == 0 ? .infinity : total / Double(count)
    }

    private static func score(
        _ a: ScrollImageFingerprint.GrayPlane,
        _ b: ScrollImageFingerprint.GrayPlane,
        direction: ScrollCaptureDirection,
        offset: Int,
        rowStep: Int,
        columnStep: Int
    ) -> Double? {
        let overlap = a.height - offset
        guard overlap > 0 else { return nil }
        var error = 0.0
        var textured = 0
        var closeMatches = 0
        for y in stride(from: 0, to: overlap, by: rowStep) {
            let aY = direction == .down ? y + offset : y
            let bY = direction == .down ? y : y + offset
            guard a.texturedRows[aY] || b.texturedRows[bY] else { continue }
            var rowError = 0
            var count = 0
            let aStart = aY * a.width
            let bStart = bY * b.width
            for x in stride(from: 0, to: a.width, by: columnStep) {
                rowError += abs(Int(a.bytes[aStart + x]) - Int(b.bytes[bStart + x]))
                count += 1
            }
            let normalized = Double(rowError) / Double(max(1, count))
            error += normalized
            textured += 1
            if normalized <= 22 { closeMatches += 1 }
        }
        guard textured >= 4 else { return nil }
        let coverage = Double(closeMatches) / Double(textured)
        guard coverage >= 0.32 else { return nil }
        let averageError = error / Double(textured)
        let overlapPenalty = Double(offset) / Double(a.height) * 4
        return averageError + overlapPenalty + (1 - coverage) * 14
    }
}

@MainActor
final class CaptureScrollingSession {
    private enum State: Equatable { case ready, collecting, finishing, completed, cancelled, failed }
    private let selection: CGRect
    private let captureFrame: @MainActor (Set<Int>) async throws -> CGImage
    private let onComplete: @MainActor (CGImage) async -> Void
    private let onCancel: @MainActor () -> Void
    private let onFailure: @MainActor (Error) -> Void
    private var state: State = .ready
    private var sequence = ScrollingCaptureSequence()
    private var hud: ScrollingCaptureHUD?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var debounceTask: Task<Void, Never>?
    private var captureTask: Task<Void, Never>?
    private var finishTask: Task<Void, Never>?
    private var capturePending = false
    private var lastEventTimestamp: TimeInterval = -1
    private var lastCaptureRequest = 0.0

    init(
        selection: CGRect,
        captureFrame: @escaping @MainActor (Set<Int>) async throws -> CGImage,
        onComplete: @escaping @MainActor (CGImage) async -> Void,
        onCancel: @escaping @MainActor () -> Void,
        onFailure: @escaping @MainActor (Error) -> Void
    ) {
        self.selection = selection.standardized
        self.captureFrame = captureFrame
        self.onComplete = onComplete
        self.onCancel = onCancel
        self.onFailure = onFailure
    }

    func present() {
        guard state == .ready else { return }
        let hud = ScrollingCaptureHUD(selection: selection)
        hud.onStart = { [weak self] in self?.start() }
        hud.onDone = { [weak self] in self?.finish() }
        hud.onCancel = { [weak self] in self?.cancel() }
        self.hud = hud
        hud.showReady()
    }

    private func start() {
        guard state == .ready else { return }
        state = .collecting
        hud?.showCollecting(message: BiscuitLocalization.string("Capturing the first view…"), sections: 0)
        installScrollMonitors()
        requestCapture()
    }

    private func installScrollMonitors() {
        guard globalMonitor == nil, localMonitor == nil else { return }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            let timestamp = event.timestamp
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.observeScroll(timestamp: timestamp, point: NSEvent.mouseLocation)
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.observeScroll(timestamp: event.timestamp, point: NSEvent.mouseLocation)
            return event
        }
    }

    private func removeScrollMonitors() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }

    private func observeScroll(timestamp: TimeInterval, point: CGPoint) {
        guard state == .collecting, selection.contains(point), hud?.contains(point) != true else { return }
        if abs(timestamp - lastEventTimestamp) < 0.0005 { return }
        lastEventTimestamp = timestamp
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastCaptureRequest >= 0.14 {
            lastCaptureRequest = now
            requestCapture()
        }
        debounceTask?.cancel()
        debounceTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 320_000_000) } catch { return }
            guard let self, self.state == .collecting else { return }
            self.lastCaptureRequest = ProcessInfo.processInfo.systemUptime
            self.requestCapture()
        }
    }

    private func requestCapture() {
        guard state == .collecting else { return }
        guard captureTask == nil else {
            capturePending = true
            return
        }
        captureTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.captureAndAppend()
            self.captureTask = nil
            if self.capturePending, self.state == .collecting {
                self.capturePending = false
                self.requestCapture()
            }
        }
    }

    private func captureAndAppend() async {
        guard state == .collecting || state == .finishing else { return }
        do {
            let excludedWindowNumbers = Set(hud.map { [$0.windowNumber] } ?? [])
            let image = try await captureFrame(excludedWindowNumbers)
            guard state == .collecting || state == .finishing else { return }
            let currentSequence = sequence
            let (updatedSequence, result) = try await Task.detached(priority: .userInitiated) {
                var updated = currentSequence
                let result = try updated.append(image)
                return (updated, result)
            }.value
            guard state == .collecting || state == .finishing else { return }
            sequence = updatedSequence
            if state == .collecting {
                switch result {
                case .firstFrame:
                    hud?.showCollecting(message: BiscuitLocalization.string("Scroll in the selection; choose Done when finished."), sections: 1)
                case .appended(let sections):
                    hud?.showCollecting(message: BiscuitLocalization.string("Image growing. Keep scrolling or choose Done."), sections: sections)
                case .unchanged:
                    if sequence.needsRecovery {
                        hud?.showCollecting(message: BiscuitLocalization.string("Back at the last captured view. Continue in the original direction."), sections: sequence.sectionCount)
                    } else {
                        hud?.showCollecting(message: BiscuitLocalization.string("No new content captured. Continue scrolling or choose Done."), sections: sequence.sectionCount)
                    }
                case .noOverlap:
                    hud?.showCollecting(message: BiscuitLocalization.string("Overlap missing. Return to captured content and use shorter scrolls."), sections: sequence.sectionCount)
                case .ambiguousOverlap:
                    hud?.showCollecting(message: BiscuitLocalization.string("Repeated content. Use a shorter scroll or cancel."), sections: sequence.sectionCount)
                case .reversedDirection:
                    hud?.showCollecting(message: BiscuitLocalization.string("Return to last view, then continue in the original direction."), sections: sequence.sectionCount)
                case .closed:
                    break
                }
            }
        } catch {
            fail(error)
        }
    }

    private func finish() {
        guard state == .collecting, finishTask == nil else { return }
        state = .finishing
        removeScrollMonitors()
        debounceTask?.cancel()
        debounceTask = nil
        capturePending = false
        hud?.showFinishing()
        finishTask = Task { @MainActor [weak self] in
            await self?.finishNow()
            self?.finishTask = nil
        }
    }

    private func finishNow() async {
        if let captureTask { await captureTask.value }
        guard state == .finishing else { return }
        // Take one final selected-area frame so the final scroll position is never omitted.
        await captureAndAppend()
        guard state == .finishing else { return }
        do {
            let currentSequence = sequence
            let image = try await Task.detached(priority: .userInitiated) {
                var finalSequence = currentSequence
                return try finalSequence.finish()
            }.value
            guard state == .finishing else { return }
            sequence.cancel()
            state = .completed
            closeHUD()
            await onComplete(image)
        } catch ScrollingCaptureError.noScrollRecorded {
            resumeAfterRejectedFinish(error: ScrollingCaptureError.noScrollRecorded)
        } catch ScrollingCaptureError.needsRecovery {
            resumeAfterRejectedFinish(error: ScrollingCaptureError.needsRecovery)
        } catch ScrollingCaptureError.noCapturedFrames {
            resumeAfterRejectedFinish(error: ScrollingCaptureError.noCapturedFrames)
        } catch {
            fail(error)
        }
    }

    private func resumeAfterRejectedFinish(error: Error) {
        guard state == .finishing else { return }
        state = .collecting
        hud?.showCollecting(message: error.localizedDescription, sections: sequence.sectionCount)
        installScrollMonitors()
    }

    private func cancel() {
        guard state == .ready || state == .collecting || state == .finishing else { return }
        state = .cancelled
        debounceTask?.cancel()
        captureTask?.cancel()
        finishTask?.cancel()
        debounceTask = nil
        captureTask = nil
        finishTask = nil
        capturePending = false
        removeScrollMonitors()
        sequence.cancel()
        closeHUD()
        onCancel()
    }

    private func fail(_ error: Error) {
        guard state == .collecting || state == .finishing else { return }
        state = .failed
        debounceTask?.cancel()
        captureTask?.cancel()
        finishTask?.cancel()
        debounceTask = nil
        captureTask = nil
        finishTask = nil
        removeScrollMonitors()
        sequence.cancel()
        closeHUD()
        onFailure(error)
    }

    private func closeHUD() {
        hud?.close()
        hud = nil
    }
}

@MainActor
private final class ScrollingCaptureHUD {
    private let panel: ScrollingCaptureHUDPanel
    private let message: NSTextField
    private let sectionCount: NSTextField
    private let startButton: NSButton
    private let doneButton: NSButton
    private let cancelButton: NSButton
    var onStart: (() -> Void)?
    var onDone: (() -> Void)?
    var onCancel: (() -> Void)?

    var windowNumber: Int { panel.windowNumber }

    init(selection: CGRect) {
        let size = NSSize(width: 640, height: 104)
        let frame = Self.place(size: size, outside: selection)
        panel = ScrollingCaptureHUDPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let visual = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        visual.material = .hudWindow
        visual.blendingMode = .behindWindow
        visual.state = .active
        visual.wantsLayer = true
        visual.layer?.cornerRadius = 13
        panel.contentView = visual

        message = NSTextField(labelWithString: "")
        message.frame = NSRect(x: 16, y: 38, width: 410, height: 58)
        message.font = .systemFont(ofSize: 13, weight: .semibold)
        message.lineBreakMode = .byWordWrapping
        message.cell?.wraps = true
        message.cell?.usesSingleLineMode = false
        visual.addSubview(message)

        sectionCount = NSTextField(labelWithString: "")
        sectionCount.frame = NSRect(x: 16, y: 13, width: 410, height: 18)
        sectionCount.font = .systemFont(ofSize: 11)
        sectionCount.textColor = .secondaryLabelColor
        sectionCount.lineBreakMode = .byTruncatingTail
        visual.addSubview(sectionCount)

        startButton = NSButton(title: BiscuitLocalization.string("Start Capture"), target: nil, action: nil)
        startButton.frame = NSRect(x: 438, y: 37, width: 102, height: 30)
        startButton.bezelStyle = .rounded
        startButton.setAccessibilityLabel(BiscuitLocalization.string("Start scrolling image capture"))
        doneButton = NSButton(title: BiscuitLocalization.string("Done"), target: nil, action: nil)
        doneButton.frame = NSRect(x: 438, y: 37, width: 70, height: 30)
        doneButton.bezelStyle = .rounded
        doneButton.setAccessibilityLabel(BiscuitLocalization.string("Finish scrolling image capture"))

        cancelButton = NSButton(title: BiscuitLocalization.string("Cancel"), target: nil, action: nil)
        cancelButton.frame = NSRect(x: 554, y: 37, width: 76, height: 30)
        cancelButton.bezelStyle = .rounded
        cancelButton.setAccessibilityLabel(BiscuitLocalization.string("Cancel scrolling image capture"))

        startButton.target = self
        startButton.action = #selector(startPressed)
        doneButton.target = self
        doneButton.action = #selector(donePressed)
        cancelButton.target = self
        cancelButton.action = #selector(cancelPressed)
        visual.addSubview(startButton)
        visual.addSubview(doneButton)
        visual.addSubview(cancelButton)
        doneButton.isHidden = true
        BiscuitLocalization.applyInterfaceDirection(to: panel)
    }

    func showReady() {
        message.stringValue = BiscuitLocalization.string("Selected area is ready")
        sectionCount.stringValue = BiscuitLocalization.string("Start, scroll normally, then choose Done.")
        _ = BiscuitPresentation.show(panel, key: false)
    }

    func showCollecting(message text: String, sections: Int) {
        message.stringValue = text
        sectionCount.stringValue = sections == 0
            ? BiscuitLocalization.string("Preparing the initial view…")
            : BiscuitLocalization.format("Captured sections: %d", arguments: [sections])
        startButton.isHidden = true
        doneButton.isHidden = false
        _ = BiscuitPresentation.show(panel, key: false)
    }

    func showFinishing() {
        message.stringValue = BiscuitLocalization.string("Finishing the long image…")
        sectionCount.stringValue = BiscuitLocalization.string("Checking overlap and capture limits.")
        startButton.isHidden = true
        doneButton.isHidden = true
        _ = BiscuitPresentation.show(panel, key: false)
    }

    func contains(_ point: CGPoint) -> Bool {
        panel.frame.contains(point)
    }

    func close() {
        panel.orderOut(nil)
        panel.close()
    }

    @objc private func startPressed() { onStart?() }
    @objc private func donePressed() { onDone?() }
    @objc private func cancelPressed() { onCancel?() }

    private static func place(size: NSSize, outside selection: CGRect) -> CGRect {
        let margin: CGFloat = 10
        let screens = NSScreen.screens.map(\.frame)
        let candidates = [
            CGRect(x: selection.minX, y: selection.maxY + margin, width: size.width, height: size.height),
            CGRect(x: selection.maxX - size.width, y: selection.maxY + margin, width: size.width, height: size.height),
            CGRect(x: selection.minX, y: selection.minY - size.height - margin, width: size.width, height: size.height),
            CGRect(x: selection.maxX - size.width, y: selection.minY - size.height - margin, width: size.width, height: size.height),
            CGRect(x: selection.minX - size.width - margin, y: selection.minY, width: size.width, height: size.height),
            CGRect(x: selection.maxX + margin, y: selection.minY, width: size.width, height: size.height)
        ]
        if let candidate = candidates.first(where: { candidate in
            screens.contains(where: { $0.contains(candidate) }) && !candidate.intersects(selection)
        }) { return candidate }

        let display = NSScreen.screens.first(where: { $0.frame.intersects(selection) }) ?? NSScreen.main
        let bounds = display?.frame ?? CGRect(origin: .zero, size: size)
        let x = min(max(bounds.minX + margin, selection.minX), max(bounds.minX + margin, bounds.maxX - size.width - margin))
        let y = min(max(bounds.minY + margin, selection.minY), max(bounds.minY + margin, bounds.maxY - size.height - margin))
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }
}

@MainActor
private final class ScrollingCaptureHUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

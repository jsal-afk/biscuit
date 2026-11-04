import AppKit
import CoreGraphics
import ScreenCaptureKit

@MainActor
final class CaptureController {
    private enum SelectionAction {
        case clipboardText
        case textResult((String) -> Void)
        case image
        case scrollingImage
    }

    private let onText: (String) -> Void
    private let onImage: (URL) -> Void
    private let onCopiedText: (String) -> Void
    private let onCopiedImage: () -> Void
    private let onEditImage: (URL) -> Void
    private var scrollingCaptureSession: CaptureScrollingSession?
    private var selectionTransitionPending = false
    private var captureOperationInProgress = false
    private var action: SelectionAction?
    private var selectionWindows: [CaptureSelectionWindow] = []
    private var selectionViews: [CaptureSelectionOverlayView] = []
    private var selectedRect: CGRect?
    private var thumbnailShelf: CaptureThumbnailShelf?
    private static let cornerThumbnailsKey = "capture.cornerThumbnails"
    private static let thumbnailAutoHideKey = "capture.cornerThumbnailsAutoHide"
    var cornerThumbnailsEnabled: Bool { BiscuitPreferences.defaults.bool(forKey: Self.cornerThumbnailsKey) }
    var cornerThumbnailsAutoHideEnabled: Bool { BiscuitPreferences.defaults.bool(forKey: Self.thumbnailAutoHideKey) }

    func setCornerThumbnailsEnabled(_ enabled: Bool) {
        BiscuitPreferences.defaults.set(enabled, forKey: Self.cornerThumbnailsKey)
        thumbnailShelf?.setEnabled(enabled)
    }

    func setCornerThumbnailsAutoHideEnabled(_ enabled: Bool) {
        BiscuitPreferences.defaults.set(enabled, forKey: Self.thumbnailAutoHideKey)
        thumbnailShelf?.setAutoHideEnabled(enabled)
    }

    init(
        onText: @escaping (String) -> Void,
        onImage: @escaping (URL) -> Void,
        onCopiedText: @escaping (String) -> Void,
        onCopiedImage: @escaping () -> Void,
        onEditImage: @escaping (URL) -> Void
    ) {
        BiscuitPreferences.defaults.register(defaults: [
            Self.cornerThumbnailsKey: true,
            Self.thumbnailAutoHideKey: false
        ])
        self.onText = onText
        self.onImage = onImage
        self.onCopiedText = onCopiedText
        self.onCopiedImage = onCopiedImage
        self.onEditImage = onEditImage
    }
    func removeImages(_ urls: [URL]) -> Set<URL> {
        thumbnailShelf?.removeImages(urls) ?? []
    }
    func performImageFileMutation(
        afterDragsFor url: URL,
        perform: @escaping @MainActor () -> Void
    ) {
        guard let thumbnailShelf else {
            perform()
            return
        }
        thumbnailShelf.performImageFileMutation(afterDragsFor: url, perform: perform)
    }

    func updateImageFileURL(from oldURL: URL, to newURL: URL, title: String) {
        thumbnailShelf?.updateImageFileURL(from: oldURL, to: newURL, title: title)
    }

    func selectText() {
        beginSelection(.clipboardText)
    }

    func selectImage() {
        beginSelection(.image)
    }

    func selectScrollingImage() {
        beginSelection(.scrollingImage)
    }
    func selectForText(_ completion: @escaping (String) -> Void) {
        beginSelection(.textResult(completion))
    }

    private func beginSelection(_ action: SelectionAction) {
        guard scrollingCaptureSession == nil, !selectionTransitionPending, !captureOperationInProgress else {
            presentError(CaptureFailure.captureAlreadyActive)
            completeWithEmptyText(action)
            return
        }
        guard selectionWindows.isEmpty else {
            completeWithEmptyText(action)
            return
        }
#if BISCUIT_SMOKE
        guard let screen = BiscuitPresentation.qaScreen() else {
            presentError(CaptureFailure.displayUnavailable)
            completeWithEmptyText(action)
            return
        }
        let screens = [screen]
#else
        let screens = NSScreen.screens
        guard !screens.isEmpty else {
            presentError(CaptureFailure.noDisplays)
            completeWithEmptyText(action)
            return
        }
#endif
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            presentScreenPermissionError()
            completeWithEmptyText(action)
            return
        }

        self.action = action
        selectedRect = nil
        for (index, screen) in screens.enumerated() {
#if BISCUIT_SMOKE
            let selectionFrame = screen.visibleFrame
#else
            let selectionFrame = screen.frame
#endif
            let view = CaptureSelectionOverlayView(
                frame: NSRect(origin: .zero, size: selectionFrame.size),
                screenFrame: selectionFrame,
                showsHint: index == 0,
                onChange: { [weak self] rect in self?.updateSelection(rect) },
                onFinish: { [weak self] rect in self?.finishSelection(rect) },
                onCancel: { [weak self] in self?.cancelSelection() }
            )
            let window = CaptureSelectionWindow(contentRect: selectionFrame, styleMask: .borderless, backing: .buffered, defer: false)
            window.level = .screenSaver
            window.backgroundColor = .clear
            window.isOpaque = false
            window.hasShadow = false
            window.ignoresMouseEvents = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.isReleasedWhenClosed = false
            window.contentView = view
            window.initialFirstResponder = view
            window.onCancel = { [weak self] in self?.cancelSelection() }
            selectionViews.append(view)
            selectionWindows.append(window)
        }
        for window in selectionWindows { _ = BiscuitPresentation.show(window, key: false) }
        _ = BiscuitPresentation.show(selectionWindows.first)
    }

    private func updateSelection(_ rect: CGRect) {
        selectedRect = rect.standardized
        for view in selectionViews {
            view.selectionRect = selectedRect
            view.needsDisplay = true
        }
    }

    private func cancelSelection() {
        action = nil
        closeSelectionWindows()
    }

    private func finishSelection(_ rect: CGRect) {
        let completedAction = action
        action = nil
        closeSelectionWindows()
        guard let completedAction else { return }
        let area = rect.standardized
        guard area.width >= 3, area.height >= 3 else {
            presentError(CaptureFailure.selectionTooSmall)
            completeWithEmptyText(completedAction)
            return
        }
        selectionTransitionPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self else { return }
            self.selectionTransitionPending = false
            switch completedAction {
            case .clipboardText:
                self.recognizeText(in: area, clipboard: true, completion: nil)
            case .textResult(let completion):
                self.recognizeText(in: area, clipboard: false, completion: completion)
            case .image:
                self.captureImage(in: area)
            case .scrollingImage:
                self.beginScrollingCapture(in: area)
            }
        }
    }
    private func beginScrollingCapture(in area: CGRect) {
        guard scrollingCaptureSession == nil else { return }
        let startedAt = ProcessInfo.processInfo.systemUptime
        let session = CaptureScrollingSession(
            selection: area,
            captureFrame: { windowNumbers in
                try await CaptureScreenImage.capture(area, excludingWindowNumbers: windowNumbers)
            },
            onComplete: { [weak self] image in
                guard let self else { return }
                await self.storeCapturedImage(
                    image,
                    measurement: ImageMeasurementContext(
                        area: area, startedAt: startedAt, captureMilliseconds: nil, isStitchedOutput: true
                    )
                ) { _ in }
                self.scrollingCaptureSession = nil
            },
            onCancel: { [weak self] in
                guard let self else { return }
                self.recordImageMeasurement(
                    area: area, startedAt: startedAt, captureMilliseconds: nil, image: nil, outcome: .cancelled
                )
                self.scrollingCaptureSession = nil
            },
            onFailure: { [weak self] error in
                guard let self else { return }
                self.recordImageMeasurement(
                    area: area, startedAt: startedAt, captureMilliseconds: nil, image: nil, outcome: .failed
                )
                self.scrollingCaptureSession = nil
                self.presentError(error)
            }
        )
        scrollingCaptureSession = session
        session.present()
    }

    private func closeSelectionWindows() {
        for window in selectionWindows {
            window.orderOut(nil)
            window.close()
        }
        selectionWindows.removeAll()
        selectionViews.removeAll()
        selectedRect = nil
    }

    private func recognizeText(in rect: CGRect, clipboard: Bool, completion: ((String) -> Void)?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard self.scrollingCaptureSession == nil,
                  !self.selectionTransitionPending,
                  !self.captureOperationInProgress,
                  self.selectionWindows.isEmpty else {
                self.presentError(CaptureFailure.captureAlreadyActive)
                completion?("")
                return
            }
            self.captureOperationInProgress = true
            defer { self.captureOperationInProgress = false }
            let startedAt = ProcessInfo.processInfo.systemUptime
            var captureMilliseconds: Double?
            var image: CGImage?
            var result: CaptureOCRResult?
            do {
                let captureStartedAt = ProcessInfo.processInfo.systemUptime
                do {
                    image = try await CaptureScreenImage.capture(rect)
                } catch {
                    captureMilliseconds = Self.elapsedMilliseconds(since: captureStartedAt)
                    throw error
                }
                captureMilliseconds = Self.elapsedMilliseconds(since: captureStartedAt)
                guard let image else { throw CaptureFailure.imageEncoding }
                result = try await Task.detached(priority: .userInitiated) {
                    try CaptureOCR.recognize(in: image)
                }.value
                guard let result,
                      !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    self.recordTextMeasurement(
                        area: rect, startedAt: startedAt, captureMilliseconds: captureMilliseconds,
                        image: image, result: result, outcome: .failed
                    )
                    self.presentError(CaptureFailure.noText)
                    completion?("")
                    return
                }
                if clipboard {
                    NSPasteboard.general.clearContents()
                    let copied = NSPasteboard.general.setString(result.text, forType: .string)
                    if !copied {
                        presentError(CaptureFailure.pasteboardWriteFailed)
                    }
                    onText(result.text)
                    if copied { onCopiedText(result.text) }
                }
                self.recordTextMeasurement(
                    area: rect, startedAt: startedAt, captureMilliseconds: captureMilliseconds,
                    image: image, result: result, outcome: .succeeded
                )
                completion?(result.text)
            } catch {
                self.recordTextMeasurement(
                    area: rect, startedAt: startedAt, captureMilliseconds: captureMilliseconds,
                    image: image, result: result, outcome: .failed
                )
                presentError(error)
                completion?("")
            }
        }
    }

    func captureImage(in rect: CGRect) {
        captureImage(in: rect) { _ in }
    }

    func captureImage(in rect: CGRect, completion: @escaping (Result<URL, Error>) -> Void) {
        Task { @MainActor [self] in
            await captureImageNow(in: rect, completion: completion)
        }
    }

    private struct ImageMeasurementContext {
        let area: CGRect
        let startedAt: TimeInterval
        let captureMilliseconds: Double?
        let isStitchedOutput: Bool
    }

    private func captureImageNow(in rect: CGRect, completion: (Result<URL, Error>) -> Void) async {
        let area = rect.standardized
        guard scrollingCaptureSession == nil,
              !selectionTransitionPending,
              !captureOperationInProgress,
              selectionWindows.isEmpty else {
            let error = CaptureFailure.captureAlreadyActive
            presentError(error)
            completion(.failure(error))
            return
        }
        guard area.width >= 3, area.height >= 3 else {
            let error = CaptureFailure.selectionTooSmall
            presentError(error)
            completion(.failure(error))
            return
        }
        captureOperationInProgress = true
        defer { captureOperationInProgress = false }
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            presentScreenPermissionError()
            completion(.failure(CaptureFailure.permissionDenied))
            return
        }
        let startedAt = ProcessInfo.processInfo.systemUptime
        let captureStartedAt = ProcessInfo.processInfo.systemUptime
        var captureMilliseconds: Double?
        do {
            let image: CGImage
            do {
                image = try await CaptureScreenImage.capture(area)
            } catch {
                captureMilliseconds = Self.elapsedMilliseconds(since: captureStartedAt)
                throw error
            }
            captureMilliseconds = Self.elapsedMilliseconds(since: captureStartedAt)
            await storeCapturedImage(
                image,
                measurement: ImageMeasurementContext(
                    area: area, startedAt: startedAt, captureMilliseconds: captureMilliseconds,
                    isStitchedOutput: false
                ),
                completion: completion
            )
        } catch {
            recordImageMeasurement(
                area: area, startedAt: startedAt, captureMilliseconds: captureMilliseconds,
                image: nil, outcome: .failed
            )
            presentError(error)
            completion(.failure(error))
        }
    }

    private func storeCapturedImage(
        _ image: CGImage,
        measurement: ImageMeasurementContext? = nil,
        completion: (Result<URL, Error>) -> Void
    ) async {
        do {
            let (data, url) = try await Task.detached(priority: .userInitiated) {
                let data = try CaptureScreenImage.pngData(from: image)
                let url = try CaptureScreenImage.store(data)
                return (data, url)
            }.value
            NSPasteboard.general.clearContents()
            let copied = NSPasteboard.general.setData(data, forType: .png)
            if !copied {
                presentError(CaptureFailure.pasteboardWriteFailed)
            }
            if cornerThumbnailsEnabled {
                if thumbnailShelf == nil {
                    thumbnailShelf = CaptureThumbnailShelf(
                        onText: { [weak self] text in self?.onText(text) },
                        onCopiedText: { [weak self] text in self?.onCopiedText(text) },
                        onCopiedImage: { [weak self] in self?.onCopiedImage() },
                        onEditImage: { [weak self] url in self?.onEditImage(url) },
                        autoHideEnabled: cornerThumbnailsAutoHideEnabled
                    )
                }
                thumbnailShelf?.append(image: image, fileURL: url)
            }
            onImage(url)
            if copied { onCopiedImage() }
            if let measurement {
                recordImageMeasurement(
                    area: measurement.area, startedAt: measurement.startedAt,
                    captureMilliseconds: measurement.captureMilliseconds, image: image,
                    outcome: .succeeded, isStitchedOutput: measurement.isStitchedOutput
                )
            }
            completion(.success(url))
        } catch {
            if let measurement {
                recordImageMeasurement(
                    area: measurement.area, startedAt: measurement.startedAt,
                    captureMilliseconds: measurement.captureMilliseconds, image: image,
                    outcome: .failed, isStitchedOutput: measurement.isStitchedOutput
                )
            }
            presentError(error)
            completion(.failure(error))
        }
    }

    private static func elapsedMilliseconds(since start: TimeInterval) -> Double {
        max(0, ProcessInfo.processInfo.systemUptime - start) * 1_000
    }

    func recordImageMeasurement(
        area: CGRect,
        startedAt: TimeInterval,
        captureMilliseconds: Double?,
        image: CGImage?,
        outcome: MeasurementEntry.Outcome,
        isStitchedOutput: Bool = false
    ) {
        let widthPixels = image?.width
        let heightPixels = image?.height
        let scale: Double?
        if let widthPixels, let heightPixels, area.width > 0, area.height > 0 {
            let horizontalScale = Double(widthPixels) / Double(area.width)
            // A stitched output extends vertically; its unchanged viewport width retains the backing scale.
            scale = isStitchedOutput
                ? horizontalScale
                : max(horizontalScale, Double(heightPixels) / Double(area.height))
        } else {
            scale = nil
        }
        MeasurementLogger.record(MeasurementEntry(
            operation: .imageCapture,
            outcome: outcome,
            widthPixels: widthPixels,
            heightPixels: heightPixels,
            widthPoints: Double(area.width),
            heightPoints: Double(area.height),
            scale: scale,
            captureMilliseconds: captureMilliseconds,
            endToEndMilliseconds: Self.elapsedMilliseconds(since: startedAt)
        ))
    }

    func recordTextMeasurement(
        area: CGRect,
        startedAt: TimeInterval,
        captureMilliseconds: Double?,
        image: CGImage?,
        result: CaptureOCRResult?,
        outcome: MeasurementEntry.Outcome
    ) {
        let widthPixels = image?.width
        let heightPixels = image?.height
        let scale: Double?
        if let widthPixels, let heightPixels, area.width > 0, area.height > 0 {
            scale = max(Double(widthPixels) / Double(area.width), Double(heightPixels) / Double(area.height))
        } else {
            scale = nil
        }
        MeasurementLogger.record(MeasurementEntry(
            operation: .textCapture,
            outcome: outcome,
            widthPixels: widthPixels,
            heightPixels: heightPixels,
            widthPoints: Double(area.width),
            heightPoints: Double(area.height),
            scale: scale,
            captureMilliseconds: captureMilliseconds,
            ocrMilliseconds: result?.recognitionMilliseconds,
            tableMilliseconds: result?.tableMilliseconds,
            endToEndMilliseconds: Self.elapsedMilliseconds(since: startedAt),
            boxCount: result?.boxCount,
            characterCount: result?.characterCount,
            tableCount: result?.tableCount,
            tableRowCount: result?.tableRowCount,
            tableColumnCount: result?.tableColumnCount,
            tableCellCount: result?.tableCellCount,
            averageConfidence: result?.averageConfidence,
            confidenceObservationCount: result?.confidenceObservationCount,
            recognitionEngine: result?.recognitionEngine,
            recognitionVariant: result?.recognitionVariant,
            recognitionLanguages: result?.recognitionLanguages,
            languageCorrectionEnabled: result?.languageCorrectionEnabled,
            automaticLanguageDetectionEnabled: result?.automaticLanguageDetectionEnabled
        ))
    }

    private func completeWithEmptyText(_ action: SelectionAction) {
        if case .textResult(let completion) = action { completion("") }
    }

    private func presentError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = BiscuitLocalization.string("Capture failed")
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: BiscuitLocalization.string("OK"))
        BiscuitLocalization.applyInterfaceDirection(to: alert)
        _ = BiscuitPresentation.runModal(alert)
    }

    private func presentScreenPermissionError() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = BiscuitLocalization.string("Screen Recording access is required")
        alert.informativeText = BiscuitLocalization.string("Allow biscuit in System Settings → Privacy & Security → Screen Recording, then try the capture again.")
        alert.addButton(withTitle: BiscuitLocalization.string("Open System Settings"))
        alert.addButton(withTitle: BiscuitLocalization.string("Cancel"))
        BiscuitLocalization.applyInterfaceDirection(to: alert)
        if BiscuitPresentation.runModal(alert) == .alertFirstButtonReturn,
           let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(settingsURL)
        }
    }
}

enum CaptureFailure: LocalizedError {
    case noDisplays
    case selectionTooSmall
    case noText
    case pasteboardWriteFailed
    case permissionDenied
    case displayUnavailable
    case captureAlreadyActive
    case captureControlsUnavailable
    case screenCaptureKitUnavailable
    case imageTooLarge
    case imageEncoding

    var errorDescription: String? {
        switch self {
        case .noDisplays: return BiscuitLocalization.string("No active display is available for capture.")
        case .selectionTooSmall: return BiscuitLocalization.string("Select an area at least 3 points wide and high.")
        case .noText: return BiscuitLocalization.string("No readable text was found in the selected area.")
        case .pasteboardWriteFailed: return BiscuitLocalization.string("The image or text could not be written to the pasteboard.")
        case .permissionDenied: return BiscuitLocalization.string("Screen Recording access was not granted. Allow biscuit in System Settings and relaunch if macOS requests it.")
        case .displayUnavailable: return BiscuitLocalization.string("The selected display area could not be captured. Check Screen Recording access and try again.")
        case .captureAlreadyActive: return BiscuitLocalization.string("Another capture is active or finishing. Use its controls, or wait for it to complete, before starting a new one.")
        case .captureControlsUnavailable: return BiscuitLocalization.string("The scrolling capture controls could not be safely excluded. Cancel this session; no image was saved.")
        case .screenCaptureKitUnavailable: return BiscuitLocalization.string("Selected-area capture requires macOS 14 or later.")
        case .imageTooLarge: return BiscuitLocalization.string("The selected area is too large to capture safely. Select a smaller area.")
        case .imageEncoding: return BiscuitLocalization.string("The selected area could not be encoded as a PNG image.")
        }
    }
}

enum CaptureScreenImage {
    struct DisplaySnapshot {
        let region: CGRect
        let image: CGImage
    }

    @MainActor
    static func capture(_ selection: CGRect, excludingWindowNumbers: Set<Int> = []) async throws -> CGImage {
        guard #available(macOS 14.0, *) else { throw CaptureFailure.screenCaptureKitUnavailable }
        guard selection.minX.isFinite, selection.minY.isFinite, selection.maxX.isFinite, selection.maxY.isFinite,
              selection.width.isFinite, selection.height.isFinite else { throw CaptureFailure.selectionTooSmall }
        guard CGPreflightScreenCaptureAccess() else { throw CaptureFailure.permissionDenied }
        let screens = NSScreen.screens
        guard !screens.isEmpty else { throw CaptureFailure.noDisplays }
        let shareable = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let excludedWindowIDs = Set(excludingWindowNumbers.compactMap { CGWindowID(exactly: $0) })
        guard excludedWindowIDs.count == excludingWindowNumbers.count else {
            throw CaptureFailure.captureControlsUnavailable
        }
        let excludedWindows = shareable.windows.filter { excludedWindowIDs.contains($0.windowID) }
        guard Set(excludedWindows.map(\.windowID)).isSuperset(of: excludedWindowIDs) else {
            throw CaptureFailure.captureControlsUnavailable
        }
        var sources: [(screen: NSScreen, filter: SCContentFilter, scale: CGFloat, region: CGRect)] = []
        var maximumScale: CGFloat = 1

        for screen in screens {
            let region = selection.intersection(screen.frame)
            guard !region.isNull, !region.isEmpty else { continue }
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let display = shareable.displays.first(where: { $0.displayID == CGDirectDisplayID(number.uint32Value) }) else {
                throw CaptureFailure.displayUnavailable
            }
            let filter = SCContentFilter(display: display, excludingWindows: excludedWindows)
            let displayScale = CGFloat(filter.pointPixelScale)
            guard displayScale.isFinite, displayScale > 0 else { throw CaptureFailure.displayUnavailable }
            maximumScale = max(maximumScale, displayScale)
            sources.append((screen, filter, displayScale, region))
        }
        guard !sources.isEmpty else { throw CaptureFailure.displayUnavailable }
        try validateSize(selection, scale: maximumScale)

        var snapshots: [DisplaySnapshot] = []
        for source in sources {
            let scale = source.scale
            let configuration = SCStreamConfiguration()
            configuration.sourceRect = CGRect(
                x: source.region.minX - source.screen.frame.minX,
                y: source.screen.frame.maxY - source.region.maxY,
                width: source.region.width,
                height: source.region.height
            )
            configuration.width = Int(ceil(source.region.width * scale))
            configuration.height = Int(ceil(source.region.height * scale))
            configuration.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: source.filter, configuration: configuration)
            snapshots.append(DisplaySnapshot(region: source.region, image: image))
        }
        if snapshots.count == 1, snapshots[0].region == selection { return snapshots[0].image }
        return try compose(selection, snapshots: snapshots, scale: maximumScale)
    }

    private static func validateSize(_ selection: CGRect, scale: CGFloat) throws {
        let widthValue = ceil(selection.width * scale)
        let heightValue = ceil(selection.height * scale)
        guard widthValue.isFinite, heightValue.isFinite, widthValue > 0, heightValue > 0,
              widthValue <= 32_768, heightValue <= 32_768 else { throw CaptureFailure.imageTooLarge }
        let width = Int(widthValue)
        let height = Int(heightValue)
        guard width <= 80_000_000 / height else { throw CaptureFailure.imageTooLarge }
    }

    static func compose(_ selection: CGRect, snapshots: [DisplaySnapshot], scale: CGFloat) throws -> CGImage {
        try validateSize(selection, scale: scale)
        let pixelWidth = Int(ceil(selection.width * scale))
        let pixelHeight = Int(ceil(selection.height * scale))
        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: pixelWidth * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw CaptureFailure.imageEncoding }
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(pixelWidth), height: CGFloat(pixelHeight)))
        context.interpolationQuality = .high
        for snapshot in snapshots {
            context.draw(snapshot.image, in: CGRect(
                x: (snapshot.region.minX - selection.minX) * scale,
                y: (snapshot.region.minY - selection.minY) * scale,
                width: snapshot.region.width * scale,
                height: snapshot.region.height * scale
            ))
        }
        guard let image = context.makeImage() else { throw CaptureFailure.imageEncoding }
        return image
    }

    static func pngData(from image: CGImage) throws -> Data {
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw CaptureFailure.imageEncoding
        }
        return data
    }

    static func store(_ data: Data) throws -> URL {
        let manager = FileManager.default
        let base: URL
        if let override = ProcessInfo.processInfo.environment["BISCUIT_DATA_DIR"], !override.isEmpty {
            base = URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        } else {
            base = try manager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("biscuit", isDirectory: true)
        }
        let directory = base.appendingPathComponent("library-images", isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("capture-\(UUID().uuidString).png", isDirectory: false)
        try data.write(to: destination, options: .atomic)
        return destination
    }
}

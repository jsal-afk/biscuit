import AppKit

@MainActor
final class CaptureThumbnailShelf {
    private let panel: NSPanel
    private let scrollView: NSScrollView
    private let documentView: CaptureThumbnailDocumentView
    private let previewPanel: NSPanel
    private let previewImageView: NSImageView
    private let onText: (String) -> Void
    private let onCopiedText: (String) -> Void
    private let onCopiedImage: () -> Void
    private let onEditImage: (URL) -> Void
    private let pasteboard: NSPasteboard
    private var rows: [CaptureThumbnailView] = []
    private var imageFileMutationLeases = ImageFileMutationLeases()
    private var previewedURL: URL?
    private var autoHideEnabled: Bool
    private var autoHideTimer: CaptureThumbnailAutoHideTimer?
    private var hoveredThumbnailURLs = Set<URL>()
    private var activeShelfDragCount = 0
    private var isEnabled = true
    private let panelWidth: CGFloat = 190
    private let shelfLimit = 12
    private let rowHeight: CGFloat = 84

    init(
        onText: @escaping (String) -> Void,
        onCopiedText: @escaping (String) -> Void,
        onCopiedImage: @escaping () -> Void,
        onEditImage: @escaping (URL) -> Void,
        autoHideEnabled: Bool = false,
        pasteboard: NSPasteboard = .general
    ) {
        let width: CGFloat = 190
        let content = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
        content.autoresizingMask = [.width, .height]
        content.material = .hudWindow
        content.state = .active
        content.blendingMode = .behindWindow

        let shelfPanel = NSPanel(contentRect: content.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let shelfScrollView = NSScrollView(frame: content.bounds.insetBy(dx: 7, dy: 7))
        let shelfDocumentView = CaptureThumbnailDocumentView(frame: NSRect(x: 0, y: 0, width: width - 14, height: 0))
        shelfScrollView.documentView = shelfDocumentView
        shelfScrollView.drawsBackground = false
        shelfScrollView.hasVerticalScroller = true
        shelfScrollView.hasHorizontalScroller = false
        shelfScrollView.autohidesScrollers = true
        shelfScrollView.borderType = .noBorder
        shelfScrollView.autoresizingMask = [.width, .height]
        content.addSubview(shelfScrollView)

        let imageView = NSImageView(frame: NSRect(x: 10, y: 10, width: 340, height: 250))
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        let previewContent = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 360, height: 270))
        previewContent.autoresizingMask = [.width, .height]
        previewContent.material = .hudWindow
        previewContent.state = .active
        previewContent.addSubview(imageView)
        let shelfPreviewPanel = NSPanel(contentRect: previewContent.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)

        panel = shelfPanel
        scrollView = shelfScrollView
        documentView = shelfDocumentView
        previewPanel = shelfPreviewPanel
        previewImageView = imageView
        self.onText = onText
        self.onCopiedText = onCopiedText
        self.onCopiedImage = onCopiedImage
        self.onEditImage = onEditImage
        self.pasteboard = pasteboard
        self.autoHideEnabled = autoHideEnabled
        self.autoHideTimer = CaptureThumbnailAutoHideTimer { [weak self] in self?.autoHideShelf() }

        shelfPanel.level = .floating
        shelfPanel.hidesOnDeactivate = false
        shelfPanel.isOpaque = false
        shelfPanel.backgroundColor = .clear
        shelfPanel.hasShadow = true
        shelfPanel.ignoresMouseEvents = false
        shelfPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        shelfPanel.isReleasedWhenClosed = false
        shelfPanel.contentView = content
        BiscuitLocalization.applyInterfaceDirection(to: shelfPanel)

        shelfPreviewPanel.level = .floating
        shelfPreviewPanel.hidesOnDeactivate = false
        shelfPreviewPanel.isOpaque = false
        shelfPreviewPanel.backgroundColor = .clear
        shelfPreviewPanel.hasShadow = true
        shelfPreviewPanel.ignoresMouseEvents = true
        shelfPreviewPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        shelfPreviewPanel.contentView = previewContent
        BiscuitLocalization.applyInterfaceDirection(to: shelfPreviewPanel)
    }
    func setAutoHideEnabled(_ enabled: Bool) {
        guard autoHideEnabled != enabled else { return }
        autoHideEnabled = enabled
        updateAutoHideTimer()
    }
    func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        isEnabled = enabled
        if enabled {
            updateLayout()
        } else {
            autoHideTimer?.cancel()
            hoveredThumbnailURLs.removeAll()
            panel.orderOut(nil)
            hidePreview()
        }
    }

    func append(image: CGImage, fileURL: URL) {
        let thumbnail = Self.makeThumbnail(image)
        if thumbnail == nil { showError(CaptureFailure.imageEncoding, title: BiscuitLocalization.string("Thumbnail preview unavailable")) }
        let row = CaptureThumbnailView(
            frame: NSRect(x: 7, y: 0, width: panelWidth - 28, height: rowHeight - 8),
            image: thumbnail ?? NSImage(size: NSSize(width: 1, height: 1)),
            fileURL: fileURL,
            onHover: { [weak self] image, url in
                self?.enterThumbnail(url)
                self?.showPreview(image, fileURL: url)
            },
            onExit: { [weak self] url in self?.exitThumbnail(url) },
            onClick: { [weak self] url in self?.copyImage(from: url) },
            onCopyText: { [weak self] url in self?.copyText(from: url) },
            onEditImage: { [weak self] url in self?.onEditImage(url) },
            onUnavailable: { [weak self] url, error in self?.reportUnavailable(url, error: error) },
            onClose: { [weak self] url in self?.closeThumbnail(url) },
            onDragStarted: { [weak self] url in self?.beginDrag(for: url) },
            onDragEnded: { [weak self] url in self?.endDrag(for: url) }
        )
        rows.insert(row, at: 0)
        if rows.count > shelfLimit {
            let oldest = rows.removeLast()
            hoveredThumbnailURLs.remove(oldest.fileURL.standardizedFileURL)
            oldest.removeFromSuperview()
        }
        updateLayout()
    }
    func removeImages(_ urls: [URL]) -> Set<URL> {
        let removed = Set(urls.map(\.standardizedFileURL))
        hoveredThumbnailURLs.subtract(removed)
        guard !removed.isEmpty else { return [] }
        rows.removeAll { row in
            guard removed.contains(row.fileURL.standardizedFileURL) else { return false }
            row.removeFromSuperview()
            return true
        }
        if let previewedURL, removed.contains(previewedURL.standardizedFileURL) {
            hidePreview()
        }
        let leased = imageFileMutationLeases.removeImages(Array(removed))
        updateLayout()
        return leased
    }

    func performImageFileMutation(afterDragsFor url: URL, perform: @escaping @MainActor () -> Void) {
        switch imageFileMutationLeases.scheduleMutation(afterDragsFor: url, perform: perform) {
        case .immediate:
            perform()
        case .deferred, .discarded:
            break
        }
    }

    func updateImageFileURL(from oldURL: URL, to newURL: URL, title: String) {
        let oldKey = oldURL.standardizedFileURL
        rows.first(where: { $0.fileURL.standardizedFileURL == oldKey })?
            .updateImageFileURL(newURL, title: title)
        if hoveredThumbnailURLs.remove(oldKey) != nil {
            hoveredThumbnailURLs.insert(newURL.standardizedFileURL)
        }
        if previewedURL?.standardizedFileURL == oldKey {
            previewedURL = newURL.standardizedFileURL
        }
    }

    private func beginDrag(for url: URL) {
        activeShelfDragCount += 1
        autoHideTimer?.cancel()
        imageFileMutationLeases.beginDrag(for: url)
    }

    private func endDrag(for url: URL) {
        defer {
            if activeShelfDragCount > 0 { activeShelfDragCount -= 1 }
            updateAutoHideTimer()
        }
        switch imageFileMutationLeases.endDrag(for: url) {
        case .none:
            return
        case .delete(let key):
            do {
                try FileManager.default.removeItem(at: key)
            } catch {
                if FileManager.default.fileExists(atPath: key.path) {
                    showError(error, title: BiscuitLocalization.string("Could not remove expired capture"))
                }
            }
        case .perform(let mutations):
            mutations.forEach { $0() }
        }
    }

    #if BISCUIT_SMOKE
    func smokeBeginDragLease(for url: URL) { beginDrag(for: url) }
    func smokeEndDragLease(for url: URL) { endDrag(for: url) }
    #endif

    private func hidePreview() {
        previewPanel.orderOut(nil)
        previewedURL = nil
    }
    private func enterThumbnail(_ url: URL) {
        hoveredThumbnailURLs.insert(url.standardizedFileURL)
        autoHideTimer?.cancel()
    }

    private func exitThumbnail(_ url: URL) {
        hoveredThumbnailURLs.remove(url.standardizedFileURL)
        hidePreview()
        updateAutoHideTimer()
    }

    private func updateAutoHideTimer() {
        guard autoHideEnabled, isEnabled, panel.isVisible, !rows.isEmpty,
              hoveredThumbnailURLs.isEmpty, activeShelfDragCount == 0 else {
            autoHideTimer?.cancel()
            return
        }
        autoHideTimer?.reset()
    }

    private func autoHideShelf() {
        guard autoHideEnabled, isEnabled, !rows.isEmpty else { return }
        guard hoveredThumbnailURLs.isEmpty, activeShelfDragCount == 0 else {
            updateAutoHideTimer()
            return
        }
        panel.orderOut(nil)
        hidePreview()
    }


    private func updateLayout() {
        guard isEnabled else {
            autoHideTimer?.cancel()
            hoveredThumbnailURLs.removeAll()
            panel.orderOut(nil)
            hidePreview()
            return
        }
        for (index, row) in rows.enumerated() {
            row.frame = NSRect(x: 7, y: 6 + CGFloat(index) * rowHeight, width: panelWidth - 28, height: rowHeight - 8)
            if row.superview == nil { documentView.addSubview(row) }
        }
        documentView.frame = NSRect(x: 0, y: 0, width: panelWidth - 14, height: CGFloat(rows.count) * rowHeight + 6)
        BiscuitLocalization.applyInterfaceDirection(to: panel)
        documentView.needsDisplay = true
        guard !rows.isEmpty else {
            autoHideTimer?.cancel()
            hoveredThumbnailURLs.removeAll()
            panel.orderOut(nil)
            hidePreview()
            return
        }
        let visibleFrame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero
        let height = CGFloat(min(rows.count, 4)) * rowHeight + 14
        BiscuitPresentation.setFrame(NSRect(x: visibleFrame.maxX - panelWidth - 14, y: visibleFrame.minY + 14, width: panelWidth, height: height), for: panel, display: true)
        guard BiscuitPresentation.show(panel, key: false) else { return }
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        updateAutoHideTimer()
    }
    private func closeThumbnail(_ url: URL) {
        guard let index = rows.firstIndex(where: { $0.fileURL == url }) else { return }
        rows.remove(at: index).removeFromSuperview()
        hoveredThumbnailURLs.remove(url.standardizedFileURL)
        hidePreview()
        updateLayout()
    }


    private func copyImage(from url: URL) {
        do {
            let data = try Data(contentsOf: url)
            pasteboard.clearContents()
            guard pasteboard.setData(data, forType: .png) else {
                throw CaptureFailure.pasteboardWriteFailed
            }
            onCopiedImage()
        } catch {
            if !FileManager.default.fileExists(atPath: url.path) {
                reportUnavailable(url, error: error)
            } else {
                showError(error, title: BiscuitLocalization.string("Could not copy capture"))
            }
        }
    }

    private func copyText(from url: URL) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let text = try await Task.detached(priority: .userInitiated) {
                    try CaptureOCR.recognizeText(in: url)
                }.value
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    showError(CaptureFailure.noText, title: BiscuitLocalization.string("No readable text"))
                    return
                }
                pasteboard.clearContents()
                guard pasteboard.setString(text, forType: .string) else {
                    showError(CaptureFailure.pasteboardWriteFailed, title: BiscuitLocalization.string("Could not copy text"))
                    return
                }
                onText(text)
                onCopiedText(text)
            } catch {
                if !FileManager.default.fileExists(atPath: url.path) {
                    reportUnavailable(url, error: error)
                } else {
                    showError(error, title: BiscuitLocalization.string("Text recognition failed"))
                }
            }
        }
    }

    private func showPreview(_ image: NSImage, fileURL: URL) {
        guard FileManager.default.isReadableFile(atPath: fileURL.path) else {
            reportUnavailable(fileURL, error: Self.unavailableFileError(fileURL))
            return
        }
        previewImageView.image = image
        previewedURL = fileURL.standardizedFileURL
        let size = previewPanel.frame.size
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        var x = pointer.x + 18
        var y = pointer.y + 18
        if x + size.width > visible.maxX { x = pointer.x - size.width - 18 }
        if y + size.height > visible.maxY { y = visible.maxY - size.height }
        x = max(visible.minX, min(x, visible.maxX - size.width))
        y = max(visible.minY, min(y, visible.maxY - size.height))
        BiscuitPresentation.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: previewPanel.frame.size), for: previewPanel, display: false)
        guard BiscuitPresentation.show(previewPanel, key: false) else { return }
    }

    private func reportUnavailable(_ url: URL, error: Error) {
        if !FileManager.default.fileExists(atPath: url.path) {
            rows.removeAll { row in
                guard row.fileURL == url else { return false }
                row.removeFromSuperview()
                return true
            }
            hoveredThumbnailURLs.remove(url.standardizedFileURL)
            updateLayout()
        }
        hidePreview()
        showError(error, title: BiscuitLocalization.string("Saved capture unavailable"))
    }

    private func showError(_ error: Error, title: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: BiscuitLocalization.string("OK"))
        BiscuitLocalization.applyInterfaceDirection(to: alert)
        _ = BiscuitPresentation.runModal(alert)
    }

    private static func unavailableFileError(_ url: URL) -> Error {
        NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError, userInfo: [
            NSLocalizedDescriptionKey: BiscuitLocalization.format("The saved image is no longer available: %1$@", arguments: [url.lastPathComponent])
        ])
    }


    private static func makeThumbnail(_ image: CGImage) -> NSImage? {
        let maximumSide: CGFloat = 440
        let factor = min(1, maximumSide / CGFloat(max(image.width, image.height)))
        let width = max(1, Int((CGFloat(image.width) * factor).rounded(.up)))
        let height = max(1, Int((CGFloat(image.height) * factor).rounded(.up)))
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
        guard let rep, let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        NSImage(cgImage: image, size: NSSize(width: CGFloat(image.width), height: CGFloat(image.height))).draw(
            in: NSRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)),
            from: .zero,
            operation: .copy,
            fraction: 1
        )
        NSGraphicsContext.restoreGraphicsState()
        let thumbnail = NSImage(size: NSSize(width: CGFloat(width), height: CGFloat(height)))
        thumbnail.addRepresentation(rep)
        return thumbnail
    }
}

@MainActor
private final class CaptureThumbnailDocumentView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
private final class CaptureThumbnailView: NSView, NSDraggingSource {
    private let image: NSImage
    private(set) var fileURL: URL
    private var title: String?
    private let onHover: (NSImage, URL) -> Void
    private let onExit: (URL) -> Void
    private let onClick: (URL) -> Void
    private let onCopyText: (URL) -> Void
    private let onEditImage: (URL) -> Void
    private let onClose: (URL) -> Void
    private let onUnavailable: (URL, Error) -> Void
    private let onDragStarted: (URL) -> Void
    private let onDragEnded: (URL) -> Void
    private var editButton: NSButton?
    private var mouseDownPoint: NSPoint?
    private var dragging = false
    private var activeDragURL: URL?

    init(
        frame: NSRect,
        image: NSImage,
        fileURL: URL,
        onHover: @escaping (NSImage, URL) -> Void,
        onExit: @escaping (URL) -> Void,
        onClick: @escaping (URL) -> Void,
        onCopyText: @escaping (URL) -> Void,
        onEditImage: @escaping (URL) -> Void,
        onUnavailable: @escaping (URL, Error) -> Void,
        onClose: @escaping (URL) -> Void,
        onDragStarted: @escaping (URL) -> Void,
        onDragEnded: @escaping (URL) -> Void
    ) {
        self.image = image
        self.fileURL = fileURL
        self.onHover = onHover
        self.onExit = onExit
        self.onClick = onClick
        self.onCopyText = onCopyText
        self.onEditImage = onEditImage
        self.onUnavailable = onUnavailable
        self.onClose = onClose
        self.onDragStarted = onDragStarted
        self.onDragEnded = onDragEnded
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
        let button = NSButton(title: BiscuitLocalization.string("Edit"), target: self, action: #selector(editFromButton(_:)))
        button.bezelStyle = .rounded
        button.font = .systemFont(ofSize: 10, weight: .semibold)
        button.setAccessibilityLabel(BiscuitLocalization.string("Edit Image"))
        button.toolTip = BiscuitLocalization.string("Edit Image")
        button.isHidden = true
        addSubview(button)
        editButton = button
        updateAccessibilityLabel()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override var isFlipped: Bool { true }
    override func layout() {
        super.layout()
        editButton?.frame = NSRect(x: bounds.maxX - 50, y: 7, width: 42, height: 21)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.62).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
        image.draw(in: bounds.insetBy(dx: 5, dy: 5), from: .zero, operation: .sourceOver, fraction: 1)
        if let title, !title.isEmpty {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: NSColor.white,
                .paragraphStyle: paragraph
            ]
            let labelHeight = min(18, max(12, bounds.height - 8))
            let label = NSRect(x: 6, y: max(4, bounds.maxY - labelHeight - 4),
                               width: max(0, bounds.width - 12), height: labelHeight)
            NSColor.black.withAlphaComponent(0.72).setFill()
            NSBezierPath(roundedRect: label, xRadius: 3, yRadius: 3).fill()
            (title as NSString).draw(in: label.insetBy(dx: 4, dy: 1), withAttributes: attributes)
        }
    }
    func updateImageFileURL(_ url: URL, title: String) {
        fileURL = url
        self.title = title
        updateAccessibilityLabel()
        needsDisplay = true
    }

    private func updateAccessibilityLabel() {
        let accessibilityLabel: String
        if let title, !title.isEmpty {
            accessibilityLabel = BiscuitLocalization.format("%1$@: Screenshot; Edit Image on hover or in the context menu, click to copy, drag to attach", arguments: [title])
        } else {
            accessibilityLabel = BiscuitLocalization.string("Screenshot; Edit Image on hover or in the context menu, click to copy, drag to attach")
        }
        setAccessibilityLabel(accessibilityLabel)
        toolTip = title
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let close = NSMenuItem(title: BiscuitLocalization.string("Close"), action: #selector(closeFromMenu), keyEquivalent: "")
        close.target = self
        menu.addItem(close)
        menu.addItem(.separator())
        let edit = NSMenuItem(title: BiscuitLocalization.string("Edit Image"), action: #selector(editFromMenu(_:)), keyEquivalent: "")
        edit.target = self
        menu.addItem(edit)
        let copyImage = NSMenuItem(title: BiscuitLocalization.string("Copy Image"), action: #selector(copyImageFromMenu), keyEquivalent: "")
        copyImage.target = self
        let copyText = NSMenuItem(title: BiscuitLocalization.string("Copy Text"), action: #selector(copyTextFromMenu), keyEquivalent: "")
        copyText.target = self
        menu.addItem(copyImage)
        menu.addItem(copyText)
        return menu
    }

    override func mouseEntered(with event: NSEvent) {
        editButton?.isHidden = false
        onHover(image, fileURL)
    }

    override func mouseExited(with event: NSEvent) {
        editButton?.isHidden = true
        onExit(fileURL)
    }

    override func mouseDown(with event: NSEvent) {
        guard FileManager.default.isReadableFile(atPath: fileURL.path) else {
            onUnavailable(fileURL, Self.unavailableFileError(fileURL))
            return
        }
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        dragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !dragging, let start = mouseDownPoint else { return }
        guard FileManager.default.isReadableFile(atPath: fileURL.path) else {
            mouseDownPoint = nil
            onUnavailable(fileURL, Self.unavailableFileError(fileURL))
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - start.x, point.y - start.y) > 4 else { return }
        let dragURL = fileURL
        let item = NSDraggingItem(pasteboardWriter: dragURL as NSURL)
        item.setDraggingFrame(bounds, contents: image)
        dragging = true
        activeDragURL = dragURL
        onDragStarted(dragURL)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        guard mouseDownPoint != nil else { return }
        if !dragging { onClick(fileURL) }
        mouseDownPoint = nil
        dragging = false
    }

    @objc private func copyImageFromMenu() {
        onClick(fileURL)
    }

    @objc private func copyTextFromMenu() {
        onCopyText(fileURL)
    }
    @objc private func editFromMenu(_ sender: Any?) { editImage() }

    @objc private func editFromButton(_ sender: Any?) { editImage() }

    private func editImage() {
        guard FileManager.default.isReadableFile(atPath: fileURL.path) else {
            onUnavailable(fileURL, Self.unavailableFileError(fileURL))
            return
        }
        onEditImage(fileURL)
    }
    @objc private func closeFromMenu() {
        onClose(fileURL)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        let dragURL = activeDragURL ?? fileURL
        activeDragURL = nil
        onDragEnded(dragURL)
    }

    private static func unavailableFileError(_ url: URL) -> Error {
        NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError, userInfo: [
            NSLocalizedDescriptionKey: BiscuitLocalization.format("The saved image is no longer available: %1$@", arguments: [url.lastPathComponent])
        ])
    }
}

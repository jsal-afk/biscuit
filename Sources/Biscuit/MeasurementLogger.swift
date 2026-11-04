import AppKit
import Foundation

@MainActor
enum MeasurementLogger {
    private static let store = MeasurementLogStore()
    private static var pendingWrite: Task<Void, Never>?
    private static var lastWriteError: String?
    private static var summaryWindow: MeasurementSummaryWindowController?
    private static var refreshID = UUID()

    static func record(_ entry: MeasurementEntry) {
        let webRoute = verifiedWebRouteIdentifier(for: entry)
        var classifiedEntry = entry
        classifiedEntry.classifyModelIdentifier(verifiedWebRoute: webRoute)
        let previousWrite = pendingWrite
        pendingWrite = Task { @MainActor in
            await previousWrite?.value
            do {
                try await store.append(classifiedEntry)
                lastWriteError = nil
            } catch {
                lastWriteError = error.localizedDescription
            }
        }
    }

    // Successful Web requests refresh the cached status before resolving the selected slug.
    private static func verifiedWebRouteIdentifier(for entry: MeasurementEntry) -> String? {
        guard entry.outcome == .succeeded,
              entry.provider == "chatgptWeb",
              let candidate = entry.model, !candidate.isEmpty,
              let status = ChatGPTWebProvider.shared.lastKnownStatus,
              status.connected, !status.needsReconnect,
              let routes = ChatGPTWebModelSelection.confirmedRoutes(
                connected: status.connected, reportedRoutes: status.modelRoutes
              ),
              case .available(let index) = ChatGPTWebModelSelection.resolve(
                savedSlug: candidate, routeInventory: routes
              ),
              routes.indices.contains(index) else { return nil }
        let resolvedSlug = routes[index].slug
        return resolvedSlug == candidate ? resolvedSlug : nil
    }

    static func showSummary() {
        let controller = summaryWindow ?? MeasurementSummaryWindowController()
        summaryWindow = controller
        guard BiscuitPresentation.show(controller.window) else { return }
        NSApp.activate(ignoringOtherApps: true)
        refreshSummary()
    }

    static func revealLog() {
        revealLog(selectFile: true)
    }

    static func revealLogFolder() {
        revealLog(selectFile: false)
    }

    private static func refreshSummary() {
        let requestID = UUID()
        refreshID = requestID
        summaryWindow?.showLoading(path: store.fileURL.path)
        Task { @MainActor in
            await pendingWrite?.value
            guard refreshID == requestID, let summaryWindow else { return }
            do {
                let entries = try await store.entries()
                guard refreshID == requestID else { return }
                summaryWindow.show(summary: MeasurementSummary(entries: entries), path: store.fileURL.path,
                                   error: lastWriteError)
            } catch {
                guard refreshID == requestID else { return }
                summaryWindow.show(summary: MeasurementSummary(entries: []), path: store.fileURL.path,
                                   error: error.localizedDescription)
            }
        }
    }

    private static func revealLog(selectFile: Bool) {
        Task { @MainActor in
            await pendingWrite?.value
            do {
                try await store.prepareLogFile()
                let opened: Bool
                if selectFile {
                    opened = NSWorkspace.shared.selectFile(
                        store.fileURL.path,
                        inFileViewerRootedAtPath: store.dataDirectory.path
                    )
                } else {
                    opened = NSWorkspace.shared.open(store.dataDirectory)
                }
                guard opened else {
                    showError(BiscuitLocalization.string("The measurement log could not be opened in Finder."))
                    return
                }
            } catch {
                showError(error.localizedDescription)
            }
        }
    }

    private static func showError(_ message: String) {
        lastWriteError = message
        showSummary()
    }
}

@MainActor
private final class MeasurementSummaryWindowController: NSWindowController {
    private let runCount = NSTextField(labelWithString: "")
    private let statusCount = NSTextField(labelWithString: "")
    private let capturePercentiles = NSTextField(labelWithString: "")
    private let ocrPercentile = NSTextField(labelWithString: "")
    private let translationPercentile = NSTextField(labelWithString: "")
    private let studyPercentile = NSTextField(labelWithString: "")
    private let counts = NSTextField(wrappingLabelWithString: "")
    private let path = NSTextField(wrappingLabelWithString: "")
    private let message = NSTextField(wrappingLabelWithString: "")

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 390),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = BiscuitLocalization.string("Measurement Summary")
        window.isReleasedWhenClosed = false
        super.init(window: window)

        let container = NSView()
        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        let documentView = NSView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = documentView
        container.addSubview(scrollView)

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .width
        root.spacing = 12
        root.translatesAutoresizingMaskIntoConstraints = false
        let heading = NSTextField(labelWithString: BiscuitLocalization.string("Local Measurements"))
        heading.font = .systemFont(ofSize: 17, weight: .semibold)
        for label in [runCount, statusCount, capturePercentiles, ocrPercentile,
                      translationPercentile, studyPercentile, counts, path, message] {
            label.maximumNumberOfLines = 0
            label.lineBreakMode = .byWordWrapping
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        path.textColor = .secondaryLabelColor
        path.font = .systemFont(ofSize: 11)
        message.textColor = .secondaryLabelColor
        root.addArrangedSubview(heading)
        root.addArrangedSubview(runCount)
        root.addArrangedSubview(statusCount)
        root.addArrangedSubview(capturePercentiles)
        root.addArrangedSubview(ocrPercentile)
        root.addArrangedSubview(translationPercentile)
        root.addArrangedSubview(studyPercentile)
        root.addArrangedSubview(counts)
        root.addArrangedSubview(path)
        root.addArrangedSubview(message)

        let finder = NSButton(title: BiscuitLocalization.string("Show in Finder"), target: self, action: #selector(showInFinder(_:)))
        finder.bezelStyle = .rounded
        let close = NSButton(title: BiscuitLocalization.string("Close"), target: self, action: #selector(closeWindow(_:)))
        close.bezelStyle = .rounded
        let buttons = NSStackView(views: [finder, close])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        root.addArrangedSubview(buttons)

        documentView.addSubview(root)
        window.contentView = container
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            root.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 22),
            root.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -22),
            root.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 20),
            root.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -20)
        ])
        BiscuitLocalization.applyInterfaceDirection(to: window)
        BiscuitPresentation.center(window)
    }

    required init?(coder: NSCoder) { nil }

    func showLoading(path: String) {
        runCount.stringValue = BiscuitLocalization.string("Loading local measurement summary…")
        statusCount.stringValue = ""
        capturePercentiles.stringValue = ""
        ocrPercentile.stringValue = ""
        translationPercentile.stringValue = ""
        studyPercentile.stringValue = ""
        counts.stringValue = ""
        self.path.stringValue = BiscuitLocalization.format("Measurement log: %@", arguments: [path])
        message.stringValue = ""
    }

    func show(summary: MeasurementSummary, path: String, error: String?) {
        runCount.stringValue = summary.runCount == 0
            ? BiscuitLocalization.string("No measurements recorded yet.")
            : BiscuitLocalization.format("Runs: %ld", arguments: [summary.runCount])
        statusCount.stringValue = BiscuitLocalization.format(
            "Successful: %ld · Failed: %ld · Cancelled: %ld",
            arguments: [summary.successfulRunCount, summary.failedRunCount, summary.cancelledRunCount]
        )
        capturePercentiles.stringValue = BiscuitLocalization.format(
            "End-to-end — p50: %@; p95: %@",
            arguments: [Self.milliseconds(summary.endToEndP50), Self.milliseconds(summary.endToEndP95)]
        )
        ocrPercentile.stringValue = BiscuitLocalization.format("OCR — p50: %@", arguments: [Self.milliseconds(summary.ocrP50)])
        translationPercentile.stringValue = BiscuitLocalization.format("Translation — p50: %@", arguments: [Self.milliseconds(summary.translationP50)])
        studyPercentile.stringValue = BiscuitLocalization.format("Study — p50: %@", arguments: [Self.milliseconds(summary.studyP50)])
        counts.stringValue = BiscuitLocalization.format(
            "Recognized boxes: %@ · Characters: %@ · Tables: %@ · Table cells: %@ · Average confidence: %@",
            arguments: [
                Self.count(summary.totalBoxCount),
                Self.count(summary.totalCharacterCount),
                Self.count(summary.totalTableCount),
                Self.count(summary.totalTableCellCount),
                Self.confidence(summary.averageConfidence)
            ]
        )
        self.path.stringValue = BiscuitLocalization.format("Measurement log: %@", arguments: [path])
        if let error {
            message.textColor = .systemRed
            message.stringValue = BiscuitLocalization.format("Measurement log issue: %@", arguments: [error])
        } else if summary.runCount == 0 {
            message.textColor = .secondaryLabelColor
            message.stringValue = BiscuitLocalization.string("Timing, counts, and configuration stay on this Mac. Captured images, recognized text, and provider credentials are not written to this log.")
        } else {
            message.textColor = .secondaryLabelColor
            message.stringValue = BiscuitLocalization.string("Local-only timing, counts, and configuration. Captured images, recognized text, and provider credentials are not recorded.")
        }
    }

    @objc private func showInFinder(_ sender: Any?) {
        MeasurementLogger.revealLog()
    }

    @objc private func closeWindow(_ sender: Any?) {
        window?.close()
    }

    private static func milliseconds(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return BiscuitLocalization.format("%.1f ms", arguments: [value])
    }

    private static func count(_ value: Int?) -> String {
        value.map(String.init) ?? "—"
    }

    private static func confidence(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return BiscuitLocalization.format("%.1f%%", arguments: [value * 100])
    }
}

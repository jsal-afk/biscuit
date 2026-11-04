import AppKit

@MainActor
final class BiscuitSettingsWindowController: NSObject {
    private weak var owner: AppDelegate?
    private let capture: CaptureController
    private let library: LibraryController
    private let pageWidth: CGFloat
    private let windowContentWidth: CGFloat
    private static let minimumTabStripWidth: CGFloat = 436
    private static let captureReferenceFrame = NSRect(x: 0, y: 0, width: 631, height: 826)
    private var tabs: NSSegmentedControl!
    private var scrollView: NSScrollView!
    private var statusLabel: NSTextField!
    private var scrollHeightConstraint: NSLayoutConstraint!
    private var pages: [NSView] = []
    private var shortcutRecorders: [Int: ShortcutRecorder] = [:]
    private var currentPage = 0
    let window: NSWindow

    init(owner: AppDelegate, capture: CaptureController, library: LibraryController, language: LanguageController) {
        self.owner = owner
        self.capture = capture
        self.library = library
        let styleMask: NSWindow.StyleMask = [.titled, .closable]
        let captureFrame = Self.captureReferenceFrame
        let contentRect = NSWindow.contentRect(forFrameRect: captureFrame, styleMask: styleMask)
        self.windowContentWidth = contentRect.width
        self.pageWidth = contentRect.width - 48
        self.window = NSWindow(contentRect: contentRect, styleMask: styleMask, backing: .buffered, defer: false)
        super.init()

        let content = NSView()
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .centerX
        root.spacing = 12
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)

        tabs = NSSegmentedControl(labels: ["Capture", "Translation", "Learning", "Todos", "General"].map { BiscuitLocalization.string($0) }, trackingMode: .selectOne, target: self, action: #selector(sectionChanged(_:)))
        tabs.segmentStyle = .rounded
        tabs.segmentDistribution = .fit
        tabs.selectedSegment = 0
        tabs.sizeToFit()
        tabs.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.minimumTabStripWidth).isActive = true
        root.addArrangedSubview(tabs)

        scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.widthAnchor.constraint(equalToConstant: pageWidth).isActive = true
        scrollHeightConstraint = scrollView.heightAnchor.constraint(equalToConstant: 480)
        scrollHeightConstraint.isActive = true
        root.addArrangedSubview(scrollView)

        statusLabel = NSTextField(wrappingLabelWithString: "")
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 0
        statusLabel.widthAnchor.constraint(equalToConstant: pageWidth).isActive = true
        statusLabel.isHidden = true
        root.addArrangedSubview(statusLabel)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            root.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20)
        ])
        window.contentView = content

        pages = [
            makeCapturePage(),
            language.makeSettingsTabView(labelColumnWidth: labelColumnWidth(for: ["Provider", "Account", "Usage", "Model", "My language", "Translate into", "Clipboard", "After copying"])),
            makeLearningPage(),
            makeTodosPage(),
            makeGeneralPage()
        ]
        let initialFrame = Self.captureReferenceFrame
        BiscuitPresentation.setFrame(initialFrame, for: window, display: false)
        selectPage(0, resize: true)
    }

    func updateShortcutStatus(_ errors: [String]) {
        let wasHidden = statusLabel.isHidden
        statusLabel.stringValue = errors.joined(separator: "\n")
        statusLabel.isHidden = errors.isEmpty
        if wasHidden != statusLabel.isHidden || !errors.isEmpty {
            selectPage(currentPage, resize: true)
        }
    }

    private func makeCapturePage() -> NSStackView {
        let labels = ["Capture & Copy Image", "Image history", "Copy shortcut", "Translate shortcut", "Scrolling image shortcut", "Recognition language", "Notification duration"]
        let labelWidth = labelColumnWidth(for: labels)
        let page = pageStack()
        page.addArrangedSubview(shortcutRow(index: 4, label: "Capture & Copy Image", labelColumnWidth: labelWidth))
        page.addArrangedSubview(shortcutRow(index: 5, label: "Scrolling image shortcut", labelColumnWidth: labelWidth))

        let corner = NSButton(checkboxWithTitle: BiscuitLocalization.string("Keep captured images in the screen corner"), target: self, action: #selector(cornerThumbnailsChanged(_:)))
        corner.state = capture.cornerThumbnailsEnabled ? .on : .off
        page.addArrangedSubview(formRow("", content: controlGroup(corner, info("Thumbnails stack in the bottom-right corner, so the previous image isn't lost when you capture another. Recent images are also kept under Recent Images in the menu bar.")), labelColumnWidth: labelWidth))
        let autoHide = NSButton(
            checkboxWithTitle: BiscuitLocalization.string("Automatically hide corner thumbnails after 8 seconds"),
            target: self,
            action: #selector(cornerThumbnailAutoHideChanged(_:))
        )
        autoHide.state = capture.cornerThumbnailsAutoHideEnabled ? .on : .off
        page.addArrangedSubview(formRow(
            "",
            content: controlGroup(
                autoHide,
                info("This hides only the corner shelf; captured images remain in local history and can still be reopened from Recent Images.")
            ),
            labelColumnWidth: labelWidth
        ))

        let aiTitle = NSButton(checkboxWithTitle: BiscuitLocalization.string("Give images an AI title"), target: self, action: #selector(imageTitlesChanged(_:)))
        aiTitle.state = SettingsPreferences.imageTitlesEnabled(defaults: BiscuitPreferences.defaults) ? .on : .off
        page.addArrangedSubview(formRow("", content: controlGroup(
            aiTitle,
            info("Titles appear in Recent Images and filenames. OCR runs locally. When on, only the selected, enabled ChatGPT or Claude route receives OCR text—not image bytes. Off by default; no backfill or provider fallback. Provider usage applies.")
        ), labelColumnWidth: labelWidth))

        let history = NSPopUpButton()
        history.widthAnchor.constraint(equalToConstant: 205).isActive = true
        history.target = self
        history.action = #selector(imageHistoryChanged(_:))
        refreshImageHistoryMenu(history)
        page.addArrangedSubview(formRow("Image history", content: controlGroup(history, info("Local image history is unlimited unless you choose a limit. Reducing it asks before older files are removed.")), labelColumnWidth: labelWidth))

        page.addArrangedSubview(shortcutRow(index: 0, label: "Copy shortcut", labelColumnWidth: labelWidth))
        page.addArrangedSubview(shortcutRow(index: 1, label: "Translate shortcut", labelColumnWidth: labelWidth))
        page.addArrangedSubview(formRow("", content: info("Hold Option to show the Copy and Translate shortcuts while a copy notification is visible."), labelColumnWidth: labelWidth))
        page.addArrangedSubview(CaptureOCRSettingsView(labelColumnWidth: labelWidth))

        let duration = NSPopUpButton()
        duration.widthAnchor.constraint(equalToConstant: 105).isActive = true
        for value in SettingsPreferences.notificationDurations {
            let title = BiscuitLocalization.format("%.1f s", arguments: [value])
            duration.addItem(withTitle: title)
            duration.lastItem?.representedObject = NSNumber(value: value)
        }
        let currentDuration = SettingsPreferences.notificationDuration(defaults: BiscuitPreferences.defaults)
        if let index = SettingsPreferences.notificationDurations.firstIndex(of: currentDuration) {
            duration.selectItem(at: index)
        }
        duration.target = self
        duration.action = #selector(notificationDurationChanged(_:))
        page.addArrangedSubview(formRow("Notification duration", content: controlGroup(duration, info("Controls how long Biscuit's native copy notification stays visible.")), labelColumnWidth: labelWidth))
        return page
    }

    private func makeLearningPage() -> NSStackView {
        let labelWidth = labelColumnWidth(for: ["Learn shortcut", "Explanation level", "Study notes"])
        let page = pageStack()
        page.addArrangedSubview(shortcutRow(index: 2, label: "Learn shortcut", labelColumnWidth: labelWidth))

        let level = NSPopUpButton()
        level.widthAnchor.constraint(equalToConstant: 180).isActive = true
        for choice in ExplanationLevel.allCases {
            level.addItem(withTitle: choice.title)
            level.lastItem?.representedObject = choice.rawValue
        }
        let currentLevel = SettingsPreferences.explanationLevel(defaults: BiscuitPreferences.defaults)
        level.selectItem(withTitle: currentLevel.title)
        level.target = self
        level.action = #selector(explanationLevelChanged(_:))
        page.addArrangedSubview(formRow("Explanation level", content: level, labelColumnWidth: labelWidth))

        let notes = NSButton(title: BiscuitLocalization.string("Open Study Notes"), target: self, action: #selector(openStudyNotes(_:)))
        notes.bezelStyle = .rounded
        page.addArrangedSubview(formRow("Study notes", content: notes, labelColumnWidth: labelWidth))
        page.addArrangedSubview(formRow("", content: info("Explains the meaning, vocabulary, grammar and nuance of captured text in your language; Apple Translation does not explain. Save explanations in the local Study Notes notebook, then open, search, copy, delete, or export notes as Markdown. Existing study-notes.md entries are imported once without changing the original file. Vocabulary and personal notes stay with each study record."), labelColumnWidth: labelWidth))
        return page
    }

    private func makeTodosPage() -> NSStackView {
        let labelWidth = labelColumnWidth(for: ["Todo shortcut"])
        let page = pageStack()
        page.addArrangedSubview(shortcutRow(index: 3, label: "Todo shortcut", labelColumnWidth: labelWidth))
        let edge = NSButton(checkboxWithTitle: BiscuitLocalization.string("Show when the pointer rests on the right edge of the screen"), target: self, action: #selector(edgeTriggerChanged(_:)))
        edge.state = BiscuitPreferences.defaults.bool(forKey: TodoController.edgeEnabledPreferenceKey) ? .on : .off
        page.addArrangedSubview(formRow("", content: controlGroup(edge, info("Tasks are saved only on this Mac. Press the shortcut again, press Esc, or click elsewhere to tuck the panel away. Starred tasks stay at the top; right-click a task to delete it.")), labelColumnWidth: labelWidth))
        return page
    }

    private func makeGeneralPage() -> NSStackView {
        let labels = ["License", "Interface language", "Version", "Updates", "Diagnostics"]
        let labelWidth = labelColumnWidth(for: labels)
        let page = pageStack()
        page.addArrangedSubview(formRow("License", content: info("Free and MIT-licensed. Local text and image history is unlimited; no paid unlock is required."), labelColumnWidth: labelWidth))

        let interfaceLanguage = NSPopUpButton()
        interfaceLanguage.widthAnchor.constraint(equalToConstant: 180).isActive = true
        for choice in InterfaceLanguageChoice.allCases {
            interfaceLanguage.addItem(withTitle: choice.title)
            interfaceLanguage.lastItem?.representedObject = choice.rawValue
        }
        interfaceLanguage.selectItem(withTitle: SettingsPreferences.interfaceLanguage(defaults: BiscuitPreferences.defaults).title)
        interfaceLanguage.target = self
        interfaceLanguage.action = #selector(interfaceLanguageChanged(_:))
        page.addArrangedSubview(formRow(
            "Interface language",
            content: controlGroup(
                interfaceLanguage,
                info("System matches your preferred supported language; unsupported system locales fall back to English. All listed locales are bundled. Restart Biscuit to apply a saved preference.")
            ),
            labelColumnWidth: labelWidth
        ))

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? BiscuitLocalization.string("Unknown")
        page.addArrangedSubview(formRow("Version", content: NSTextField(labelWithString: version), labelColumnWidth: labelWidth))

        let login = NSButton(checkboxWithTitle: BiscuitLocalization.string("Launch at login"), target: self, action: #selector(loginAtLaunchChanged(_:)))
        login.state = owner?.loginAtLaunchEnabled == true ? .on : .off
        page.addArrangedSubview(formRow("", content: controlGroup(login, info("Opening Settings does not change this macOS login-item setting.")), labelColumnWidth: labelWidth))
        let checkUpdates = NSButton(title: BiscuitLocalization.string("Check for Updates…"), target: self, action: #selector(checkForUpdates(_:)))
        checkUpdates.bezelStyle = .rounded
        let automaticUpdates = NSButton(
            checkboxWithTitle: BiscuitLocalization.string("Automatically check for updates"),
            target: self,
            action: #selector(automaticUpdateChecksChanged(_:))
        )
        automaticUpdates.state = BiscuitUpdatePreferences.automaticChecksEnabled(defaults: BiscuitPreferences.defaults) ? .on : .off
        page.addArrangedSubview(formRow(
            "Updates",
            content: controlGroup(
                checkUpdates,
                automaticUpdates,
                info("Automatic checks are off until enabled. When enabled, Biscuit checks the public GitHub release list at most once a day. Checks download no files; you choose whether to install a compatible release.")
            ),
            labelColumnWidth: labelWidth
        ))

        let measurementLogs = NSButton(
            title: BiscuitLocalization.string("Open Measurement Log Folder"),
            target: self,
            action: #selector(openMeasurementLogs(_:))
        )
        measurementLogs.bezelStyle = .rounded
        page.addArrangedSubview(formRow(
            "Diagnostics",
            content: controlGroup(
                measurementLogs,
                info("Opens private local measurement logs. Biscuit does not upload diagnostics.")
            ),
            labelColumnWidth: labelWidth
        ))
        return page
    }

    private func pageStack() -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 12
        return stack
    }

    private func labelColumnWidth(for labels: [String]) -> CGFloat {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let localizedLabels = labels.map { BiscuitLocalization.string($0) }
        let intrinsic = localizedLabels.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        return min(max(110, ceil(intrinsic + 18)), pageWidth * 0.35)
    }

    private func formRow(_ label: String, content: NSView, labelColumnWidth: CGFloat) -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .top
        row.distribution = .fill
        row.spacing = 12
        let displayedLabel = label.isEmpty ? "" : BiscuitLocalization.string(label)
        let labelView = NSTextField(labelWithString: displayedLabel)
        labelView.alignment = .right
        labelView.widthAnchor.constraint(equalToConstant: labelColumnWidth).isActive = true
        labelView.setContentHuggingPriority(.required, for: .horizontal)
        content.setContentHuggingPriority(.defaultLow, for: .horizontal)
        content.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(labelView)
        row.addArrangedSubview(content)
        row.widthAnchor.constraint(equalToConstant: pageWidth).isActive = true
        return row
    }

    private func controlGroup(_ views: NSView..., spacing: CGFloat = 4) -> NSStackView {
        let group = NSStackView(views: views)
        group.orientation = .vertical
        group.alignment = .leading
        group.spacing = spacing
        return group
    }

    private func info(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: BiscuitLocalization.string(text))
        label.maximumNumberOfLines = 0
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func shortcutRow(index: Int, label: String, labelColumnWidth: CGFloat) -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        let name = NSTextField(labelWithString: BiscuitLocalization.string(label))
        name.alignment = .right
        name.widthAnchor.constraint(equalToConstant: labelColumnWidth).isActive = true
        name.setContentHuggingPriority(.required, for: .horizontal)
        let current = owner?.settingsShortcut(index) ?? (AppDelegate.defaultCodes[index], AppDelegate.defaultModifiers[index])
        let recorder = ShortcutRecorder(code: current.0, modifiers: current.1, onRecording: { [weak self] recording in
            self?.owner?.settingsShortcutRecording(recording)
        }, onChange: { [weak self] code, modifiers in
            self?.owner?.saveSettingsShortcut(index, code: code, modifiers: modifiers)
        })
        recorder.widthAnchor.constraint(equalToConstant: 155).isActive = true
        shortcutRecorders[index] = recorder
        let reset = NSButton(title: BiscuitLocalization.string("Default"), target: self, action: #selector(resetShortcut(_:)))
        reset.tag = index
        row.addArrangedSubview(name)
        row.addArrangedSubview(recorder)
        row.addArrangedSubview(reset)
        row.widthAnchor.constraint(equalToConstant: pageWidth).isActive = true
        return row
    }

    private func refreshImageHistoryMenu(_ popup: NSPopUpButton) {
        popup.removeAllItems()
        guard library.store != nil else {
            popup.addItem(withTitle: BiscuitLocalization.string("Unavailable"))
            popup.lastItem?.representedObject = "unavailable"
            popup.isEnabled = false
            return
        }
        popup.isEnabled = true
        popup.addItem(withTitle: BiscuitLocalization.string("Keep all"))
        popup.lastItem?.representedObject = "all"
        if let limit = library.currentImageLimit {
            popup.addItem(withTitle: BiscuitLocalization.format("Keep last %d", arguments: [limit]))
            popup.lastItem?.representedObject = NSNumber(value: limit)
        }
        popup.menu?.addItem(.separator())
        popup.addItem(withTitle: BiscuitLocalization.string("Choose count…"))
        popup.lastItem?.representedObject = "choose"
        if let limit = library.currentImageLimit {
            popup.selectItem(withTitle: BiscuitLocalization.format("Keep last %d", arguments: [limit]))
        } else {
            popup.selectItem(withTitle: BiscuitLocalization.string("Keep all"))
        }
    }

    private func chooseImageHistoryLimit() {
        let alert = NSAlert()
        alert.messageText = BiscuitLocalization.string("Keep how many recent images?")
        alert.informativeText = BiscuitLocalization.string("Text history remains unlimited. Older images are removed only after confirmation.")
        let field = NSTextField(string: library.currentImageLimit.map { String($0) } ?? "")
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: BiscuitLocalization.string("Apply"))
        alert.addButton(withTitle: BiscuitLocalization.string("Cancel"))
        BiscuitLocalization.applyInterfaceDirection(to: alert)
        guard BiscuitPresentation.runModal(alert) == .alertFirstButtonReturn else { return }
        let value = field.stringValue.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        guard let limit = Int(value), limit > 0 else {
            let invalid = NSAlert()
            invalid.messageText = BiscuitLocalization.string("Enter a positive image count")
            invalid.addButton(withTitle: BiscuitLocalization.string("OK"))
            BiscuitLocalization.applyInterfaceDirection(to: invalid)
            _ = BiscuitPresentation.runModal(invalid)
            return
        }
        _ = library.setImageLimitFromSettings(limit)
    }

    @objc private func sectionChanged(_ sender: NSSegmentedControl) {
        guard sender.selectedSegment >= 0 else { return }
        selectPage(sender.selectedSegment, resize: true)
    }

    @objc private func resetShortcut(_ sender: NSButton) {
        let index = sender.tag
        guard let value = owner?.resetSettingsShortcut(index) else { return }
        shortcutRecorders[index]?.setShortcut(code: value.0, modifiers: value.1)
    }

    @objc private func cornerThumbnailsChanged(_ sender: NSButton) {
        capture.setCornerThumbnailsEnabled(sender.state == .on)
    }

    @objc private func imageTitlesChanged(_ sender: NSButton) {
        let enabled = sender.state == .on
        SettingsPreferences.setImageTitlesEnabled(enabled, defaults: BiscuitPreferences.defaults)
        library.imageTitlePreferenceChanged(enabled: enabled)
    }

    @objc private func imageHistoryChanged(_ sender: NSPopUpButton) {
        guard let item = sender.selectedItem else {
            refreshImageHistoryMenu(sender)
            return
        }
        if let limit = item.representedObject as? NSNumber {
            _ = library.setImageLimitFromSettings(limit.intValue)
        } else {
            switch item.representedObject as? String {
            case "all": _ = library.setImageLimitFromSettings(nil)
            case "choose": chooseImageHistoryLimit()
            default: break
            }
        }
        refreshImageHistoryMenu(sender)
    }

    @objc private func edgeTriggerChanged(_ sender: NSButton) {
        owner?.changeEdge(sender)
    }
    @objc private func cornerThumbnailAutoHideChanged(_ sender: NSButton) {
        capture.setCornerThumbnailsAutoHideEnabled(sender.state == .on)
    }


    @objc private func openStudyNotes(_ sender: Any?) {
        owner?.showStudyNotes()
    }
    @objc private func loginAtLaunchChanged(_ sender: NSButton) {
        owner?.changeLogin(sender)
    }
    @objc private func checkForUpdates(_ sender: Any?) {
        owner?.checkForUpdates()
    }

    @objc private func automaticUpdateChecksChanged(_ sender: NSButton) {
        let enabled = sender.state == .on
        BiscuitUpdatePreferences.setAutomaticChecksEnabled(enabled, defaults: BiscuitPreferences.defaults)
        owner?.automaticUpdateChecksChanged(enabled: enabled)
    }

    @objc private func notificationDurationChanged(_ sender: NSPopUpButton) {
        guard let value = sender.selectedItem?.representedObject as? NSNumber else { return }
        SettingsPreferences.setNotificationDuration(value.doubleValue, defaults: BiscuitPreferences.defaults)
    }

    @objc private func explanationLevelChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String,
              let level = ExplanationLevel(rawValue: raw) else { return }
        SettingsPreferences.setExplanationLevel(level, defaults: BiscuitPreferences.defaults)
    }

    @objc private func interfaceLanguageChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String,
              let choice = InterfaceLanguageChoice(rawValue: raw) else { return }
        SettingsPreferences.setInterfaceLanguage(choice, defaults: BiscuitPreferences.defaults)
        showStatus(BiscuitLocalization.string("Interface language preference saved. Restart Biscuit to apply it."))
    }


    @objc private func openMeasurementLogs(_ sender: Any?) {
        MeasurementLogger.revealLogFolder()
    }

    private func showStatus(_ text: String) {
        statusLabel.stringValue = text
        statusLabel.isHidden = false
        selectPage(currentPage, resize: true)
    }

    private func selectPage(_ index: Int, resize: Bool) {
        guard pages.indices.contains(index) else { return }
        currentPage = index
        tabs.selectedSegment = index
        let page = pages[index]
        let document = SettingsPageDocumentView(frame: NSRect(x: 0, y: 0, width: pageWidth, height: 1))
        page.frame = NSRect(x: 0, y: 0, width: pageWidth, height: 1)
        document.addSubview(page)
        BiscuitLocalization.applyInterfaceDirection(to: document)
        document.layoutSubtreeIfNeeded()
        page.layoutSubtreeIfNeeded()
        let pageHeight = max(120, ceil(page.fittingSize.height))
        let maximum = max(240, ((window.screen ?? NSScreen.main)?.visibleFrame.height ?? 960) - 220)
        let tabHeight = tabs.fittingSize.height
        let statusHeight = statusLabel.isHidden ? 0 : max(14, ceil(statusLabel.fittingSize.height))
        let statusSpacing = statusLabel.isHidden ? 0 : 12.0
        let verticalMargins: CGFloat = 40
        let rootSpacing: CGFloat = 12

        let scrollHeight: CGFloat
        if index == 0 {
            let contentHeight = NSWindow.contentRect(forFrameRect: Self.captureReferenceFrame, styleMask: window.styleMask).height
            scrollHeight = max(160, contentHeight - verticalMargins - tabHeight - rootSpacing - statusHeight - statusSpacing)
        } else {
            let available = max(160, maximum - verticalMargins - tabHeight - rootSpacing - statusHeight - statusSpacing)
            scrollHeight = min(pageHeight, available)
        }
        scrollHeightConstraint.constant = scrollHeight

        let documentHeight = max(pageHeight, scrollHeight)
        page.frame = NSRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
        document.setFrameSize(NSSize(width: pageWidth, height: documentHeight))
        scrollView.documentView = document
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)

        guard resize else { return }
        if index == 0 {
            resizeWindow(toFrameHeight: Self.captureReferenceFrame.height)
        } else {
            let contentHeight = verticalMargins + tabHeight + rootSpacing + scrollHeight + statusHeight + statusSpacing
            resizeWindow(toContentHeight: contentHeight)
        }
    }

    private func resizeWindow(toFrameHeight height: CGFloat) {
        let current = window.frame
        BiscuitPresentation.setFrame(NSRect(x: current.minX, y: current.maxY - height, width: Self.captureReferenceFrame.width, height: height), for: window, display: true)
    }

    private func resizeWindow(toContentHeight height: CGFloat) {
        let contentRect = NSRect(x: 0, y: 0, width: windowContentWidth, height: height)
        let frameRect = NSWindow.frameRect(forContentRect: contentRect, styleMask: window.styleMask)
        let current = window.frame
        BiscuitPresentation.setFrame(NSRect(x: current.minX, y: current.maxY - frameRect.height, width: frameRect.width, height: frameRect.height), for: window, display: true)
    }
}

private final class SettingsPageDocumentView: NSView {
    override var isFlipped: Bool { true }
}

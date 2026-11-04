import AppKit
import Carbon
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    private var status: NSStatusItem!
    private lazy var library: LibraryController = LibraryController(onRemovingImages: { [weak self] urls in
        self?.capture.removeImages(urls) ?? Set<URL>()
    }, onCopied: { [weak self] kind, text in
        switch kind {
        case .text: self?.notifyCopied(text)
        case .image: self?.notifyCopied(nil)
        }
    }, imageTitleEnabled: {
        SettingsPreferences.imageTitlesEnabled(defaults: BiscuitPreferences.defaults)
    }, requestImageTitle: { [weak self] text, isStillConsented, completion in
        self?.language.requestImageTitle(text, isStillConsented: isStillConsented, completion: completion)
    }, scheduleImageFileMutation: { [weak self] url, perform in
        guard let self else {
            perform()
            return
        }
        self.capture.performImageFileMutation(afterDragsFor: url, perform: perform)
    }, onImageFileURLChanged: { [weak self] oldURL, newURL, title in
        self?.capture.updateImageFileURL(from: oldURL, to: newURL, title: title)
    })
    private let todos = TodoController()
    private lazy var language: LanguageController = LanguageController(
        onCopied: { [weak self] text in self?.notifyCopied(text) },
        onOfferAfterCopyChanged: { [weak self] enabled in self?.copyOfferPreferenceChanged(enabled: enabled) }
    )
    private lazy var capture: CaptureController = CaptureController(onText: { [weak self] text in
        self?.lastText = text
        self?.library.addText(text)
    }, onImage: { [weak self] url in
        self?.library.addImage(url)
    }, onCopiedText: { [weak self] text in
        self?.copyNotification.showCopiedText(text)
    }, onCopiedImage: { [weak self] in
        self?.copyNotification.showCopiedImage()
    }, onEditImage: { [weak self] url in
        self?.library.editImage(forImageURL: url)
    })
    private lazy var copyNotification = CopyNotificationController(
        duration: { SettingsPreferences.notificationDuration(defaults: BiscuitPreferences.defaults) },
        offerEnabled: { SettingsPreferences.offerTranslationAfterCopy(defaults: BiscuitPreferences.defaults) },
        shortcutLabel: { [weak self] index in
            let resolved = self?.shortcut(index) ?? (Self.defaultCodes[index], Self.defaultModifiers[index])
            return SettingsPreferences.shortcutLabel(
                code: resolved.0,
                modifiers: resolved.1,
                commandMask: UInt32(cmdKey),
                shiftMask: UInt32(shiftKey),
                optionMask: UInt32(optionKey),
                controlMask: UInt32(controlKey)
            )
        },
        onTranslate: { [weak self] text in self?.language.show(text: text, mode: .translate) }
    )
    private var updateClient = BiscuitUpdateClient()
#if BISCUIT_SMOKE
    private var smokeUpdateSourceConfigurationError: String?
#endif
    private let updateInstaller = BiscuitUpdateInstaller(expectedBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
    private var availableUpdate: BiscuitUpdateRelease?
    private var updateCheckInProgress = false
    private var updateInstallationInProgress = false
#if BISCUIT_SMOKE
    private var updateConfirmationInProgress = false
    private var updaterMessageInProgress = false
    private var pendingUpdateSheetParent: NSWindow?
#endif
    private var automaticUpdateCheckTask: Task<Void, Never>?
    private var pendingUpdateRelaunch: (appURL: URL, rollbackURL: URL)?

    private var lastText = ""
    private var settings: NSWindow?
    private var settingsController: BiscuitSettingsWindowController?
    private var hotkeys: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    private var shortcutErrors: [String] = []
    static let shortcutNames = ["Copy area text", "Translate area", "Learn from area", "Todos", "Capture image", "Capture scrolling image"]
    static let defaultCodes: [UInt32] = [UInt32(kVK_ANSI_C), UInt32(kVK_ANSI_T), UInt32(kVK_ANSI_L), UInt32(kVK_ANSI_D), UInt32(kVK_ANSI_4), UInt32(kVK_ANSI_S)]
    static let defaultModifiers: [UInt32] = [UInt32(optionKey), UInt32(optionKey), UInt32(optionKey), UInt32(optionKey), UInt32(cmdKey | shiftKey), UInt32(optionKey)]

    private var deferredTermination = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !deferredTermination else { return .terminateLater }
#if BISCUIT_SMOKE
        if updateConfirmationInProgress || updaterMessageInProgress {
            return .terminateCancel
        }
#endif
        if updateInstallationInProgress && pendingUpdateRelaunch == nil {
            deferredTermination = true
            return .terminateLater
        }
        deferredTermination = true
        if pendingUpdateRelaunch != nil {
            beginUpdatedApplicationRelaunch(sender)
            return .terminateLater
        }
        let waiting = ChatGPTWebProvider.shared.shutdownForTermination {
            sender.reply(toApplicationShouldTerminate: true)
        }
        return waiting ? .terminateLater : .terminateNow
    }

    private func beginUpdatedApplicationRelaunch(_ sender: NSApplication) {
        let waiting = ChatGPTWebProvider.shared.shutdownForTermination { [weak self] in
            guard let self else {
                sender.reply(toApplicationShouldTerminate: true)
                return
            }
            self.launchUpdatedApplicationOrRestore(sender)
        }
        if !waiting { launchUpdatedApplicationOrRestore(sender) }
    }
    private func launchUpdatedApplicationOrRestore(_ sender: NSApplication) {
        guard let pending = pendingUpdateRelaunch else {
            sender.reply(toApplicationShouldTerminate: true)
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
#if BISCUIT_SMOKE
        let processEnvironment = ProcessInfo.processInfo.environment
        var isolatedEnvironment: [String: String] = [:]
        for key in ["BISCUIT_DATA_DIR", "BISCUIT_PREFERENCES_SUITE", "BISCUIT_SMOKE_UPDATES_API_URL", "BISCUIT_SMOKE_CAPTURE_DISPLAY_ID"] {
            if let value = processEnvironment[key] { isolatedEnvironment[key] = value }
        }
        if !isolatedEnvironment.isEmpty { configuration.environment = isolatedEnvironment }
#endif
        hotkeys.forEach { UnregisterEventHotKey($0) }
        hotkeys.removeAll()
        NSWorkspace.shared.openApplication(at: pending.appURL, configuration: configuration) { [weak self] application, error in
            Task { @MainActor [weak self] in
                guard let self else {
                    sender.reply(toApplicationShouldTerminate: true)
                    return
                }
                guard application != nil, error == nil else {
#if BISCUIT_SMOKE
                    await self.restoreAfterUpdatedLaunchFailure(
                        pending,
                        sender: sender,
                        sheetParent: self.pendingUpdateSheetParent
                    )
#else
                    await self.restoreAfterUpdatedLaunchFailure(pending, sender: sender, sheetParent: nil)
#endif
                    return
                }
                sender.reply(toApplicationShouldTerminate: true)
            }
        }
    }

    private func restoreAfterUpdatedLaunchFailure(
        _ pending: (appURL: URL, rollbackURL: URL),
        sender: NSApplication,
        sheetParent: NSWindow?
    ) async {
        pendingUpdateRelaunch = nil
#if BISCUIT_SMOKE
        pendingUpdateSheetParent = nil
#endif
        let detail: String
        do {
            try updateInstaller.restore(pending.rollbackURL, at: pending.appURL)
            updateInstallationInProgress = false
            deferredTermination = false
            detail = BiscuitLocalization.string("The previous Biscuit version was restored. Your data and preferences were not changed.")
        } catch {
            updateInstallationInProgress = false
            deferredTermination = false
            detail = error.localizedDescription
        }
        registerHotkeys()
        rebuildMenu()
        await showUpdaterMessage(
            BiscuitLocalization.string("Update relaunch failed"),
            detail,
            sheetParent: sheetParent
        )
        sender.reply(toApplicationShouldTerminate: false)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
#if BISCUIT_SMOKE
        configureSmokeUpdateSource()
#endif
        NSApp.setActivationPolicy(.accessory)
        installMainMenu()
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.image = Self.menuBarIcon()
        status.button?.setAccessibilityLabel("biscuit")
        status.button?.toolTip = BiscuitLocalization.string("biscuit — capture, translate, remember")
        lastText = library.store?.items.first(where: { $0.kind == .text })?.text ?? ""
        rebuildMenu()
        registerHotkeys()
        todos.startEdgeMonitoring()
        scheduleAutomaticUpdateCheck(afterNanoseconds: 30_000_000_000)
        #if BISCUIT_SMOKE
        if CommandLine.arguments.contains("--smoke") {
            Task { await BiscuitSmoke.run(app: self) }
            return
        }
        #endif
        if CommandLine.arguments.contains("--show-library") {
            library.show()
        } else if CommandLine.arguments.contains("--show-settings") {
            showSettings()
        } else if CommandLine.arguments.contains("--show-todos") {
            todos.toggle()
        }
    }
#if BISCUIT_SMOKE
    private func configureSmokeUpdateSource() {
        let errorMessage = "The updater smoke requires BISCUIT_SMOKE_UPDATES_API_URL to be a valid local loopback HTTP endpoint. No production network will be used."
        guard let raw = ProcessInfo.processInfo.environment["BISCUIT_SMOKE_UPDATES_API_URL"] else {
            if CommandLine.arguments.contains("--smoke") {
                smokeUpdateSourceConfigurationError = errorMessage
            }
            return
        }
        guard let url = URL(string: raw),
              url.scheme?.lowercased() == "http",
              url.user == nil,
              url.password == nil,
              let host = url.host?.lowercased(),
              host == "localhost" || host == "::1" || host == "127.0.0.1" || host.hasPrefix("127.") else {
            smokeUpdateSourceConfigurationError = errorMessage
            return
        }
        updateClient = BiscuitUpdateClient(apiURL: url, allowedAssetHosts: [host], allowLoopbackHTTP: true)
        smokeUpdateSourceConfigurationError = nil
    }
#endif

    private static func menuBarIcon() -> NSImage {
        let icon = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            let shape = NSBezierPath(ovalIn: NSRect(x: 1, y: 1, width: 16, height: 16))
            shape.windingRule = .evenOdd
            for point in [NSPoint(x: 5, y: 11), NSPoint(x: 11, y: 12), NSPoint(x: 8, y: 7), NSPoint(x: 12, y: 4), NSPoint(x: 4, y: 4)] {
                shape.append(NSBezierPath(ovalIn: NSRect(x: point.x, y: point.y, width: 2, height: 2)))
            }
            NSColor.black.setFill(); shape.fill(); return true
        }
        icon.isTemplate = true
        return icon
    }

    private func installMainMenu() {
        let main = NSMenu()
        let app = NSMenuItem(); let appMenu = NSMenu()
        appMenu.addItem(withTitle: BiscuitLocalization.string("About biscuit"), action: #selector(about), keyEquivalent: "")
        appMenu.addItem(withTitle: BiscuitLocalization.string("Settings…"), action: #selector(showSettings), keyEquivalent: ",")
        appMenu.addItem(.separator())
        let quit = appMenu.addItem(withTitle: BiscuitLocalization.string("Quit biscuit"), action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        app.submenu = appMenu; main.addItem(app)
        let edit = NSMenuItem(); let editMenu = NSMenu(title: BiscuitLocalization.string("Edit"))
        for (title, action, key) in [("Undo", Selector(("undo:")), "z"), ("Cut", #selector(NSText.cut(_:)), "x"), ("Copy", #selector(NSText.copy(_:)), "c"), ("Paste", #selector(NSText.paste(_:)), "v"), ("Select All", #selector(NSText.selectAll(_:)), "a")] {
            editMenu.addItem(withTitle: BiscuitLocalization.string(title), action: action, keyEquivalent: key)
        }
        edit.submenu = editMenu; main.addItem(edit); NSApp.mainMenu = main
    }

    private func rebuildMenu() {
        let menu = status.menu ?? NSMenu()
        menu.removeAllItems()
        menu.delegate = self
        let heading = menu.addItem(withTitle: BiscuitLocalization.string("biscuit · local by default"), action: nil, keyEquivalent: "")
        heading.isEnabled = false
        add(menu, "Capture & Copy Image", #selector(imageArea), shortcutIndex: 4)
        add(menu, "Capture Scrolling Image…", #selector(scrollingImage), shortcutIndex: 5)
        add(menu, "Capture Area & Copy", #selector(copyArea), shortcutIndex: 0)
        add(menu, "Capture Area & Translate", #selector(translateArea), shortcutIndex: 1)
        add(menu, "Translate Last Result", #selector(translateLast))
        add(menu, "Capture Area & Learn", #selector(learnArea), shortcutIndex: 2)
        add(menu, "Learn from Last Result", #selector(learnLast))
        add(menu, "Open Study Notes", #selector(showStudyNotes))
        add(menu, "Todos", #selector(showTodos), shortcutIndex: 3)

        menu.addItem(recentItemsMenuItem(kind: .text, title: "Recent Results"))
        menu.addItem(recentItemsMenuItem(kind: .image, title: "Recent Images"))

        let more = NSMenuItem(title: BiscuitLocalization.string("History & Clipboard"), action: nil, keyEquivalent: "")
        let moreMenu = NSMenu(title: BiscuitLocalization.string("History & Clipboard"))
        add(moreMenu, "History — Search & Re-copy…", #selector(showLibrary))
        add(moreMenu, "Translate Clipboard Text…", #selector(translateClipboard))
        add(moreMenu, "Learn from Clipboard Text…", #selector(learnClipboard))
        more.submenu = moreMenu
        menu.addItem(more)
        menu.addItem(.separator())
        let summary = menu.addItem(
            withTitle: BiscuitLocalization.string("Measurement Summary…"),
            action: #selector(showMeasurementSummary),
            keyEquivalent: ""
        )
        summary.target = self
        let check = menu.addItem(
            withTitle: BiscuitLocalization.string(updateCheckInProgress ? "Checking for Updates…" : "Check for Updates…"),
            action: #selector(checkForUpdates),
            keyEquivalent: ""
        )
        check.target = self
#if BISCUIT_SMOKE
        check.isEnabled = !updateCheckInProgress && !updateInstallationInProgress
            && !updateConfirmationInProgress && !updaterMessageInProgress
#else
        check.isEnabled = !updateCheckInProgress && !updateInstallationInProgress
#endif
        let install = menu.addItem(
            withTitle: BiscuitLocalization.string(updateInstallationInProgress ? "Installing Update…" : "Install Update…"),
            action: #selector(installAvailableUpdate),
            keyEquivalent: ""
        )
        install.target = self
#if BISCUIT_SMOKE
        install.isEnabled = availableUpdate != nil && !updateCheckInProgress && !updateInstallationInProgress
            && !updateConfirmationInProgress && !updaterMessageInProgress
#else
        install.isEnabled = availableUpdate != nil && !updateCheckInProgress && !updateInstallationInProgress
#endif
        add(menu, "Settings…", #selector(showSettings))
        add(menu, "Permissions & Getting Started…", #selector(permissions))
        add(menu, "About biscuit", #selector(about))
        add(menu, "Quit biscuit", #selector(quit))
        status.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) { if menu === status.menu { rebuildMenu() } }

    private func recentItemsMenuItem(kind: LibraryItemKind, title: String) -> NSMenuItem {
        let localizedTitle = BiscuitLocalization.string(title)
        let parent = NSMenuItem(title: localizedTitle, action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: localizedTitle)
        let items = Array((library.store?.items ?? []).lazy.filter { $0.kind == kind }.prefix(8))
        for record in items {
            let label: String
            if kind == .image, let imageTitle = record.title {
                label = imageTitle
            } else {
                let excerpt = record.text?.split(maxSplits: 1, whereSeparator: \.isNewline).first.map(String.init)
                label = excerpt.flatMap { $0.isEmpty ? nil : String($0.prefix(72)) }
                    ?? record.createdAt.formatted(date: .abbreviated, time: .shortened)
            }
            let item = NSMenuItem(title: label, action: #selector(recopyRecent(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = record.id.uuidString
            submenu.addItem(item)
        }
        if items.isEmpty { submenu.addItem(withTitle: BiscuitLocalization.string("No saved items"), action: nil, keyEquivalent: "") }
        submenu.addItem(.separator())
        add(submenu, "Show All History…", #selector(showLibrary))
        parent.submenu = submenu
        return parent
    }

    @objc private func recopyRecent(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String,
              let id = UUID(uuidString: value),
              let store = library.store,
              let record = store.items.first(where: { $0.id == id }) else { return }
        do {
            try store.copyToPasteboard(id)
            if record.kind == .text, let text = record.text {
                lastText = text
                copyNotification.showCopiedText(text)
            } else {
                copyNotification.showCopiedImage()
            }
        } catch { message(BiscuitLocalization.string("Cannot re-copy history"), error.localizedDescription) }
    }

    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, shortcutIndex: Int? = nil) {
        let item = menu.addItem(withTitle: BiscuitLocalization.string(title), action: action, keyEquivalent: "")
        item.target = self
        if let shortcutIndex {
            let (code, modifiers) = shortcut(shortcutIndex)
            if let equivalent = SettingsPreferences.shortcutKeyEquivalent(code) {
                item.keyEquivalent = equivalent
                item.keyEquivalentModifierMask = shortcutModifierFlags(modifiers)
            }
        }
    }
    private func notifyCopied(_ text: String?) {
        if let text {
            copyNotification.showCopiedText(text)
        } else {
            copyNotification.showCopiedImage()
        }
    }

    func copyOfferPreferenceChanged(enabled: Bool) {
        copyNotification.updateOfferPreference(enabled)
    }
    @objc func showMeasurementSummary() {
        MeasurementLogger.showSummary()
    }

    @objc func checkForUpdates() {
#if BISCUIT_SMOKE
        guard !updateConfirmationInProgress, !updaterMessageInProgress,
              let parent = validatedUpdaterSheetParent(settings, context: "manual update check") else { return }
        Task { await performUpdateCheck(manual: true, sheetParent: parent) }
#else
        Task { await performUpdateCheck(manual: true) }
#endif
    }

    func automaticUpdateChecksChanged(enabled: Bool) {
        automaticUpdateCheckTask?.cancel()
        automaticUpdateCheckTask = nil
        guard enabled else { return }
        scheduleAutomaticUpdateCheck(afterNanoseconds: 1_000_000_000)
    }

    private func scheduleAutomaticUpdateCheck(afterNanoseconds delay: UInt64) {
        automaticUpdateCheckTask?.cancel()
#if BISCUIT_SMOKE
        guard smokeUpdateSourceConfigurationError == nil else { return }
#endif
        guard BiscuitUpdatePreferences.shouldCheckAutomatically(defaults: BiscuitPreferences.defaults) else { return }
        automaticUpdateCheckTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: delay) }
            catch { return }
            guard let self,
                  !Task.isCancelled,
                  BiscuitUpdatePreferences.shouldCheckAutomatically(defaults: BiscuitPreferences.defaults) else { return }
            await self.performUpdateCheck(manual: false)
        }
    }

#if BISCUIT_SMOKE
    private func validatedUpdaterSheetParent(_ candidate: NSWindow?, context: String) -> NSWindow? {
        func fail(_ reason: String) -> NSWindow? {
            fputs("BISCUIT_SMOKE updater sheet \(context) failed closed: \(reason)\n", stderr)
            return nil
        }

        guard let candidate,
              let storedSettings = settings,
              let settingsController = settingsController,
              storedSettings === candidate,
              settingsController.window === candidate,
              candidate.isVisible,
              !candidate.isMiniaturized else {
            return fail("the existing Settings window is missing, closed, or not visible")
        }
        guard let configuredScreen = BiscuitPresentation.qaScreen(),
              configuredScreen.visibleFrame.contains(candidate.frame) else {
            return fail("the Settings window is not fully inside the configured built-in visible frame")
        }
        return candidate
    }

    private func showUpdaterMessage(_ title: String, _ detail: String, sheetParent: NSWindow?) async {
        guard let parent = validatedUpdaterSheetParent(sheetParent, context: title) else { return }
        guard !updaterMessageInProgress else {
            fputs("BISCUIT_SMOKE updater message already pending; suppressed duplicate sheet: \(title)\n", stderr)
            return
        }

        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        BiscuitLocalization.applyInterfaceDirection(to: alert)
        updaterMessageInProgress = true
        rebuildMenu()
        defer {
            updaterMessageInProgress = false
            rebuildMenu()
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            BiscuitPresentation.beginSheet(alert, for: parent) { _ in
                continuation.resume()
            }
        }
    }
#else
    private func showUpdaterMessage(_ title: String, _ detail: String, sheetParent _: NSWindow?) async {
        message(title, detail)
    }
#endif

    private func performUpdateCheck(manual: Bool, sheetParent: NSWindow? = nil) async {
#if BISCUIT_SMOKE
        if let smokeUpdateSourceConfigurationError {
            if manual {
                await showUpdaterMessage(
                    BiscuitLocalization.string("Update Check Failed"),
                    BiscuitLocalization.string(smokeUpdateSourceConfigurationError),
                    sheetParent: sheetParent
                )
            }
            return
        }
#endif
        guard !updateCheckInProgress, !updateInstallationInProgress else {
            if manual {
                await showUpdaterMessage(
                    BiscuitLocalization.string("Update Check"),
                    BiscuitLocalization.string("An update check or installation is already in progress."),
                    sheetParent: sheetParent
                )
            }
            return
        }
        updateCheckInProgress = true
        BiscuitUpdatePreferences.recordCheck(defaults: BiscuitPreferences.defaults)
        rebuildMenu()
        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
        do {
            let result = try await updateClient.check(installedVersion: currentVersion)
            switch result {
            case .updateAvailable(let release):
                availableUpdate = release
                if manual {
                    await showUpdaterMessage(
                        BiscuitLocalization.string("Update Available"),
                        BiscuitLocalization.format(
                            "Version %@ is available. Choose Install Update from the menu to download and verify it; Biscuit never installs updates automatically.",
                            arguments: [release.version.description]
                        ),
                        sheetParent: sheetParent
                    )
                }
            case .upToDate:
                availableUpdate = nil
                if manual {
                    await showUpdaterMessage(
                        BiscuitLocalization.string("Biscuit Is Up to Date"),
                        BiscuitLocalization.format("Biscuit is up to date (version %@).", arguments: [currentVersion]),
                        sheetParent: sheetParent
                    )
                }
            case .noPublishedRelease:
                availableUpdate = nil
                if manual {
                    await showUpdaterMessage(
                        BiscuitLocalization.string("No Published Release"),
                        BiscuitLocalization.string("No published Biscuit release is available at the configured GitHub source. No files were downloaded."),
                        sheetParent: sheetParent
                    )
                }
            case .noCompatibleRelease:
                availableUpdate = nil
                if manual {
                    await showUpdaterMessage(
                        BiscuitLocalization.string("No Compatible Release"),
                        BiscuitLocalization.string("Published Biscuit releases exist, but none has a compatible semantic version. No files were downloaded."),
                        sheetParent: sheetParent
                    )
                }
            }
        } catch {
            if manual {
                await showUpdaterMessage(
                    BiscuitLocalization.string("Update Check Failed"),
                    BiscuitLocalization.format("Could not check for updates: %@", arguments: [error.localizedDescription]),
                    sheetParent: sheetParent
                )
            }
        }
        updateCheckInProgress = false
        rebuildMenu()
    }


    @objc private func installAvailableUpdate() {
#if BISCUIT_SMOKE
        guard let release = availableUpdate,
              !updateInstallationInProgress,
              !updateCheckInProgress,
              !updateConfirmationInProgress,
              !updaterMessageInProgress else { return }
        guard let parent = validatedUpdaterSheetParent(settings, context: "install confirmation") else { return }
#else
        guard let release = availableUpdate, !updateInstallationInProgress, !updateCheckInProgress else { return }
#endif
        let confirmation = NSAlert()
        confirmation.messageText = BiscuitLocalization.format("Install Biscuit %@?", arguments: [release.version.description])
        confirmation.informativeText = BiscuitLocalization.string(
            "Biscuit downloads the configured GitHub release, verifies its SHA-256 digest when published, bundle identity, version, universal architectures, macOS compatibility, and code signature, then keeps your current app as a rollback copy before replacing it. Your data and preferences stay in place. The app folder must be writable; Biscuit never requests administrator access."
        )
        confirmation.addButton(withTitle: BiscuitLocalization.string("Install and Relaunch"))
        confirmation.addButton(withTitle: BiscuitLocalization.string("Cancel"))
        BiscuitLocalization.applyInterfaceDirection(to: confirmation)
#if !BISCUIT_SMOKE
        NSApp.activate(ignoringOtherApps: true)
#endif
#if BISCUIT_SMOKE
        updateConfirmationInProgress = true
        rebuildMenu()
        BiscuitPresentation.beginSheet(confirmation, for: parent) { [weak self] response in
            guard let self else { return }
            self.updateConfirmationInProgress = false
            self.rebuildMenu()
            guard response == .alertFirstButtonReturn,
                  let validatedParent = self.validatedUpdaterSheetParent(parent, context: "install confirmation completion") else { return }
            self.beginUpdateInstallation(release, sheetParent: validatedParent)
        }
#else
        guard BiscuitPresentation.runModal(confirmation) == .alertFirstButtonReturn else { return }
        beginUpdateInstallation(release, sheetParent: nil)
#endif
    }

    private func beginUpdateInstallation(_ release: BiscuitUpdateRelease, sheetParent: NSWindow?) {
        updateInstallationInProgress = true
        rebuildMenu()
        let installer = updateInstaller
        let client = updateClient
        let appURL = Bundle.main.bundleURL.standardizedFileURL
        let dataRoot = BiscuitUpdatePreferences.dataRoot()
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let rollback = try await Task.detached(priority: .utility) {
                    try await installer.install(release, using: client, at: appURL, dataRoot: dataRoot)
                }.value
                let terminationWasDeferred = self.deferredTermination
#if BISCUIT_SMOKE
                self.pendingUpdateSheetParent = sheetParent
#endif
                self.pendingUpdateRelaunch = (appURL, rollback)
                if terminationWasDeferred {
                    self.beginUpdatedApplicationRelaunch(NSApp)
                } else {
                    // Avoid holding this MainActor task inside AppKit's terminateLater run loop.
                    RunLoop.main.perform(inModes: [.common, .modalPanel]) {
                        MainActor.assumeIsolated { NSApp.terminate(nil) }
                    }
                }
            } catch {
                let terminationRequested = self.deferredTermination
                self.updateInstallationInProgress = false
                if !terminationRequested { self.deferredTermination = false }
                self.rebuildMenu()
                await self.showUpdaterMessage(
                    BiscuitLocalization.string("Update Installation Failed"),
                    BiscuitLocalization.format("Biscuit could not install the update: %@", arguments: [error.localizedDescription]),
                    sheetParent: sheetParent
                )
                if terminationRequested {
                    NSApp.reply(toApplicationShouldTerminate: true)
                }
            }
        }
    }


    private func shortcutModifierFlags(_ modifiers: UInt32) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        if modifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if modifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if modifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        return flags
    }
    @objc func copyArea() { capture.selectText() }
    @objc func imageArea() { capture.selectImage() }
    @objc func scrollingImage() { capture.selectScrollingImage() }
    @objc func translateArea() { capture.selectForText { [weak self] text in self?.rememberAndShow(text, .translate) } }
    @objc func learnArea() { capture.selectForText { [weak self] text in self?.rememberAndShow(text, .learn) } }
    private func rememberAndShow(_ text: String, _ mode: LanguageMode) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        lastText = text
        library.addText(text)
        language.show(text: text, mode: mode)
    }
    @objc func translateLast() { showLast(.translate) }
    @objc func learnLast() { showLast(.learn) }
    private func showLast(_ mode: LanguageMode) {
        guard !lastText.isEmpty else {
            message(
                BiscuitLocalization.string("No captured text yet"),
                BiscuitLocalization.string("Capture an area first, or choose Translate Clipboard Text.")
            )
            return
        }
        language.show(text: lastText, mode: mode)
    }
    @objc func translateClipboard() { useClipboard(.translate) }
    @objc func learnClipboard() { useClipboard(.learn) }
    private func useClipboard(_ mode: LanguageMode) {
        guard let text = NSPasteboard.general.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            message(BiscuitLocalization.string("No clipboard text"), BiscuitLocalization.string("Copy some text first."))
            return
        }
        language.show(text: text, mode: mode)
    }
    @objc func showLibrary() { library.show() }
    @objc func showTodos() { todos.toggle() }
    @objc func showStudyNotes() { language.showStudyNotes() }
    @objc func permissions() {
        let alert = NSAlert()
        alert.messageText = BiscuitLocalization.string("Screen capture permission")
        let status = CGPreflightScreenCaptureAccess()
            ? BiscuitLocalization.string("granted")
            : BiscuitLocalization.string("not granted")
        alert.informativeText = BiscuitLocalization.format(
            "biscuit needs Screen & System Audio Recording for selected-area capture. OCR, images, history and todos stay on this Mac. Global shortcuts use Carbon and do not require Accessibility. Translation never starts until you choose Translate or Explain in its window.\n\nCurrent screen recording status: %@.",
            arguments: [status]
        )
        alert.addButton(withTitle: BiscuitLocalization.string("Open System Settings"))
        alert.addButton(withTitle: BiscuitLocalization.string("Request Permission"))
        alert.addButton(withTitle: BiscuitLocalization.string("Close"))
        BiscuitLocalization.applyInterfaceDirection(to: alert)
#if !BISCUIT_SMOKE
        NSApp.activate(ignoringOtherApps: true)
#endif
        switch BiscuitPresentation.runModal(alert) {
        case .alertFirstButtonReturn: NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        case .alertSecondButtonReturn: _ = CGRequestScreenCaptureAccess()
        default: break
        }
    }
    @objc func about() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? BiscuitLocalization.string("Unknown")
        message(
            BiscuitLocalization.format("biscuit %@", arguments: [version]),
            BiscuitLocalization.string("Independent open-source macOS capture, OCR, translation, history and todos.\nMIT licensed. Unlimited local history and search are always included.")
        )
    }
    @objc func quit() {
        guard !deferredTermination else { return }
        NSApp.terminate(nil)
    }
    func message(_ title: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        BiscuitLocalization.applyInterfaceDirection(to: alert)
#if !BISCUIT_SMOKE
        NSApp.activate(ignoringOtherApps: true)
#endif
        _ = BiscuitPresentation.runModal(alert)
    }

    private func registerHotkeys() {
        hotkeys.forEach { UnregisterEventHotKey($0) }; hotkeys.removeAll(); shortcutErrors.removeAll()
        if handler == nil {
            var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let owner = Unmanaged.passUnretained(self).toOpaque()
            InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                var id = EventHotKeyID()
                let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
                guard result == noErr else { return result }
                MainActor.assumeIsolated { Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue().performShortcut(Int(id.id)) }
                return noErr
            }, 1, &event, owner, &handler)
        }
        for index in Self.shortcutNames.indices {
            let (code, modifiers) = shortcut(index)
            var ref: EventHotKeyRef?
            let result = RegisterEventHotKey(code, modifiers, EventHotKeyID(signature: 0x42495343, id: UInt32(index)), GetApplicationEventTarget(), 0, &ref)
            if result == noErr, let ref { hotkeys.append(ref) }
            else {
                let name = BiscuitLocalization.string(Self.shortcutNames[index])
                shortcutErrors.append(BiscuitLocalization.format("%@: registration failed (%d). Choose another shortcut; macOS may reserve it.", arguments: [name, Int(result)]))
            }
        }
        settingsController?.updateShortcutStatus(shortcutErrors)
    }
    private func performShortcut(_ index: Int) {
        switch index {
        case 0:
            if !copyNotification.repeatCopy() { copyArea() }
        case 1:
            if let text = copyNotification.takeTranslationText() {
                language.show(text: text, mode: .translate)
            } else {
                translateArea()
            }
        case 2: learnArea()
        case 3: showTodos()
        case 4: imageArea()
        case 5: capture.selectScrollingImage()
        default: break
        }
    }
    private func shortcut(_ index: Int) -> (UInt32, UInt32) {
        SettingsPreferences.resolvedShortcut(
            index: index,
            defaults: BiscuitPreferences.defaults,
            defaultCodes: Self.defaultCodes,
            defaultModifiers: Self.defaultModifiers
        ) ?? (0, 0)
    }
    func settingsShortcut(_ index: Int) -> (UInt32, UInt32) { shortcut(index) }

    func saveSettingsShortcut(_ index: Int, code: UInt32, modifiers: UInt32) {
        BiscuitPreferences.defaults.set(Int(code), forKey: "shortcut.\(index).code")
        BiscuitPreferences.defaults.set(Int(modifiers), forKey: "shortcut.\(index).modifiers")
        registerHotkeys()
    }

    func resetSettingsShortcut(_ index: Int) -> (UInt32, UInt32) {
        guard let value = SettingsPreferences.resetShortcut(
            index: index,
            defaults: BiscuitPreferences.defaults,
            defaultCodes: Self.defaultCodes,
            defaultModifiers: Self.defaultModifiers
        ) else { return (0, 0) }
        registerHotkeys()
        return value
    }

    func settingsShortcutRecording(_ recording: Bool) {
        if recording {
            hotkeys.forEach { UnregisterEventHotKey($0) }
            hotkeys.removeAll()
        } else {
            registerHotkeys()
        }
    }

    var loginAtLaunchEnabled: Bool { SMAppService.mainApp.status == .enabled }

    @objc func showSettings() {
        if let settings {
            BiscuitLocalization.applyInterfaceDirection(to: settings)
            guard BiscuitPresentation.show(settings) else { return }
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let controller = BiscuitSettingsWindowController(owner: self, capture: capture, library: library, language: language)
        settingsController = controller
        let window = controller.window
        BiscuitLocalization.applyInterfaceDirection(to: window)
        window.title = BiscuitLocalization.string("biscuit Settings")
        window.isReleasedWhenClosed = false
        window.delegate = self
        settings = window
        registerHotkeys()
        BiscuitPresentation.center(window)
        guard BiscuitPresentation.show(window) else { return }
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === settings else { return }
        closing.makeFirstResponder(nil)
        settings = nil
        settingsController = nil
        registerHotkeys()
    }

    @objc func changeEdge(_ sender: NSButton) { BiscuitPreferences.defaults.set(sender.state == .on, forKey: TodoController.edgeEnabledPreferenceKey) }
    @objc func changeLogin(_ sender: NSButton) {
        do { if sender.state == .on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
        catch { sender.state = SMAppService.mainApp.status == .enabled ? .on : .off; message(BiscuitLocalization.string("Login item could not be changed"), error.localizedDescription) }
    }


    #if BISCUIT_SMOKE
    func smokeSeedHistory(text: String, image: URL) { library.addText(text); library.addImage(image) }
    func smokeShowWindows() {
        library.show()
        language.show(text: "Hello world. This is a public biscuit fixture.", mode: .translate)
        showSettings()
        NativeAccountController.shared.showSettings()
        todos.toggle()
    }
    func smokeShowLearningWindow() { language.show(text: "Hello world. This is a public biscuit fixture.", mode: .learn) }
    func smokeUsePasteboard(_ pasteboard: NSPasteboard) {
        library.smokeUsePasteboard(pasteboard)
        language.smokeUsePasteboard(pasteboard)
    }
    #endif
}


final class BiscuitBackgroundView: NSView {
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }
}

final class TopStackView: NSStackView {
    override var isFlipped: Bool { true }
}


@MainActor
final class ShortcutRecorder: NSButton {
    private var code: UInt32
    private var modifiers: UInt32
    private var recording = false
    private let onChange: (UInt32, UInt32) -> Void
    private let onRecording: (Bool) -> Void
    init(code: UInt32, modifiers: UInt32, onRecording: @escaping (Bool) -> Void, onChange: @escaping (UInt32, UInt32) -> Void) {
        self.code = code; self.modifiers = modifiers; self.onRecording = onRecording; self.onChange = onChange
        super.init(frame: .zero); bezelStyle = .rounded; target = self; action = #selector(begin); refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unsupported") }
    func setShortcut(code: UInt32, modifiers: UInt32) {
        guard !recording else { return }
        self.code = code
        self.modifiers = modifiers
        refresh()
    }
    override var acceptsFirstResponder: Bool { true }
    @objc private func begin() {
        window?.makeFirstResponder(self)
        recording = true; title = BiscuitLocalization.string("Press shortcut…"); onRecording(true)
    }
    override func resignFirstResponder() -> Bool {
        if recording { recording = false; refresh(); onRecording(false) }
        return super.resignFirstResponder()
    }
    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        if event.keyCode == 53 { recording = false; refresh(); onRecording(false); return }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.intersection([.command, .option, .control]).isEmpty else { NSSound.beep(); return }
        code = UInt32(event.keyCode); modifiers = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }; if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }; if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        recording = false; onChange(code, modifiers); onRecording(false); refresh()
    }
    private func refresh() {
        let names: [UInt32: String] = [8:"C",17:"T",37:"L",2:"D",21:"4",23:"5",4:"H",1:"S",0:"A",35:"P",49:BiscuitLocalization.string("Space"),36:BiscuitLocalization.string("Return")]
        let key = names[code] ?? BiscuitLocalization.format("Key %d", arguments: [Int(code)])
        title = (modifiers & UInt32(controlKey) != 0 ? "⌃" : "") + (modifiers & UInt32(optionKey) != 0 ? "⌥" : "") + (modifiers & UInt32(shiftKey) != 0 ? "⇧" : "") + (modifiers & UInt32(cmdKey) != 0 ? "⌘" : "") + key
    }
}

#if !BISCUIT_IMAGE_TITLE_LIFECYCLE_CHECKS && !BISCUIT_SECURE_STORE_DIAGNOSTICS_SMOKE && !BISCUIT_CHATGPT_ACCESS_SMOKE
@main
struct BiscuitMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate(); app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
#endif

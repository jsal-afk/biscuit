import AppKit
import Foundation

@MainActor
final class ChatGPTWebSettingsController: NSObject, NSWindowDelegate {
    static let shared = ChatGPTWebSettingsController()

    private let provider = ChatGPTWebProvider.shared
    private var window: NSWindow?
    private var statusLabel: NSTextField?
    private var runtimeLabel: NSTextField?
    private var browserLabel: NSTextField?
    private var modelPopup: NSPopUpButton?
    private var connectButton: NSButton?
    private var continueButton: NSButton?
    private var cancelLoginButton: NSButton?
    private var disconnectButton: NSButton?
    private var downloadButton: NSButton?
    private var removeRuntimeButton: NSButton?
    private var loginTask: Task<Void, Never>?
    private var isBusy = false
    private var canDisconnect = false

    private override init() { super.init() }

    func show() {
        if window == nil { buildWindow() }
        refreshLocalState()
        guard BiscuitPresentation.show(window) else { return }
        NSApp.activate(ignoringOtherApps: true)
        if provider.runtime.runtimeIsPresent, provider.runtime.browserRuntimeIsPresent {
            Task { await refreshRemoteStatus() }
        }
    }

    private func buildWindow() {
        let created = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 700),
                               styleMask: [.titled, .closable, .miniaturizable],
                               backing: .buffered, defer: false)
        created.title = BiscuitLocalization.string("biscuit ChatGPT Web Provider")
        created.isReleasedWhenClosed = false
        created.delegate = self

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 10
        root.translatesAutoresizingMaskIntoConstraints = false

        let heading = NSTextField(labelWithString: "ChatGPT Web · usage 닳지 않고 무제한으로 쓰기")
        heading.font = .systemFont(ofSize: 16, weight: .semibold)
        root.addArrangedSubview(heading)

        let usage = NSTextField(wrappingLabelWithString: BiscuitLocalization.string("This browser-only route uses your ChatGPT chat allowance, not Codex quota. Availability and usage remain subject to your ChatGPT plan, model availability, and account limits; the selector label is not a promise of literal unlimited access. Text is sent only when you explicitly run a translation or learning request."))
        usage.maximumNumberOfLines = 0
        root.addArrangedSubview(usage)

        let status = NSTextField(wrappingLabelWithString: "")
        status.maximumNumberOfLines = 0
        status.identifier = NSUserInterfaceItemIdentifier("chatgptWeb.status")
        status.textColor = .secondaryLabelColor
        statusLabel = status
        root.addArrangedSubview(status)

        let runtimeRow = NSStackView()
        runtimeRow.orientation = .horizontal
        runtimeRow.alignment = .centerY
        runtimeRow.spacing = 8
        runtimeRow.addArrangedSubview(NSTextField(labelWithString: BiscuitLocalization.string("Electron runtime")))
        let runtime = NSTextField(wrappingLabelWithString: "")
        runtime.maximumNumberOfLines = 2
        runtime.textColor = .secondaryLabelColor
        runtimeLabel = runtime
        runtimeRow.addArrangedSubview(runtime)
        let download = NSButton(title: BiscuitLocalization.string("Download / Replace…"), target: self, action: #selector(downloadRuntime(_:)))
        downloadButton = download
        runtimeRow.addArrangedSubview(download)
        let remove = NSButton(title: BiscuitLocalization.string("Remove"), target: self, action: #selector(removeRuntime(_:)))
        removeRuntimeButton = remove
        runtimeRow.addArrangedSubview(remove)
        root.addArrangedSubview(runtimeRow)

        let browserRow = NSStackView()
        browserRow.orientation = .horizontal
        browserRow.alignment = .centerY
        browserRow.spacing = 8
        browserRow.addArrangedSubview(NSTextField(labelWithString: BiscuitLocalization.string("ChatGPT Web profile")))
        let browser = NSTextField(wrappingLabelWithString: "")
        browser.maximumNumberOfLines = 2
        browser.textColor = .secondaryLabelColor
        browserLabel = browser
        browserRow.addArrangedSubview(browser)
        root.addArrangedSubview(browserRow)

        let modelRow = NSStackView()
        modelRow.orientation = .horizontal
        modelRow.alignment = .centerY
        modelRow.spacing = 8
        modelRow.addArrangedSubview(NSTextField(labelWithString: BiscuitLocalization.string("ChatGPT Web model")))
        let models = NSPopUpButton()
        models.addItem(withTitle: BiscuitLocalization.string("Connect to load available models"))
        models.isEnabled = false
        models.target = self
        models.action = #selector(modelChanged(_:))
        modelPopup = models
        modelRow.addArrangedSubview(models)
        root.addArrangedSubview(modelRow)

        let accountRow = NSStackView()
        accountRow.orientation = .horizontal
        accountRow.alignment = .centerY
        accountRow.spacing = 8
        let connect = NSButton(title: BiscuitLocalization.string("Connect / Retry Sign-in…"), target: self, action: #selector(connect(_:)))
        connect.bezelStyle = .rounded
        connect.identifier = NSUserInterfaceItemIdentifier("chatgptWeb.connect")
        connectButton = connect
        accountRow.addArrangedSubview(connect)
        let continueLogin = NSButton(title: BiscuitLocalization.string("Continue"), target: self, action: #selector(continueLogin(_:)))
        continueLogin.isEnabled = false
        continueLogin.identifier = NSUserInterfaceItemIdentifier("chatgptWeb.continue")
        continueLogin.isHidden = true
        continueButton = continueLogin
        accountRow.addArrangedSubview(continueLogin)
        let cancelLogin = NSButton(title: BiscuitLocalization.string("Cancel Sign-in"), target: self, action: #selector(cancelLogin(_:)))
        cancelLogin.isHidden = true
        cancelLoginButton = cancelLogin
        accountRow.addArrangedSubview(cancelLogin)
        let disconnect = NSButton(title: BiscuitLocalization.string("Disconnect…"), target: self, action: #selector(disconnect(_:)))
        disconnect.isEnabled = false
        disconnectButton = disconnect
        accountRow.addArrangedSubview(disconnect)
        root.addArrangedSubview(accountRow)

        let noticesRow = NSStackView()
        noticesRow.orientation = .horizontal
        noticesRow.alignment = .centerY
        noticesRow.spacing = 12
        noticesRow.addArrangedSubview(NSButton(title: BiscuitLocalization.string("ChatGPT Web provider notices…"), target: self, action: #selector(openProviderNotices(_:))))
        noticesRow.addArrangedSubview(NSButton(title: BiscuitLocalization.string("Electron runtime notices…"), target: self, action: #selector(openRuntimeNotices(_:))))
        root.addArrangedSubview(noticesRow)
        let recovery = NSTextField(wrappingLabelWithString: BiscuitLocalization.string("Connect downloads the official Electron 41.10.7 runtime only after confirmation and verifies the architecture-specific release ZIP and executable SHA-256 before use. The complete extracted release, including Electron.app and the ZIP-root LICENSE and LICENSES.chromium.html, stays private in Biscuit's data folder. ChatGPT Web uses a dedicated persistent Electron profile and the same named session partition; Biscuit never copies cookies or reads private history. Sign-in opens a visible Biscuit-owned ChatGPT window only after you choose Connect. The selected model remains the one shown in ChatGPT; Biscuit does not change or silently substitute it. Electron's Chromium sandbox and OS protections remain enabled. Disconnect is available only for a Biscuit-managed profile; an adopted existing session is preserved."))

        recovery.maximumNumberOfLines = 0
        recovery.textColor = .secondaryLabelColor
        root.addArrangedSubview(recovery)

        let content = NSView()
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            root.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            root.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -18),
            runtime.widthAnchor.constraint(greaterThanOrEqualToConstant: 250),
            browser.widthAnchor.constraint(greaterThanOrEqualToConstant: 250),
            models.widthAnchor.constraint(greaterThanOrEqualToConstant: 340)
        ])
        for arranged in root.arrangedSubviews {
            arranged.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        }
        created.contentView = content
        BiscuitLocalization.applyInterfaceDirection(to: created)
        window = created
    }

    private func refreshLocalState() {
        let runtimeDirectory = provider.runtime.runtimeDirectoryURL
        let runtimeExists = runtimeDirectory.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        if provider.runtime.runtimeIsPresent {
            runtimeLabel?.stringValue = BiscuitLocalization.string("Electron 41.10.7 is available; Biscuit checks its pinned executable SHA-256 before launch.")
        } else if runtimeExists {
            runtimeLabel?.stringValue = BiscuitLocalization.string("The installed runtime failed verification. Replace it before use.")
        } else if runtimeDirectory == nil {
            runtimeLabel?.stringValue = BiscuitLocalization.string("No pinned Electron runtime is available for this architecture.")
        } else {
            runtimeLabel?.stringValue = BiscuitLocalization.string("Not installed. Download requires a separate confirmation.")
        }
        browserLabel?.stringValue = provider.runtime.storedSessionExists
            ? BiscuitLocalization.string("A persistent ChatGPT Web profile is available. Biscuit reuses its identity without exporting session data.")
            : BiscuitLocalization.string("Connect creates a dedicated persistent ChatGPT Web profile; personal browsers are not used.")
        downloadButton?.isEnabled = !isBusy && runtimeDirectory != nil
        removeRuntimeButton?.isEnabled = !isBusy && runtimeExists
        connectButton?.isEnabled = !isBusy
        cancelLoginButton?.isEnabled = loginTask != nil
        disconnectButton?.isEnabled = !isBusy && canDisconnect
        if !provider.runtime.runtimeIsPresent {
            if runtimeExists {
                setStatus(BiscuitLocalization.string("The Electron runtime failed verification. Replace it before connecting."))
            } else if provider.runtime.storedSessionExists {
                setStatus(BiscuitLocalization.string("A Biscuit-owned ChatGPT Web session exists. Install a verified Electron runtime to inspect it; the saved profile will not be changed."))
            } else {
                setStatus(BiscuitLocalization.string("Not connected. Connect installs the optional private Electron runtime after confirmation."))
            }
        } else if !provider.runtime.browserRuntimeIsPresent {
            setStatus(BiscuitLocalization.string("Connect downloads Biscuit's dedicated Electron runtime. No system browser is used."))
        }
    }

    private func refreshRemoteStatus() async {
        guard provider.runtime.runtimeIsPresent, provider.runtime.browserRuntimeIsPresent else { return }
        do {
            let status = try await provider.status()
            update(status)
        } catch {
            setStatus(error.localizedDescription)
            replaceModels(nil)
        }
        refreshLocalStateWithoutStatus()
    }

    private func refreshLocalStateWithoutStatus() {
        let runtimeExists = provider.runtime.runtimeDirectoryURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        if provider.runtime.runtimeIsPresent {
            runtimeLabel?.stringValue = BiscuitLocalization.string("Electron 41.10.7 is available; Biscuit checks its pinned executable SHA-256 before launch.")
        } else if runtimeExists {
            runtimeLabel?.stringValue = BiscuitLocalization.string("The installed Electron runtime failed verification. Replace it before use.")
        } else {
            runtimeLabel?.stringValue = BiscuitLocalization.string("Not installed. Download requires a separate confirmation.")
        }
        browserLabel?.stringValue = provider.runtime.storedSessionExists
            ? BiscuitLocalization.string("A persistent ChatGPT Web profile is available.")
            : BiscuitLocalization.string("Connect creates a dedicated persistent ChatGPT Web profile.")
        removeRuntimeButton?.isEnabled = !isBusy && runtimeExists
        disconnectButton?.isEnabled = !isBusy && canDisconnect
    }

    private func update(_ status: ChatGPTWebStatus) {
        if status.connected {
            setStatus(BiscuitLocalization.string("Connected to ChatGPT Web. The browser-selected model remains unchanged. Requests use temporary chats, no local tools, and ChatGPT chat allowance—not Codex quota or the direct API route."))
        } else if status.needsReconnect {
            setStatus(BiscuitLocalization.string("The saved ChatGPT Web session could not be verified. Retry sign-in; no other provider will be used."))
        } else {
            setStatus(BiscuitLocalization.string("Not connected. Choose Connect / Retry Sign-in when ready; no login starts automatically."))
        }
        replaceModels(ChatGPTWebModelSelection.confirmedRoutes(
            connected: status.connected,
            reportedRoutes: status.modelRoutes
        ))
        canDisconnect = status.canDisconnect
        disconnectButton?.isEnabled = !isBusy && canDisconnect
    }

    private func replaceModels(_ routeInventory: [ChatGPTWebModelRoute]?) {
        guard let modelPopup else { return }
        modelPopup.removeAllItems()
        modelPopup.addItem(withTitle: BiscuitLocalization.string("Browser-selected ChatGPT model"))
        modelPopup.lastItem?.representedObject = NSNull()

        let routes = routeInventory ?? []
        for route in routes {
            modelPopup.addItem(withTitle: route.displayName)
            modelPopup.lastItem?.representedObject = route.slug
            modelPopup.lastItem?.toolTip = route.description
        }

        let saved = provider.selectedModelSlug
        let resolution = ChatGPTWebModelSelection.resolve(savedSlug: saved, routeInventory: routeInventory)
        let selectedIndex: Int
        switch resolution {
        case .browserSelected:
            selectedIndex = 0
        case .available(let index):
            selectedIndex = index + 1
        case .inventoryUnknown(let slug):
            modelPopup.addItem(withTitle: BiscuitLocalization.format("Saved model — %1$@", arguments: [slug]))
            modelPopup.lastItem?.representedObject = slug
            selectedIndex = modelPopup.numberOfItems - 1
        case .unavailable(let slug):
            modelPopup.addItem(withTitle: BiscuitLocalization.format("Saved model unavailable — %1$@", arguments: [slug]))
            modelPopup.lastItem?.representedObject = slug
            modelPopup.lastItem?.isEnabled = false
            selectedIndex = modelPopup.numberOfItems - 1
        }
        modelPopup.selectItem(at: selectedIndex)
        modelPopup.isEnabled = true
    }

    private func setStatus(_ message: String) {
        statusLabel?.textColor = .secondaryLabelColor
        statusLabel?.stringValue = message
    }

    private func confirmRuntimeDownload(replacing: Bool) async -> Bool {
        guard let window else { return false }
        return await withCheckedContinuation { continuation in
            let alert = NSAlert()
            alert.messageText = BiscuitLocalization.string(replacing ? "Replace Biscuit's private Web runtimes?" : "Download the private ChatGPT Web runtimes?")
            alert.informativeText = BiscuitLocalization.string("Biscuit downloads official Electron 41.10.7 (113 MiB on Apple silicon or 119 MiB on Intel; extracted payload about 275 MiB and 303 MiB respectively). The ZIP and Electron executable are SHA-256 verified before use. Biscuit retains the complete official runtime payload and its LICENSE / LICENSES.chromium.html notices in a private folder. Nothing is installed globally; personal browser profiles, Codex, and shared runtimes are untouched. Electron's sandbox and OS protections remain enabled.")
            alert.addButton(withTitle: BiscuitLocalization.string(replacing ? "Replace Runtime" : "Download Runtime"))
            alert.addButton(withTitle: BiscuitLocalization.string("Cancel"))
            BiscuitLocalization.applyInterfaceDirection(to: alert)
            BiscuitPresentation.beginSheet(alert, for: window) { response in
                continuation.resume(returning: response == .alertFirstButtonReturn)
            }
        }
    }

    private func confirmDisconnect() async -> Bool {
        guard let window else { return false }
        return await withCheckedContinuation { continuation in
            let alert = NSAlert()
            alert.messageText = BiscuitLocalization.string("Disconnect ChatGPT Web?")
            alert.informativeText = BiscuitLocalization.string("Disconnect removes only the Biscuit-managed ChatGPT Web profile. It does not affect your ChatGPT account, personal browser profiles, Codex, or a preserved adopted profile.")
            alert.addButton(withTitle: BiscuitLocalization.string("Disconnect"))
            alert.addButton(withTitle: BiscuitLocalization.string("Cancel"))
            BiscuitLocalization.applyInterfaceDirection(to: alert)
            BiscuitPresentation.beginSheet(alert, for: window) { response in
                continuation.resume(returning: response == .alertFirstButtonReturn)
            }
        }
    }

    private func confirmRuntimeRemoval() async -> Bool {
        guard let window else { return false }
        return await withCheckedContinuation { continuation in
            let alert = NSAlert()
            alert.messageText = BiscuitLocalization.string("Remove Biscuit's private Web runtimes?")
            alert.informativeText = BiscuitLocalization.string("This deletes only Biscuit's private Electron runtime payload. The ChatGPT Web profile and session descriptor remain; another use requires a verified runtime.")
            alert.addButton(withTitle: BiscuitLocalization.string("Remove Runtime"))
            alert.addButton(withTitle: BiscuitLocalization.string("Cancel"))
            BiscuitLocalization.applyInterfaceDirection(to: alert)
            BiscuitPresentation.beginSheet(alert, for: window) { response in
                continuation.resume(returning: response == .alertFirstButtonReturn)
            }
        }
    }

    private func setBusy(_ busy: Bool) {
        isBusy = busy
        downloadButton?.isEnabled = !busy && provider.runtime.runtimeDirectoryURL != nil
        removeRuntimeButton?.isEnabled = !busy && (provider.runtime.runtimeDirectoryURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false)
        connectButton?.isEnabled = !busy
        disconnectButton?.isEnabled = !busy && canDisconnect
        modelPopup?.isEnabled = !busy && (modelPopup?.numberOfItems ?? 0) > 0 && modelPopup?.titleOfSelectedItem != BiscuitLocalization.string("Connect to load available models")
        continueButton?.isEnabled = !busy && loginTask != nil && continueButton?.isHidden == false
        cancelLoginButton?.isEnabled = !busy && loginTask != nil
    }

    @objc private func connect(_ sender: Any?) {
        guard loginTask == nil else { return }
        loginTask = Task { [weak self] in
            guard let self else { return }
            do {
                guard self.provider.runtime.runtimeDirectoryURL != nil else {
                    self.loginTask = nil
                    self.setStatus(ChatGPTWebFailure.unsupportedArchitecture.localizedDescription)
                    return
                }
                if !self.provider.runtime.runtimeIsPresent || !self.provider.runtime.browserRuntimeIsPresent {
                    self.setBusy(true)
                    let replacing = self.provider.runtime.runtimeDirectoryURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
                    guard await self.confirmRuntimeDownload(replacing: replacing) else {
                        self.loginTask = nil
                        self.setBusy(false)
                        self.setStatus(BiscuitLocalization.string("Runtime download canceled. No runtime was installed and no login was started."))
                        return
                    }
                    self.setStatus(BiscuitLocalization.string("Downloading and verifying Biscuit's private Electron runtime…"))
                    try await self.provider.installRuntime(consented: true)
                    self.setBusy(false)
                }
                self.setBusy(true)
                self.continueButton?.isHidden = false
                self.continueButton?.isEnabled = false
                self.cancelLoginButton?.isHidden = false
                self.cancelLoginButton?.isEnabled = true
                self.setStatus(BiscuitLocalization.string("Starting Biscuit's dedicated Electron sign-in window. Complete ChatGPT sign-in there; Biscuit does not export cookies or inspect private history."))
                let status = try await self.provider.login(
                    onBrowserOpened: { [weak self] in
                        guard let self else { return }
                        self.continueButton?.isEnabled = true
                        self.setStatus(BiscuitLocalization.string("The dedicated Electron window is ready. Complete sign-in there, then choose Continue; Biscuit verifies the ChatGPT composer without exporting session data."))
                    }
                )
                self.loginTask = nil
                self.continueButton?.isHidden = true
                self.cancelLoginButton?.isHidden = true
                self.setBusy(false)
                self.update(status)
            } catch {
                self.loginTask = nil
                self.continueButton?.isHidden = true
                self.cancelLoginButton?.isHidden = true
                self.setBusy(false)
                self.setStatus(error.localizedDescription)
                self.refreshLocalStateWithoutStatus()
            }
        }
    }

    @objc private func continueLogin(_ sender: Any?) {
        guard loginTask != nil, continueButton?.isEnabled == true else { return }
        continueButton?.isEnabled = false
        setStatus(BiscuitLocalization.string("Verifying the ChatGPT session from its visible composer. The saved profile is preserved if verification fails."))
        provider.continueLogin()
    }

    @objc private func cancelLogin(_ sender: Any?) {
        guard loginTask != nil else { return }
        continueButton?.isEnabled = false
        cancelLoginButton?.isEnabled = false
        setStatus(BiscuitLocalization.string("Canceling sign-in. Any previous verified session will be retained."))
        provider.cancelLogin()
    }

    @objc private func disconnect(_ sender: Any?) {
        guard !isBusy else { return }
        Task { [weak self] in
            guard let self else { return }
            self.setBusy(true)
            guard await self.confirmDisconnect() else {
                self.setBusy(false)
                return
            }
            self.setStatus(BiscuitLocalization.string("Disconnecting Biscuit's managed ChatGPT Web profile…"))
            do {
                try await self.provider.disconnect()
                self.replaceModels([])
                self.setStatus(BiscuitLocalization.string("Disconnected. Biscuit's managed Web profile was removed; your ChatGPT account and personal browser profiles were not changed."))
            } catch {
                self.setStatus(error.localizedDescription)
            }
            self.setBusy(false)
            self.refreshLocalStateWithoutStatus()
        }
    }

    @objc private func downloadRuntime(_ sender: Any?) {
        guard !isBusy else { return }
        Task { [weak self] in
            guard let self else { return }
            self.setBusy(true)
            let replacing = self.provider.runtime.runtimeDirectoryURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
            guard await self.confirmRuntimeDownload(replacing: replacing) else {
                self.setBusy(false)
                return
            }
            self.setStatus(BiscuitLocalization.string("Downloading and verifying the official private Electron runtime…"))
            do {
                try await self.provider.installRuntime(consented: true, replacing: true)
                self.setStatus(BiscuitLocalization.string("Electron 41.10.7 and the complete official runtime notices were verified and stored privately. No login was started."))
            } catch {
                self.setStatus(error.localizedDescription)
            }
            self.setBusy(false)
            self.refreshLocalStateWithoutStatus()
        }
    }

    @objc private func removeRuntime(_ sender: Any?) {
        guard !isBusy else { return }
        Task { [weak self] in
            guard let self else { return }
            self.setBusy(true)
            guard await self.confirmRuntimeRemoval() else {
                self.setBusy(false)
                return
            }
            do {
                try await self.provider.removeRuntime()
                self.setStatus(BiscuitLocalization.string("Biscuit's private Electron runtime was removed. The saved ChatGPT Web session remains; no login or request was made."))
            } catch {
                self.setStatus(error.localizedDescription)
            }
            self.setBusy(false)
            self.refreshLocalStateWithoutStatus()
        }
    }


    @objc private func modelChanged(_ sender: NSPopUpButton) {
        guard let selected = sender.selectedItem?.representedObject else { return }
        if selected is NSNull {
            provider.setSelectedModelSlug(nil)
        } else if let slug = selected as? String {
            provider.setSelectedModelSlug(slug)
        }
    }

    @objc private func openProviderNotices(_ sender: Any?) {
        guard let resources = Bundle.main.resourceURL?.appendingPathComponent("ChatGPTWeb/Notices", isDirectory: true) else {
            setStatus(BiscuitLocalization.string("ChatGPT Web provider notices are missing from this Biscuit build."))
            return
        }
        let notice = resources.appendingPathComponent("THIRD-PARTY-NOTICES.txt")
        guard FileManager.default.isReadableFile(atPath: notice.path), NSWorkspace.shared.open(notice) else {
            setStatus(BiscuitLocalization.string("ChatGPT Web provider notices are not available. Reinstall or rebuild Biscuit with the bundled notices."))
            return
        }
        setStatus(BiscuitLocalization.string("Opened the ChatGPT Web provider licenses and notices."))
    }

    @objc private func openRuntimeNotices(_ sender: Any?) {
        guard let runtimeDirectory = provider.runtime.runtimeDirectoryURL else {
            setStatus(BiscuitLocalization.string("Electron runtime notices are not available for this architecture."))
            return
        }
        let license = runtimeDirectory.appendingPathComponent("LICENSE")
        let chromiumNotice = runtimeDirectory.appendingPathComponent("LICENSES.chromium.html")
        guard FileManager.default.isReadableFile(atPath: license.path),
              FileManager.default.isReadableFile(atPath: chromiumNotice.path),
              NSWorkspace.shared.open(license), NSWorkspace.shared.open(chromiumNotice) else {
            setStatus(BiscuitLocalization.string("The official Electron runtime notices are unavailable. Replace the verified runtime."))
            return
        }
        setStatus(BiscuitLocalization.string("Opened the official Electron and Chromium runtime notices."))
    }
    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === window else { return }
        if loginTask != nil { provider.cancelLogin() }
        window = nil
        statusLabel = nil
        runtimeLabel = nil
        browserLabel = nil
        modelPopup = nil
        connectButton = nil
        continueButton = nil
        cancelLoginButton = nil
        disconnectButton = nil
        downloadButton = nil
        removeRuntimeButton = nil
    }
}

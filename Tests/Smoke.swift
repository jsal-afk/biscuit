import AppKit
import CryptoKit
import Foundation

/// Compiled only by scripts/smoke.sh, never shipped in the release executable.
@MainActor
enum BiscuitSmoke {
    private struct Failure: Error, CustomStringConvertible { let description: String }
    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(description: message) }
    }

    static func run(app: AppDelegate) async {
        var records: [[String: String]] = []
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["BISCUIT_DATA_DIR"], let output = environment["BISCUIT_SMOKE_OUTPUT"],
              let suite = environment["BISCUIT_PREFERENCES_SUITE"], suite.hasPrefix("org.biscuit.smoke.") else {
            fputs("Smoke requires isolated data, output, and org.biscuit.smoke.* preferences.\n", stderr)
            exit(2)
        }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        let report = URL(fileURLWithPath: output, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: report, withIntermediateDirectories: true)
            try String(ProcessInfo.processInfo.processIdentifier).write(to: report.appendingPathComponent("pid"), atomically: true, encoding: .utf8)
            if CommandLine.arguments.contains("--smoke-storage") {
                try AccountSmoke.keychainPersistenceChecks(service: suite)
                records.append(["scenario": "Production Keychain add/read/update/delete", "status": "PASS", "detail": "Synthetic values, task-only service; no login, provider, Claude or user credential access."])
                try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys]).write(to: report.appendingPathComponent("results.json"), options: .atomic)
                try Data("complete\n".utf8).write(to: report.appendingPathComponent("complete"), options: .atomic)
                print("BISCUIT_STORAGE_SMOKE_PASS")
                fflush(stdout)
                NSApp.terminate(nil)
                return
            }
            try SubscriptionSmoke.run()
            try await NativeUsageSmoke.run()
            records.append(["scenario": "Native ChatGPT usage windows and reasoning-effort request payload", "status": "PASS", "detail": "Injected public synthetic ChatGPT transport fixture only; no account-store access, live network, Claude branch, or authenticated provider acceptance."])
            records.append(["scenario": "Native SSE framing, completion/failure boundaries, and HTTP credential redaction", "status": "PASS", "detail": "Local synthetic protocol fixtures only; no account access, login, network request, or authenticated provider acceptance."])
            try await AccountSmoke.run(root: report)
            records.append(["scenario": "Native account state, refresh ownership, Codex source re-read, login race/cancellation, and secure persistence", "status": "PASS", "detail": "Synthetic credentials/transports and unique biscuit-only Keychain fixture; loopback browser callback only, no real owner login, credential source, or remote provider request."])
            let fixture = report.appendingPathComponent("public-table.png")
            try makeFixture().write(to: fixture)
            let text = try CaptureOCR.recognizeText(in: fixture)
            try text.write(to: report.appendingPathComponent("ocr.txt"), atomically: true, encoding: .utf8)
            try require(text.contains("Apple\t2\t3.50"), "Table OCR must preserve Apple/2/3.50 as spreadsheet cells. Actual: \(text)")
            try require(text.contains("Bread\t1\t4.00"), "Table OCR must preserve Bread/1/4.00 as spreadsheet cells.")
            try require(text.contains("Tea\t\t1.25"), "An empty middle table cell must not shift the price into the quantity column.")
            records.append(["scenario": "Vision OCR and table-aware TSV", "status": "PASS", "detail": text])
            try verifyAsymmetricComposition()
            records.append(["scenario": "Multi-display composition orientation and asymmetric tile placement", "status": "PASS", "detail": "Synthetic red lower-left and blue upper-right display regions retained orientation, offsets, and uncovered background."])

            try LibraryExportBehaviorChecks.run()
            records.append(["scenario": "LibraryStore image export replacement", "status": "PASS", "detail": "Synthetic PNG new/existing export, managed-source and same-path preservation, and the tested immutable-destination failure with staging cleanup."])
            try ImageEditorBehaviorChecks.run(in: report)
            records.append(["scenario": "Image editor actual-sidecar orientation, flattening, crop, pixelation, undo/redo, persistence, and export isolation", "status": "PASS", "detail": "The captured public-band source and editor sidecar assert upright point text in flattened output and Canvas previews at 50%, 100%, and 200%; generated pixel fixtures cover undo/redo, rollback, and missing-source rejection. Exact originals remain private and flattened exports are metadata-isolated."])
            try ScrollingCaptureBehaviorChecks.run()
            records.append(["scenario": "Scrolling capture overlap matching, ordered band stitching, gap recovery, cancellation, and pixel budget", "status": "PASS", "detail": "Generated uniquely labeled viewport fixtures exercise the production matcher and stitcher; no live screen capture or user data."])
            try await CaptureMeasurementScaleChecks.run()
            records.append(["scenario": "Capture measurement scale contract", "status": "PASS", "detail": "Production entry creation and JSONL logging preserve stitched scale/dimensions, failed stitched-write outcome, ordinary image/text rounding, and nil-image scale."])

            try StudyNotebookBehaviorChecks.run()
            records.append(["scenario": "Study notebook save, reopen, search, update, delete, legacy migration, failure recovery, and Markdown export", "status": "PASS", "detail": "Generated local fixtures only; no model/provider request, live clipboard, UI, or user notebook data."])
            try await BiscuitUpdateBehaviorChecks.run(sourceApp: Bundle.main.bundleURL)
            records.append([
                "scenario": "Updater release comparison, bundle-identity enforcement, opt-in policy, loopback download, integrity rejection, isolated install, and rollback",
                "status": "PASS",
                "detail": "Local loopback HTTP only; caller bundle identity was matched and a signed mismatched candidate rejected. All app changes occurred in disposable temporary copies; the current smoke executable and isolated user data remained unchanged."
            ])
            let storeRoot = root.appendingPathComponent("store-fixture", isDirectory: true)
            let library = try LibraryStore(dataDirectory: storeRoot)
            for index in 0..<25 {
                try library.addText("public record \(index): biscuit retention fixture")
                let imageFixture = report.appendingPathComponent("capture-\(index).png")
                try makeFixture(marker: index).write(to: imageFixture)
                try library.addImage(imageFixture, recognizedText: text)
            }
            let restarted = try LibraryStore(dataDirectory: storeRoot)
            try require(restarted.items.filter { $0.kind == .text }.count == 25, "All 25 unique text records must survive restart, beyond Free's 10-item ceiling.")
            try require(restarted.items.filter { $0.kind == .image }.count == 25, "All 25 images must survive restart by default.")
            let match = restarted.search("PUBLIC RECORD 0:")
            try require(match.count == 1 && match[0].text == "public record 0: biscuit retention fixture", "Case-insensitive search must find the oldest record.")
            let imageMatches = restarted.search("Apple")
            try require(imageMatches.count == 25 && imageMatches.allSatisfy { $0.kind == .image }, "Image OCR text must remain searchable after restart.")
            let board = NSPasteboard(name: NSPasteboard.Name("org.biscuit.smoke.\(UUID().uuidString)"))
            defer { board.releaseGlobally() }
            try restarted.copyToPasteboard(match[0].id, pasteboard: board)
            try require(board.string(forType: .string) == match[0].text, "Re-copy must return exact historical text after restart.")
            guard let imageItem = restarted.items.last(where: { $0.kind == .image }) else { throw Failure(description: "Oldest retained image missing") }
            try restarted.copyToPasteboard(imageItem.id, pasteboard: board)
            guard let copiedImageData = NSImage(pasteboard: board)?.tiffRepresentation else { throw Failure(description: "Historical image is not pastable") }
            let copiedImageText = try CaptureOCR.recognizeText(in: copiedImageData)
            try require(copiedImageText.contains("Capture 0"), "Re-copy must retrieve the oldest image, not the current/newest clipboard image.")
            do { try restarted.setImageLimit(2); throw Failure(description: "Destructive image trim must require explicit confirmation") }
            catch LibraryStoreError.confirmationRequired { }
            try restarted.setImageLimit(2, confirmTrim: true)
            try require(restarted.items.filter { $0.kind == .image }.count == 2, "Confirmed retention must keep exactly two newest images.")
            try require(restarted.items.filter { $0.kind == .text }.count == 25, "Image retention must never trim text.")
            let afterTrim = try LibraryStore(dataDirectory: storeRoot)
            try require(afterTrim.imageLimit == 2, "Explicit image retention must survive restart.")
            try afterTrim.setImageLimit(nil)
            let libraryExport = report.appendingPathComponent("export", isDirectory: true)
            try await verifyChatGPTWebConsentAndExportIsolation(store: afterTrim, exportURL: libraryExport, dataRoot: root, environment: environment)
            records.append(["scenario": "Unlimited persistence, search, historical text/image re-copy, confirmed retention, export", "status": "PASS", "detail": "25 text +25 image records restarted; oldest text/image re-copied; confirmed trim kept2 images and25 texts."])
            records.append(["scenario": "ChatGPT Web consent, profile identity, and export isolation", "status": "PASS", "detail": "The app-owned identity is recognized with owner-private storage; profile/session data stays outside library export."])

            let todo = try TodoStore(dataDirectory: storeRoot)
            let due = Date(timeIntervalSince1970: 1_800_000_000)
            let plain = try todo.add(text: "public plain task")
            let starred = try todo.add(text: "public starred task", dueDate: due)
            try todo.setStarred(true, for: starred.id)
            try todo.updateText("public edited starred task", for: starred.id)
            try todo.setCompleted(true, for: plain.id)
            let restartedTodos = try TodoStore(dataDirectory: storeRoot)
            try require(restartedTodos.items.first?.id == starred.id, "Starred task must sort before plain/completed tasks after restart.")
            try require(restartedTodos.items.first?.dueDate == due && restartedTodos.items.first?.text == "public edited starred task", "Todo date and edited text must persist exactly.")
            try require(restartedTodos.items.first(where: { $0.id == plain.id })?.isCompleted == true, "Completion must persist.")
            try restartedTodos.delete(plain.id)
            let afterDelete = try TodoStore(dataDirectory: storeRoot)
            try require(afterDelete.items.map(\.id) == [starred.id], "Deleted todo must remain absent on restart.")
            records.append(["scenario": "Todo add/edit/star/date/complete/delete/restart", "status": "PASS", "detail": "Exact task state and star-first ordering survived JSON reload."])
            let corruptRoot = root.appendingPathComponent("corrupt-fixture", isDirectory: true)
            try FileManager.default.createDirectory(at: corruptRoot, withIntermediateDirectories: true)
            let invalid = Data("not a history manifest".utf8)
            let corruptFile = corruptRoot.appendingPathComponent("library.json")
            try invalid.write(to: corruptFile)
            do { _ = try LibraryStore(dataDirectory: corruptRoot); throw Failure(description: "Corrupt history must not be silently reset") }
            catch LibraryStoreError.invalidManifest { }
            let retainedInvalid = try Data(contentsOf: corruptFile)
            try require(retainedInvalid == invalid, "Recovery failure must leave original history bytes untouched.")
            records.append(["scenario": "Corrupt history recovery boundary", "status": "PASS", "detail": "Invalid manifest rejected without overwriting its bytes."])

            let language = LanguageController(
                onCopied: { _ in },
                onOfferAfterCopyChanged: { _ in }
            )
            let capability = await language.nativeTranslationAvailability(text: "Hello world", targetIdentifier: "ko")
            records.append(["scenario": "Apple Translation capability without text submission", "status": "OBSERVED", "detail": capability])
            if environment["BISCUIT_SUBSCRIPTION_SMOKE"] == "1" {
                for mode in [LanguageMode.translate, .learn] {
                    let result: (String?, String?) = await withCheckedContinuation { continuation in
                        language.runPublicFixtureViaChatGPTForSmoke(mode: mode) { text, error in
                            continuation.resume(returning: (text, error))
                        }
                    }
                    if let error = result.1 { throw Failure(description: "Production subscription route failed: \(error)") }
                    guard let output = result.0 else { throw Failure(description: "Subscription route returned no text") }
                    try require(output.unicodeScalars.contains(where: { (0xAC00...0xD7AF).contains($0.value) }), "Korean fixture output must contain Korean, not an English placeholder.")
                    if mode == .learn { try require(output.contains("Hello") || output.contains("biscuit"), "Language lesson must discuss the supplied vocabulary, not an unrelated response.") }
                    let name = mode == .translate ? "translation" : "lesson"
                    try output.write(to: report.appendingPathComponent("subscription-\(name).txt"), atomically: true, encoding: .utf8)
                    records.append(["scenario": "Native ChatGPT subscription provider route \(name)", "status": "PASS", "detail": "This opt-in route submits only the fixed public English fixture using the configured native session; synthetic account tests never invoke it."])
                }
            }

            let fixtureView = NSImageView(frame: NSRect(x: 0, y: 0, width: 900, height: 450))
            fixtureView.image = NSImage(contentsOf: fixture)
            fixtureView.imageScaling = .scaleAxesIndependently
            let fixtureWindow = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 900, height: 450), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            fixtureWindow.title = "biscuit Public Capture Fixture"
            fixtureWindow.isReleasedWhenClosed = false
            fixtureWindow.contentView = fixtureView
            guard BiscuitPresentation.show(fixtureWindow) else {
                throw Failure(description: "Smoke fixture could not be placed on the configured built-in display.")
            }
            NSApp.activate(ignoringOtherApps: true)
            try await Task.sleep(nanoseconds: 500_000_000)
            if CGPreflightScreenCaptureAccess() {
                let rect = fixtureWindow.convertToScreen(fixtureView.bounds)
                let capture = CaptureController(
                    onText: { _ in },
                    onImage: { _ in },
                    onCopiedText: { _ in },
                    onCopiedImage: {},
                    onEditImage: { _ in }
                )
                let result: Result<URL, Error> = await withCheckedContinuation { continuation in
                    capture.captureImage(in: rect) { continuation.resume(returning: $0) }
                }
                let captured = try result.get()
                let capturedText = try CaptureOCR.recognizeText(in: captured)
                try require(capturedText.contains("Apple") && capturedText.contains("Bread"), "Actual selected-area screen capture must contain the public fixture.")
                records.append(["scenario": "Production rectangle screen capture → PNG → clipboard/shelf → OCR", "status": "PASS", "detail": captured.path])
            } else {
                records.append(["scenario": "Production rectangle screen capture", "status": "PERMISSION BLOCKER", "detail": "CGPreflightScreenCaptureAccess=false. No desktop was captured and no permission was silently requested."])
            }
            fixtureWindow.orderOut(nil)
            app.smokeSeedHistory(text: text, image: fixture)
            try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys]).write(to: report.appendingPathComponent("results.json"), options: .atomic)
            app.smokeShowWindows()
            try await Task.sleep(nanoseconds: 500_000_000)
            let smokePasteboard = NSPasteboard(name: NSPasteboard.Name("org.biscuit.smoke.\(UUID().uuidString)"))
            defer { smokePasteboard.releaseGlobally() }
            app.smokeUsePasteboard(smokePasteboard)
            records.append(contentsOf: try await exerciseVisibleUI(app: app, root: root, report: report, pasteboard: smokePasteboard))
            records.append(try await exerciseThumbnailShelf(fixture: fixture, report: report, pasteboard: smokePasteboard))
            for (index, window) in NSApp.windows.filter({ $0.isVisible && $0.contentView != nil && $0.frame.width > 100 && $0.frame.height > 100 }).enumerated() {
                guard let view = window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                if let png = bitmap.representation(using: .png, properties: [:]) { try png.write(to: report.appendingPathComponent("ui-\(index).png")) }
                records.append(["scenario": "Native UI visible: \(window.title)", "status": "OBSERVED", "detail": "\(Int(window.frame.width))×\(Int(window.frame.height)); content render saved to ui-\(index).png"])
            }
            if environment["BISCUIT_SUBSCRIPTION_SMOKE"] != "1" {
                records.append(["scenario": "Subscription translation/learning", "status": "NOT INVOKED IN THIS RUN", "detail": "Default smoke is local; use BISCUIT_SUBSCRIPTION_SMOKE=1 for the fixed public OAuth fixture. Public fixture windows did not auto-run."])
            }
            try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys]).write(to: report.appendingPathComponent("results.json"), options: .atomic)
            try Data("complete\n".utf8).write(to: report.appendingPathComponent("complete"), options: .atomic)
            print("BISCUIT_SMOKE_PASS \(report.path)")
            fflush(stdout)
            if environment["BISCUIT_SMOKE_KEEP_OPEN"] != "1" { NSApp.terminate(nil) }
        } catch {
            records.append(["scenario": "Smoke failure", "status": "FAIL", "detail": String(describing: error)])
            if let data = try? JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: report.appendingPathComponent("results.json"), options: .atomic) }
            fputs("BISCUIT_SMOKE_FAIL \(error)\n", stderr)
            exit(1)
        }
    }

    private static func verifyChatGPTWebConsentAndExportIsolation(store: LibraryStore, exportURL: URL, dataRoot: URL, environment: [String: String]) async throws {
        let fileManager = FileManager.default
        let provider = ChatGPTWebProvider.shared
        let runtime = provider.runtime
        guard let runtimeDirectory = runtime.runtimeDirectoryURL else {
            throw Failure(description: "ChatGPT Web runtime pins are unavailable for this smoke architecture.")
        }
        try require(!fileManager.fileExists(atPath: runtime.webHomeURL.path), "ChatGPT Web smoke data must start in its dedicated empty Biscuit data root.")
        do {
            try await provider.installRuntime(consented: false)
            throw Failure(description: "ChatGPT Web runtime installation must require explicit consent.")
        } catch ChatGPTWebFailure.consentRequired { }
        try require(!fileManager.fileExists(atPath: runtimeDirectory.path), "Declining runtime consent must not create the runtime destination.")


        let profileRoot = dataRoot.appendingPathComponent("existing-chatgpt-profile", isDirectory: true)
        try fileManager.createDirectory(at: profileRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard let suiteName = environment["BISCUIT_PREFERENCES_SUITE"],
              let preferences = UserDefaults(suiteName: suiteName) else {
            throw Failure(description: "ChatGPT Web smoke has no isolated preferences suite.")
        }
        preferences.set([
            "userDataPath": profileRoot.path,
            "appName": "Biscuit Web Public Gate",
            "partition": "persist:biscuit-chatgpt-web"
        ], forKey: ChatGPTWebRuntimeManager.profileIdentityPreferenceKey)
        defer {
            preferences.removeObject(forKey: ChatGPTWebRuntimeManager.profileIdentityPreferenceKey)
            try? fileManager.removeItem(at: runtime.webHomeURL)
        }
        try runtime.prepareWebHome()
        try require(runtime.storedSessionExists, "The persisted profile identity must be recognized as an available session.")
        try require(ProcessInfo.processInfo.environment["BISCUIT_CHATGPT_WEB_ELECTRON_APP_PATH"] == nil,
                    "The runtime-layout smoke must exercise the standard private payload path, not an external override.")

        let appBundleURL = runtimeDirectory.appendingPathComponent("Electron.app", isDirectory: true)
        let contentsURL = appBundleURL.appendingPathComponent("Contents", isDirectory: true)
        let macOSURL = contentsURL.appendingPathComponent("MacOS", isDirectory: true)
        for directory in [runtimeDirectory, appBundleURL, contentsURL, macOSURL] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        let executableURL = macOSURL.appendingPathComponent("Electron", isDirectory: false)
        let executableBytes = Data("biscuit smoke Electron executable".utf8)
        try executableBytes.write(to: executableURL)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executableURL.path)
        let executableSHA256 = SHA256.hash(data: executableBytes).map { String(format: "%02x", $0) }.joined()
        for notice in ["LICENSE", "LICENSES.chromium.html"] {
            try Data("synthetic Electron notice".utf8).write(to: runtimeDirectory.appendingPathComponent(notice))
        }
        try require(!fileManager.fileExists(atPath: runtimeDirectory.appendingPathComponent("Contents/MacOS/Electron").path),
                    "The extracted payload root must not be mistaken for the Electron.app bundle root.")
        try require(runtime.runtimeIsPresent, "An installed whole-payload layout must be visible to runtimeIsPresent.")
        let verifiedExecutable = try await ChatGPTWebRuntimeManager.verifiedRuntimeURL(
            inPayloadRoot: runtimeDirectory,
            expectedExecutableSHA256: executableSHA256,
            fileManager: fileManager
        )
        try require(verifiedExecutable.standardizedFileURL == executableURL.standardizedFileURL,
                    "Post-install verification must resolve the executable nested under Electron.app.")
        let licenseURL = runtimeDirectory.appendingPathComponent("LICENSE", isDirectory: false)
        try fileManager.removeItem(at: licenseURL)
        do {
            _ = try await ChatGPTWebRuntimeManager.verifiedRuntimeURL(
                inPayloadRoot: runtimeDirectory,
                expectedExecutableSHA256: executableSHA256,
                fileManager: fileManager
            )
            throw Failure(description: "Post-install verification must reject a missing payload-root LICENSE.")
        } catch ChatGPTWebFailure.runtimeIntegrity { }

        let identityMode = try fileManager.attributesOfItem(atPath: runtime.profileIdentityURL.path)[.posixPermissions] as? NSNumber
        try require(identityMode?.intValue == 0o600, "The app-owned profile identity file must be owner-private.")
        let sessionDirectory = runtime.webHomeURL.appendingPathComponent("session", isDirectory: true)
        let stateDirectory = runtime.webHomeURL.appendingPathComponent("state", isDirectory: true)
        try fileManager.createDirectory(at: sessionDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fileManager.createDirectory(at: stateDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for directory in [runtime.webHomeURL, runtime.webHomeURL.appendingPathComponent("tmp", isDirectory: true), sessionDirectory, stateDirectory] {
            let mode = try fileManager.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
            try require(mode?.intValue == 0o700, "ChatGPT Web home, session, and state directories must be owner-private.")
        }
        let sessionMarker = "synthetic-chatgpt-web-session-marker"
        let stateMarker = "synthetic-chatgpt-web-state-marker"
        try Data(sessionMarker.utf8).write(to: sessionDirectory.appendingPathComponent("storage-state.json"))
        try Data(stateMarker.utf8).write(to: stateDirectory.appendingPathComponent("thread-environments.json"))
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sessionDirectory.appendingPathComponent("storage-state.json").path)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateDirectory.appendingPathComponent("thread-environments.json").path)
        try store.exportAll(to: exportURL)
        let exportedNames = try fileManager.contentsOfDirectory(atPath: exportURL.path).sorted()
        try require(exportedNames == ["images", "library.json"], "Portable library export must contain only the library manifest and retained images.")
        let manifest = try String(contentsOf: exportURL.appendingPathComponent("library.json"), encoding: .utf8)
        try require(!manifest.contains(sessionMarker) && !manifest.contains(stateMarker),
                    "ChatGPT Web session and request-state sentinels must never enter LibraryStore export.")
    }

    private static func exerciseVisibleUI(app: AppDelegate, root: URL, report: URL, pasteboard: NSPasteboard) async throws -> [[String: String]] {
        var records: [[String: String]] = []
        let translation = try visibleWindow("biscuit Translation")
        let settings = try visibleWindow("biscuit Settings")
        guard let translationContent = translation.contentView,
              let settingsContent = settings.contentView else {
            throw Failure(description: "Translation and Settings windows must expose content views.")
        }
        translation.displayIfNeeded()
        translationContent.layoutSubtreeIfNeeded()
        settings.displayIfNeeded()
        settingsContent.layoutSubtreeIfNeeded()

        let recorders = descendants(of: settingsContent).compactMap { $0 as? ShortcutRecorder }
        guard let copyOriginal = descendants(of: translationContent).compactMap({ $0 as? NSButton }).first(where: { $0.title == "Copy Original" }) else {
            throw Failure(description: "Translation window did not expose its Copy Original control.")
        }
        copyOriginal.performClick(nil)
        let sourceText = "Hello world. This is a public biscuit fixture."
        try require(pasteboard.string(forType: .string) == sourceText, "The visible Copy Original action must write its source to the isolated smoke pasteboard.")

        guard let recorder = recorders.first else { throw Failure(description: "Settings did not create a shortcut recorder.") }
        let shortcutIndex = 4 // The first recorder on the Capture page.
        let shortcutDefaults = BiscuitPreferences.defaults
        guard let shortcutBefore = SettingsPreferences.resolvedShortcut(
            index: shortcutIndex,
            defaults: shortcutDefaults,
            defaultCodes: AppDelegate.defaultCodes,
            defaultModifiers: AppDelegate.defaultModifiers
        ) else {
            throw Failure(description: "Settings could not resolve the saved shortcut combination.")
        }
        recorder.performClick(nil)
        try require(settings.firstResponder === recorder, "Clicking the shortcut control must focus it for recording.")
        guard let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: settings.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53) else {
            throw Failure(description: "Could not create the synthetic Escape key event.")
        }
        recorder.keyDown(with: escape)
        let shortcutAfter = SettingsPreferences.resolvedShortcut(
            index: shortcutIndex,
            defaults: shortcutDefaults,
            defaultCodes: AppDelegate.defaultCodes,
            defaultModifiers: AppDelegate.defaultModifiers
        )
        try require(shortcutAfter?.0 == shortcutBefore.0 && shortcutAfter?.1 == shortcutBefore.1,
                    "Canceling shortcut recording must preserve the saved key combination.")
        records.append(["scenario": "Visible translation copy and shortcut recorder", "status": "PASS", "detail": "Copy Original reached the isolated pasteboard; Escape preserved the saved shortcut combination."])

        app.smokeShowLearningWindow()
        try require(translation.title == "biscuit Language Learning", "The same language surface must switch into the learning workflow.")
        let learningViews = descendants(of: translationContent)
        guard let vocabulary = learningViews.compactMap({ $0 as? NSTextField }).first(where: { $0.placeholderString == "Vocabulary word or phrase" }),
              let notes = learningViews.compactMap({ $0 as? NSTextView }).first(where: { $0.isEditable && $0.string.isEmpty }),
              let save = learningViews.compactMap({ $0 as? NSButton }).first(where: { $0.title == "Save to Study Notes" }) else {
            throw Failure(description: "Learning window did not expose its vocabulary, notes, and Study Notes save controls.")
        }
        let marker = "UI vocabulary fixture \(UUID().uuidString)"
        vocabulary.stringValue = marker
        notes.string = "UI study note fixture"
        save.performClick(nil)
        let notebook = try StudyNoteStore(dataDirectory: root)
        try require(notebook.manifestURL.lastPathComponent == "study-notes.json" &&
                    FileManager.default.fileExists(atPath: notebook.manifestURL.path),
                    "Visible lesson save must write the canonical study-notes.json store.")
        let matchingNotes = notebook.search(marker)
        try require(matchingNotes.count == 1, "Canonical notebook search must find exactly one saved lesson.")
        guard let savedNote = matchingNotes.first else { throw Failure(description: "The saved lesson disappeared from the canonical notebook.") }
        try require(savedNote.provider == "Manual entry" && savedNote.original == sourceText &&
                    savedNote.explanation.isEmpty && savedNote.vocabulary == marker &&
                    savedNote.personalNotes == "UI study note fixture",
                    "Visible lesson save must persist the provider, original, explanation, vocabulary, and personal-notes fields.")
        let genericHistory = try LibraryStore(dataDirectory: root)
        try require(genericHistory.search(marker).isEmpty, "A Study Note must not be duplicated into generic Library history.")
        records.append(["scenario": "Visible learning note save, canonical notebook search, and Library history isolation", "status": "PASS", "detail": "Saved \(marker) to study-notes.json with all structured fields; the same unique entry is absent from generic Library history."])

        guard let todo = try visibleWindow("Todos") as? NSPanel else { throw Failure(description: "Todos panel is not a native panel.") }
        let previousMain = NSApp.mainWindow
        try require(todo.styleMask.contains(.nonactivatingPanel) && !todo.hidesOnDeactivate && !todo.isMainWindow && previousMain !== todo,
                    "Opening Todos must remain a visible nonactivating panel without taking the main-window role.")
        try saveSnapshot(todo, to: report.appendingPathComponent("ui-todos-panel.png"))
        if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: todo.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53) {
            NSApp.sendEvent(event)
        } else {
            throw Failure(description: "Could not create the synthetic todo-dismissal Escape event.")
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        try require(!todo.isVisible, "Escape must dismiss the open Todos panel.")
        records.append(["scenario": "Nonactivating Todos focus and dismissal", "status": "PASS", "detail": "Todos stayed non-main and visible over other windows, then dismissed on Escape; panel render saved to ui-todos-panel.png."])
        return records
    }

    private static func visibleWindow(_ title: String) throws -> NSWindow {
        guard let window = NSApp.windows.first(where: { $0.title == title && $0.isVisible }) else {
            throw Failure(description: "Expected visible window “\(title)” was not created.")
        }
        return window
    }

    private static func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }

    private static func saveSnapshot(_ window: NSWindow, to url: URL) throws {
        guard let content = window.contentView,
              let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
            throw Failure(description: "Could not render \(window.title) for smoke evidence.")
        }
        content.cacheDisplay(in: content.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw Failure(description: "Could not encode \(window.title) smoke render.")
        }
        try png.write(to: url, options: .atomic)
    }

    private static func verifyAsymmetricComposition() throws {
        let selection = CGRect(x: 10, y: 20, width: 8, height: 6)
        let red = try solidImage(red: 1, green: 0, blue: 0, width: 3, height: 2)
        let blue = try solidImage(red: 0, green: 0, blue: 1, width: 3, height: 3)
        let image = try CaptureScreenImage.compose(selection, snapshots: [
            .init(region: CGRect(x: 10, y: 20, width: 3, height: 2), image: red),
            .init(region: CGRect(x: 15, y: 23, width: 3, height: 3), image: blue)
        ], scale: 1)
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let lowerLeft = rgb(bitmap, x: 1, y: 4),
              let upperRight = rgb(bitmap, x: 6, y: 1),
              let upperLeft = rgb(bitmap, x: 1, y: 1),
              let lowerRight = rgb(bitmap, x: 6, y: 4) else {
            throw Failure(description: "Could not sample the asymmetric composite fixture.")
        }
        try require(lowerLeft.0 > 0.9 && lowerLeft.2 < 0.1, "The lower-left display tile must stay in its original orientation.")
        try require(upperRight.2 > 0.9 && upperRight.0 < 0.1, "The upper-right display tile must stay at its non-symmetric offset.")
        try require(upperLeft.0 < 0.1 && upperLeft.2 < 0.1 && lowerRight.0 < 0.1 && lowerRight.2 < 0.1,
                    "Uncovered regions must remain the initialized background, not mirrored display content.")
    }

    private static func solidImage(red: CGFloat, green: CGFloat, blue: CGFloat, width: Int, height: Int) throws -> CGImage {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw Failure(description: "Could not create synthetic display tile.")
        }
        context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { throw Failure(description: "Could not encode synthetic display tile.") }
        return image
    }

    private static func rgb(_ bitmap: NSBitmapImageRep, x: Int, y: Int) -> (CGFloat, CGFloat, CGFloat)? {
        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
              let components = color.cgColor.components, components.count >= 3 else { return nil }
        return (components[0], components[1], components[2])
    }

    private static func exerciseThumbnailShelf(fixture: URL, report: URL, pasteboard: NSPasteboard) async throws -> [String: String] {
        let fixtureData = try Data(contentsOf: fixture)
        guard let image = NSImage(data: fixtureData) else { throw Failure(description: "Shelf fixture is not a readable image.") }
        var proposed = NSRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil) else {
            throw Failure(description: "Shelf fixture could not be decoded for its thumbnail.")
        }

        let shelf = CaptureThumbnailShelf(
            onText: { _ in },
            onCopiedText: { _ in },
            onCopiedImage: {},
            onEditImage: { _ in },
            pasteboard: pasteboard
        )
        let storeRoot = report.appendingPathComponent("thumbnail-shelf-fixture", isDirectory: true)
        let store = try LibraryStore(dataDirectory: storeRoot, onRemovingImages: { shelf.removeImages($0) })
        try FileManager.default.createDirectory(at: store.imageDirectory, withIntermediateDirectories: true)
        let olderURL = store.imageDirectory.appendingPathComponent("capture-shelf-older.png")
        let newerURL = store.imageDirectory.appendingPathComponent("capture-shelf-newer.png")
        try fixtureData.write(to: olderURL)
        let olderItem = try store.addImage(olderURL, recognizedText: "public shelf image fixture")
        try require(store.imageURL(for: olderItem)?.standardizedFileURL == olderURL.standardizedFileURL,
                    "An image already stored under biscuit's managed image directory must remain a single physical copy.")
        shelf.append(image: cgImage, fileURL: olderURL)
        try await Task.sleep(nanoseconds: 20_000_000)
        try fixtureData.write(to: newerURL)
        let newerItem = try store.addImage(newerURL, recognizedText: "newer public shelf image fixture")
        let managedFiles = try FileManager.default.contentsOfDirectory(at: store.imageDirectory, includingPropertiesForKeys: nil)
        try require(managedFiles.count == 2, "Two distinct captures should occupy exactly two managed image files, without duplicate copies.")

        guard let shelfPanel = NSApp.windows.compactMap({ $0 as? NSPanel }).first(where: { $0.isVisible && abs($0.frame.width - 190) < 1 }),
              let shelfContent = shelfPanel.contentView,
              let thumbnail = descendants(of: shelfContent).first(where: { String(describing: type(of: $0)) == "CaptureThumbnailView" }) else {
            throw Failure(description: "The public fixture did not create a visible thumbnail shelf row.")
        }
        try require(thumbnail is NSDraggingSource, "Shelf thumbnails must expose native drag-source behavior.")
        try saveSnapshot(shelfPanel, to: report.appendingPathComponent("ui-capture-shelf.png"))
        guard let enter = NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: shelfPanel.windowNumber, context: nil, eventNumber: 0, trackingNumber: 1, userData: nil) else {
            throw Failure(description: "Could not create the synthetic shelf-hover event.")
        }
        thumbnail.mouseEntered(with: enter)
        guard let preview = NSApp.windows.first(where: { $0 is NSPanel && $0.isVisible && abs($0.frame.width - 360) < 1 && abs($0.frame.height - 270) < 1 }) else {
            throw Failure(description: "Hovering a retained thumbnail did not show its image preview.")
        }
        try saveSnapshot(preview, to: report.appendingPathComponent("ui-capture-preview.png"))
        guard let down = NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 80, y: 40), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: shelfPanel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1),
              let up = NSEvent.mouseEvent(with: .leftMouseUp, location: NSPoint(x: 80, y: 40), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: shelfPanel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else {
            throw Failure(description: "Could not create synthetic shelf-click events.")
        }
        thumbnail.mouseDown(with: down)
        thumbnail.mouseUp(with: up)
        try require(pasteboard.data(forType: .png) == fixtureData, "Clicking a shelf thumbnail must copy its retained PNG to the isolated pasteboard.")
        if let exit = NSEvent.enterExitEvent(with: .mouseExited, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: shelfPanel.windowNumber, context: nil, eventNumber: 0, trackingNumber: 1, userData: nil) {
            thumbnail.mouseExited(with: exit)
        }

        shelf.smokeBeginDragLease(for: olderURL)
        try store.setImageLimit(1, confirmTrim: true)
        try require(store.items.map(\.id) == [newerItem.id] && FileManager.default.fileExists(atPath: olderURL.path),
                    "Retention may remove the old shelf row but must keep its file until the active drag lease ends.")
        shelf.smokeEndDragLease(for: olderURL)
        try require(!FileManager.default.fileExists(atPath: olderURL.path) && FileManager.default.fileExists(atPath: newerURL.path),
                    "Ending the drag lease must delete only the trimmed image and preserve the retained capture.")
        return ["scenario": "Public-fixture shelf hover/copy/native drag lifetime and single-copy retention", "status": "PASS", "detail": "Hover preview and PNG copy ran on an isolated pasteboard; the NSDraggingSource row deferred old-file removal until lease end; two managed captures remained two files."]
    }

    private static func makeFixture(marker: Int? = nil) throws -> Data {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1000, pixelsHigh: 500, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { throw Failure(description: "Fixture image allocation failed") }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 1000, height: 500).fill()
        let font = NSFont.monospacedSystemFont(ofSize: 28, weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let rows = [["Item", "Qty", "Price"], ["Apple", "2", "3.50"], ["Bread", "1", "4.00"], ["Tea", "", "1.25"]]
        for (row, cells) in rows.enumerated() {
            for (column, cell) in cells.enumerated() { (cell as NSString).draw(at: NSPoint(x: 60 + column * 300, y: 380 - row * 100), withAttributes: attributes) }
        }
        if let marker { ("Capture \(marker)" as NSString).draw(at: NSPoint(x: 60, y: 20), withAttributes: attributes) }
        NSGraphicsContext.restoreGraphicsState()
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw Failure(description: "Fixture PNG encoding failed") }
        return data
    }
}

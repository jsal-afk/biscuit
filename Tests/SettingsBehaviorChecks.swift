import Foundation
import AppKit
import Carbon

#if !BISCUIT_SMOKE
@main
#endif
@MainActor
enum SettingsBehaviorChecks {
    static func main() {
        let suiteName = "org.biscuit.SettingsBehaviorChecks.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fail("could not create isolated preferences")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let browserRoute = [ChatGPTWebModelRoute(
            slug: ChatGPTWebModelSelection.browserSelectedID,
            displayName: "Browser-selected model",
            description: "The account's current browser model."
        )]
        check(ChatGPTWebModelSelection.resolve(savedSlug: nil, routeInventory: nil) == .browserSelected,
              "browser-selected remains valid when route inventory is unknown")
        let routesWithOtherModel = browserRoute + [
            ChatGPTWebModelRoute(slug: "chatgpt-web/other", displayName: "Other model", description: "")
        ]
        let browserSelectionPrecedence = ChatGPTWebModelSelection.requestSlug(
            savedSlug: ChatGPTWebModelSelection.browserSelectedID,
            defaultSlug: "chatgpt-web/other",
            routeInventory: routesWithOtherModel
        )
        let unsupportedSavedRoute = ChatGPTWebModelSelection.requestSlug(
            savedSlug: "chatgpt-web/removed",
            defaultSlug: "chatgpt-web/other",
            routeInventory: routesWithOtherModel
        )
        let nilSelectionDefault = ChatGPTWebModelSelection.requestSlug(
            savedSlug: nil, defaultSlug: "chatgpt-web/other",
            routeInventory: routesWithOtherModel
        )
        print("Saved-route precedence probe: browser-selected -> \(String(reflecting: browserSelectionPrecedence)); unsupported -> \(String(reflecting: unsupportedSavedRoute)); nil -> \(String(reflecting: nilSelectionDefault))")
        check(browserSelectionPrecedence == ChatGPTWebModelSelection.browserSelectedID, "saved browser-selected route takes precedence over a different advertised default")
        check(unsupportedSavedRoute == nil, "unsupported saved route never falls back to another advertised default")
        check(nilSelectionDefault == "chatgpt-web/other", "nil selection uses the advertised default route")
        let disconnectedEmptyReport = ChatGPTWebModelSelection.confirmedRoutes(connected: false, reportedRoutes: [])
        let connectedKnownEmpty = ChatGPTWebModelSelection.confirmedRoutes(connected: true, reportedRoutes: [])
        check(disconnectedEmptyReport == nil, "disconnected Web status leaves model inventory unknown")
        check(connectedKnownEmpty?.isEmpty == true, "connected empty Web inventory remains known-empty")
        check(ChatGPTWebModelSelection.resolve(savedSlug: "chatgpt-web/saved", routeInventory: nil)
              == .inventoryUnknown("chatgpt-web/saved"), "unknown Web inventory preserves saved model without declaring it unavailable")
        check(ChatGPTWebModelSelection.resolve(savedSlug: "chatgpt-web/saved", routeInventory: [])
              == .unavailable("chatgpt-web/saved"), "known-empty Web inventory declares absent saved model unavailable")

        check(!SettingsPreferences.imageTitlesEnabled(defaults: defaults), "AI image-title consent defaults off")

        let neverOptedIn = ImageTitleConsentSnapshot(enabledAtCapture: false, revision: 0)
        let optedIn = ImageTitleConsentSnapshot(enabledAtCapture: true, revision: 0)
        check(!neverOptedIn.allows(enabled: true, currentRevision: 0), "enabling titles cannot change an off-at-capture snapshot")
        check(optedIn.allows(enabled: true, currentRevision: 0), "enabled capture may submit title text")
        check(!optedIn.allows(enabled: true, currentRevision: 1), "revocation invalidates consent after re-enabling")
        check(!optedIn.allows(enabled: false, currentRevision: 0), "current opt-out prevents title submission")
        check(ImageTitleText.normalized("line\nbreak") == nil, "image title rejects multiline results")

        defaults.set(true, forKey: TodoController.keepOnTopPreferenceKey)
        check(TodoController.keepOnTopEnabled(defaults: defaults), "Todo Keep on Top preference persists")
        defaults.set(false, forKey: TodoController.keepOnTopPreferenceKey)
        check(!TodoController.keepOnTopEnabled(defaults: defaults), "Todo Keep on Top preference can be turned off")
        check(TodoController.shouldHideAfterKeyLoss(keepOnTop: false, keyWindowIsPanel: false),
              "an unpinned Todo panel hides after losing key status")
        check(!TodoController.shouldHideAfterKeyLoss(keepOnTop: true, keyWindowIsPanel: false),
              "Keep on Top suppresses resign-key dismissal")
        check(!TodoController.shouldHideAfterKeyLoss(keepOnTop: false, keyWindowIsPanel: true),
              "a Todo panel stays visible while it remains the key window")

        let panelSize = NSSize(width: 320, height: 240)
        let visibleFrame = NSRect(x: 40, y: 30, width: 1100, height: 800)
        let edgeFrame = TodoController.panelFrame(size: panelSize, visibleFrame: visibleFrame, savedTopLeft: nil)
        check(edgeFrame.maxX == visibleFrame.maxX && edgeFrame.midY == visibleFrame.midY,
              "default Todo placement meets the visible right edge and screen center")
        let constrainedFrame = TodoController.panelFrame(
            size: NSSize(width: visibleFrame.width + 100, height: visibleFrame.height + 100),
            visibleFrame: visibleFrame,
            savedTopLeft: nil
        )
        check(constrainedFrame == visibleFrame, "Todo panel size is clamped to the current visible frame")
        check(TodoController.shouldClearSavedPanelPosition(frame: edgeFrame, visibleFrame: visibleFrame),
              "right-edge placement clears a saved custom point")

        let customTopLeft = NSPoint(x: visibleFrame.minX + (visibleFrame.width - panelSize.width) / 3,
                                    y: visibleFrame.maxY)
        TodoController.savePanelTopLeft(customTopLeft, defaults: defaults)
        let storedTopLeft = TodoController.savedPanelTopLeft(defaults: defaults)
        check(storedTopLeft == customTopLeft, "Todo panel top-left persists through UserDefaults")
        check(!TodoController.shouldRevealAtScreenEdge(savedPanelTopLeft: storedTopLeft),
              "a custom Todo position suppresses automatic edge reveal")
        let restoredFrame = TodoController.panelFrame(size: panelSize, visibleFrame: visibleFrame, savedTopLeft: storedTopLeft)
        check(restoredFrame.minX == customTopLeft.x && restoredFrame.maxY == customTopLeft.y,
              "Todo panel restores its saved top-left point")
        check(restoredFrame.minX >= visibleFrame.minX && restoredFrame.maxX <= visibleFrame.maxX
              && restoredFrame.minY >= visibleFrame.minY && restoredFrame.maxY <= visibleFrame.maxY,
              "restored Todo position is clamped within the current visible frame")
        check(!TodoController.shouldClearSavedPanelPosition(frame: restoredFrame, visibleFrame: visibleFrame),
              "a custom Todo position remains saved until moved to the edge")

        let offscreenFrame = TodoController.panelFrame(
            size: panelSize,
            visibleFrame: visibleFrame,
            savedTopLeft: NSPoint(x: visibleFrame.maxX, y: visibleFrame.minY)
        )
        check(offscreenFrame.minX >= visibleFrame.minX && offscreenFrame.maxX <= visibleFrame.maxX
              && offscreenFrame.minY >= visibleFrame.minY && offscreenFrame.maxY <= visibleFrame.maxY,
              "saved Todo position is clamped after display bounds change")
        TodoController.savePanelTopLeft(nil, defaults: defaults)
        check(TodoController.savedPanelTopLeft(defaults: defaults) == nil
              && TodoController.shouldRevealAtScreenEdge(savedPanelTopLeft: nil),
              "clearing a custom Todo position restores edge reveal")

        var fileLeases = ImageFileMutationLeases()
        let draggedURL = URL(fileURLWithPath: "/tmp/biscuit-image-title-lease.png")
        var mutations: [String] = []
        fileLeases.beginDrag(for: draggedURL)
        fileLeases.beginDrag(for: draggedURL)
        let firstMutation = fileLeases.scheduleMutation(afterDragsFor: draggedURL) { mutations.append("first") }
        let secondMutation = fileLeases.scheduleMutation(afterDragsFor: draggedURL) { mutations.append("second") }
        check(scheduleIsDeferred(firstMutation) && scheduleIsDeferred(secondMutation), "rename mutations defer behind active drag leases")
        switch fileLeases.endDrag(for: draggedURL) {
        case .none: break
        case .delete, .perform: fail("first nested drag end must preserve the remaining lease")
        }
        check(mutations.isEmpty, "queued rename does not run before the final drag ends")
        switch fileLeases.endDrag(for: draggedURL) {
        case .perform(let deferred):
            deferred.forEach { $0() }
        case .none, .delete:
            fail("final drag end must release queued rename mutations")
        }
        check(mutations == ["first", "second"], "all queued rename mutations run once after drag release")

        let deletedURL = URL(fileURLWithPath: "/tmp/biscuit-image-title-deleted.png")
        fileLeases.beginDrag(for: deletedURL)
        _ = fileLeases.scheduleMutation(afterDragsFor: deletedURL) { mutations.append("obsolete") }
        check(fileLeases.removeImages([deletedURL]).contains(deletedURL.standardizedFileURL), "deletion retains a file while an active drag owns it")
        let afterDeletion = fileLeases.scheduleMutation(afterDragsFor: deletedURL) { mutations.append("too late") }
        check(scheduleIsDiscarded(afterDeletion), "deletion discards later filename mutations")
        switch fileLeases.endDrag(for: deletedURL) {
        case .delete(let url):
            check(url == deletedURL.standardizedFileURL, "drag release returns the pending deletion URL")
        case .none, .perform:
            fail("deletion must supersede queued rename work")
        }
        check(mutations == ["first", "second"], "deleted image never runs its queued rename")


        _ = SettingsPreferences.explanationLevel(defaults: defaults)
        check(defaults.object(forKey: SettingsPreferences.explanationLevelKey) == nil, "lesson fallback must not persist")
        _ = SettingsPreferences.notificationDuration(defaults: defaults)
        check(defaults.object(forKey: SettingsPreferences.notificationDurationKey) == nil, "duration fallback must not persist")
        _ = SettingsPreferences.clipboardOutput(defaults: defaults)
        _ = SettingsPreferences.interfaceLanguage(defaults: defaults)

        SettingsPreferences.setNotificationDuration(5, defaults: defaults)
        check(SettingsPreferences.notificationDuration(defaults: defaults) == 5, "saved notification duration")
        SettingsPreferences.setNotificationDuration(0.75, defaults: defaults)
        check(SettingsPreferences.notificationDuration(defaults: defaults) == 5, "unsupported duration is ignored")

        SettingsPreferences.setExplanationLevel(.advanced, defaults: defaults)
        check(SettingsPreferences.explanationLevel(defaults: defaults) == .advanced, "saved lesson level")

        SettingsPreferences.setClipboardOutput(.original, defaults: defaults)
        check(SettingsPreferences.clipboardOutput(defaults: defaults) == .original, "saved original clipboard mode")
        SettingsPreferences.setClipboardOutput(.translation, defaults: defaults)
        check(SettingsPreferences.clipboardOutput(defaults: defaults) == .translation, "saved translation clipboard mode")
        SettingsPreferences.setClipboardOutput(.originalAndTranslation, defaults: defaults)
        let combinedOutput = SettingsPreferences.clipboardOutput(defaults: defaults)
        check(combinedOutput == .originalAndTranslation, "saved combined clipboard mode")
        check(combinedOutput.text(original: "source", translation: "result") == "source\n\nresult", "combined clipboard formatting")
        check(combinedOutput.text(original: "", translation: "result") == nil, "combined clipboard output needs an original")
        check(combinedOutput.text(original: "source", translation: "") == nil, "combined clipboard output needs a translation")
        check(combinedOutput.text(original: "", translation: "") == nil, "combined clipboard output rejects two empty values")

        defaults.set(true, forKey: SettingsPreferences.autoDirectionKey)
        defaults.set("en", forKey: SettingsPreferences.nativeCodeKey)
        let selectedKey = SettingsPreferences.setTranslationIntoCode("fr", defaults: defaults)
        check(selectedKey == SettingsPreferences.learningTargetCodeKey, "automatic mode stores the alternate language")
        check(SettingsPreferences.automaticDirection(defaults: defaults), "selecting alternate language preserves automatic direction")
        check(SettingsPreferences.effectiveTargetCode(sourceCode: "en", nativeCode: "en", otherCode: "fr", manualCode: "de", automatic: true) == "fr", "native input routes to alternate language")
        check(SettingsPreferences.effectiveTargetCode(sourceCode: "fr", nativeCode: "en", otherCode: "fr", manualCode: "de", automatic: true) == "en", "other input routes to native language")
        defaults.set("ko", forKey: SettingsPreferences.nativeCodeKey)
        defaults.set("en", forKey: SettingsPreferences.learningTargetCodeKey)
        defaults.set("de", forKey: SettingsPreferences.manualTargetCodeKey)
        let targetBeforeManualTransition = SettingsPreferences.effectiveTargetCode(
            sourceCode: "ko", nativeCode: "ko", otherCode: "en", manualCode: "de", automatic: true
        )
        check(targetBeforeManualTransition == "en",
              "automatic direction resolves to English, not the requested French target, before the manual transition")
        SettingsPreferences.selectManualTranslationTarget("fr", defaults: defaults)
        check(!SettingsPreferences.automaticDirection(defaults: defaults),
              "explicit reverse target exits automatic direction")
        check(defaults.string(forKey: SettingsPreferences.manualTargetCodeKey) == "fr",
              "explicit reverse target persists French as the manual target")
        check(defaults.string(forKey: SettingsPreferences.nativeCodeKey) == "ko"
              && defaults.string(forKey: SettingsPreferences.learningTargetCodeKey) == "en",
              "reverse preserves the configured native and learning languages")
        let refreshedReverseTarget = SettingsPreferences.effectiveTargetCode(
            sourceCode: "ko",
            nativeCode: defaults.string(forKey: SettingsPreferences.nativeCodeKey) ?? "",
            otherCode: defaults.string(forKey: SettingsPreferences.learningTargetCodeKey) ?? "",
            manualCode: defaults.string(forKey: SettingsPreferences.manualTargetCodeKey) ?? "",
            automatic: SettingsPreferences.automaticDirection(defaults: defaults)
        )
        check(refreshedReverseTarget == "fr",
              "pure effective-target resolution returns French after manual direction is selected")
        defaults.set(false, forKey: SettingsPreferences.autoDirectionKey)
        let manualKey = SettingsPreferences.setTranslationIntoCode("de", defaults: defaults)
        check(manualKey == SettingsPreferences.manualTargetCodeKey, "manual mode stores its target")
        check(!SettingsPreferences.automaticDirection(defaults: defaults), "manual target preserves disabled direction")
        check(SettingsPreferences.effectiveTargetCode(sourceCode: "en", nativeCode: "en", otherCode: "fr", manualCode: "de", automatic: false) == "de", "manual input uses selected target")

        let defaultCodes: [UInt32] = [8, 17, 37]
        let defaultModifiers: [UInt32] = [1, 2, 4]
        defaults.set(99, forKey: "shortcut.0.code")
        defaults.set(8, forKey: "shortcut.0.modifiers")
        defaults.set(77, forKey: "shortcut.1.code")
        defaults.set(16, forKey: "shortcut.1.modifiers")
        _ = SettingsPreferences.resetShortcut(index: 0, defaults: defaults, defaultCodes: defaultCodes, defaultModifiers: defaultModifiers)
        check(SettingsPreferences.resolvedShortcut(index: 0, defaults: defaults, defaultCodes: defaultCodes, defaultModifiers: defaultModifiers)?.0 == 8, "single shortcut reset restores selected code")
        check(SettingsPreferences.resolvedShortcut(index: 0, defaults: defaults, defaultCodes: defaultCodes, defaultModifiers: defaultModifiers)?.1 == 1, "single shortcut reset restores selected modifiers")
        check(SettingsPreferences.resolvedShortcut(index: 1, defaults: defaults, defaultCodes: defaultCodes, defaultModifiers: defaultModifiers)?.0 == 77, "single shortcut reset leaves another code unchanged")
        check(SettingsPreferences.resolvedShortcut(index: 1, defaults: defaults, defaultCodes: defaultCodes, defaultModifiers: defaultModifiers)?.1 == 16, "single shortcut reset leaves another modifier unchanged")
        let scrollingIndex = 5
        let appShortcut = SettingsPreferences.resolvedShortcut(
            index: scrollingIndex,
            defaults: defaults,
            defaultCodes: AppDelegate.defaultCodes,
            defaultModifiers: AppDelegate.defaultModifiers
        )
        check(AppDelegate.shortcutNames.count == 6
              && AppDelegate.shortcutNames[scrollingIndex] == "Capture scrolling image"
              && appShortcut?.0 == UInt32(kVK_ANSI_S)
              && appShortcut?.1 == UInt32(optionKey),
              "scrolling image capture defaults to Option-S at shortcut index five")
        defaults.set(Int(kVK_ANSI_A), forKey: "shortcut.\(scrollingIndex).code")
        defaults.set(Int(cmdKey), forKey: "shortcut.\(scrollingIndex).modifiers")
        let customizedScrollShortcut = SettingsPreferences.resolvedShortcut(
            index: scrollingIndex,
            defaults: defaults,
            defaultCodes: AppDelegate.defaultCodes,
            defaultModifiers: AppDelegate.defaultModifiers
        )
        check(customizedScrollShortcut?.0 == UInt32(kVK_ANSI_A)
              && customizedScrollShortcut?.1 == UInt32(cmdKey),
              "scrolling capture shortcut customization resolves independently")
        let resetScrollShortcut = SettingsPreferences.resetShortcut(
            index: scrollingIndex,
            defaults: defaults,
            defaultCodes: AppDelegate.defaultCodes,
            defaultModifiers: AppDelegate.defaultModifiers
        )
        check(resetScrollShortcut?.0 == UInt32(kVK_ANSI_S)
              && resetScrollShortcut?.1 == UInt32(optionKey),
              "scrolling capture shortcut reset restores Option-S")

        SettingsPreferences.setOfferTranslationAfterCopy(true, defaults: defaults)
        check(SettingsPreferences.offerTranslationAfterCopy(defaults: defaults), "saved copy offer preference")
        var offer = PendingCopyOffer()
        let now = Date(timeIntervalSince1970: 1_000)
        offer.present(text: "captured text", duration: SettingsPreferences.notificationDuration(defaults: defaults), enabled: true, now: now)
        check(offer.isAvailable(now: now.addingTimeInterval(4.99), enabled: true), "copy offer remains available before duration expires")
        check(offer.consume(now: now.addingTimeInterval(4.99), enabled: true) == "captured text", "copy offer returns captured text")
        offer.present(text: "expired text", duration: 2.5, enabled: true, now: now)
        check(!offer.isAvailable(now: now.addingTimeInterval(2.5), enabled: true), "copy offer expires at configured duration")
        check(offer.consume(now: now.addingTimeInterval(2.5), enabled: true) == nil, "expired copy offer is not returned")
        offer.present(text: "consent changed", duration: 2.5, enabled: true, now: now)
        check(offer.isAvailable(now: now, enabled: true), "offer is available with consent")
        check(!offer.isAvailable(now: now, enabled: false), "revoked consent hides an existing offer")
        check(offer.consume(now: now, enabled: false) == nil, "revoked consent cannot return pending text")
        check(!offer.isAvailable(now: now, enabled: true), "re-enabling consent does not restore a consumed offer")

        SettingsPreferences.setInterfaceLanguage(.english, defaults: defaults)
        check(SettingsPreferences.interfaceLanguage(defaults: defaults) == .english, "saved supported interface language")
        check(defaults.object(forKey: "AppleLanguages") == nil, "interface language selection avoids AppleLanguages overrides")
        SettingsPreferences.setInterfaceLanguage(.system, defaults: defaults)
        check(SettingsPreferences.interfaceLanguage(defaults: defaults) == .system, "system language can be restored")
        check(defaults.persistentDomain(forName: suiteName)?["AppleLanguages"] == nil, "system language leaves the isolated suite without a language override")

        print("Settings behavior checks passed")
    }

    private static func scheduleIsDeferred(_ result: ImageFileMutationLeases.ScheduleResult) -> Bool {
        if case .deferred = result { return true }
        return false
    }

    private static func scheduleIsDiscarded(_ result: ImageFileMutationLeases.ScheduleResult) -> Bool {
        if case .discarded = result { return true }
        return false
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ label: String) {
        guard condition() else { fail(label) }
    }

    private static func fail(_ message: String) -> Never {
        fputs("Settings behavior check failed: \(message)\n", stderr)
        exit(1)
    }
}

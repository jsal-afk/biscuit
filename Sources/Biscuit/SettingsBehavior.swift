import Foundation
enum BiscuitPreferences {
    static let defaults: UserDefaults = {
#if BISCUIT_NATIVE_ACCOUNT_QA
        let environment = ProcessInfo.processInfo.environment
        guard Bundle.main.bundleIdentifier == NativeAccountSettingsKey.qaBundleIdentifier,
              let isolatedEnvironment = Bundle.main.object(forInfoDictionaryKey: "LSEnvironment") as? [String: String],
              let dataDirectory = isolatedEnvironment["BISCUIT_DATA_DIR"], !dataDirectory.isEmpty,
              environment["BISCUIT_DATA_DIR"] == dataDirectory,
              let suite = isolatedEnvironment["BISCUIT_PREFERENCES_SUITE"],
              suite == NativeAccountSettingsKey.qaPreferencesSuite,
              environment["BISCUIT_PREFERENCES_SUITE"] == suite,
              let isolated = UserDefaults(suiteName: suite) else {
            fatalError("The native-account QA candidate requires its declared isolated data directory and preferences suite.")
        }
        return isolated
#else
        if let suite = ProcessInfo.processInfo.environment["BISCUIT_PREFERENCES_SUITE"],
           !suite.isEmpty, let isolated = UserDefaults(suiteName: suite) { return isolated }
        return .standard
#endif
    }()
}

struct ChatGPTWebModelRoute: Decodable, Hashable {
    let slug: String
    let displayName: String
    let description: String
}

enum ChatGPTWebModelSelection {
    static let browserSelectedID = "browser-selected"

    enum Resolution: Equatable {
        case browserSelected
        case available(index: Int)
        case inventoryUnknown(String)
        case unavailable(String)
    }

    static func resolve(savedSlug: String?, routeInventory: [ChatGPTWebModelRoute]?) -> Resolution {
        guard let savedSlug, savedSlug != browserSelectedID else { return .browserSelected }
        guard let routeInventory else { return .inventoryUnknown(savedSlug) }
        guard let index = routeInventory.firstIndex(where: { $0.slug == savedSlug }) else {
            return .unavailable(savedSlug)
        }
        return .available(index: index)
    }

    static func confirmedRoutes(
        connected: Bool,
        reportedRoutes: [ChatGPTWebModelRoute]?
    ) -> [ChatGPTWebModelRoute]? {
        connected ? reportedRoutes : nil
    }

    static func requestSlug(
        savedSlug: String?,
        defaultSlug: String?,
        routeInventory: [ChatGPTWebModelRoute]?
    ) -> String? {
        guard let requestedSlug = savedSlug ?? defaultSlug,
              routeInventory?.contains(where: { $0.slug == requestedSlug }) == true else { return nil }
        return requestedSlug
    }
}

struct ImageTitleConsentSnapshot: Equatable {
    let enabledAtCapture: Bool
    let revision: UInt64

    func allows(enabled: Bool, currentRevision: UInt64) -> Bool {
        enabledAtCapture && enabled && revision == currentRevision
    }
}
enum ImageTitleText {
    static func normalized(_ proposed: String) -> String? {
        let title = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 120, title.utf8.count <= 512,
              !title.contains(where: { $0.isNewline }),
              title.unicodeScalars.contains(where: CharacterSet.alphanumerics.contains) else { return nil }
        return title
    }
}

@MainActor
struct ImageFileMutationLeases {
    enum ScheduleResult {
        case immediate
        case deferred
        case discarded
    }

    enum DragEndResult {
        case none
        case delete(URL)
        case perform([@MainActor () -> Void])
    }

    private var activeDrags: [URL: Int] = [:]
    private var pendingMutations: [URL: [@MainActor () -> Void]] = [:]
    private var pendingDeletions = Set<URL>()

    mutating func beginDrag(for url: URL) {
        activeDrags[url.standardizedFileURL, default: 0] += 1
    }

    mutating func scheduleMutation(
        afterDragsFor url: URL,
        perform: @escaping @MainActor () -> Void
    ) -> ScheduleResult {
        let key = url.standardizedFileURL
        guard !pendingDeletions.contains(key) else { return .discarded }
        guard activeDrags[key, default: 0] > 0 else { return .immediate }
        pendingMutations[key, default: []].append(perform)
        return .deferred
    }

    mutating func removeImages(_ urls: [URL]) -> Set<URL> {
        let removed = Set(urls.map(\.standardizedFileURL))
        for url in removed { pendingMutations.removeValue(forKey: url) }
        let leased = Set(removed.filter { activeDrags[$0, default: 0] > 0 })
        pendingDeletions.formUnion(leased)
        return leased
    }

    mutating func endDrag(for url: URL) -> DragEndResult {
        let key = url.standardizedFileURL
        guard let count = activeDrags[key] else { return .none }
        if count > 1 {
            activeDrags[key] = count - 1
            return .none
        }
        activeDrags.removeValue(forKey: key)
        if pendingDeletions.remove(key) != nil {
            pendingMutations.removeValue(forKey: key)
            return .delete(key)
        }
        let mutations = pendingMutations.removeValue(forKey: key) ?? []
        return mutations.isEmpty ? .none : .perform(mutations)
    }
}


enum ClipboardOutput: String, CaseIterable {
    case original
    case translation
    case originalAndTranslation

    var title: String {
        switch self {
        case .original: return BiscuitLocalization.string("Copy original only")
        case .translation: return BiscuitLocalization.string("Copy translation only")
        case .originalAndTranslation: return BiscuitLocalization.string("Copy original and translation")
        }
    }

    func text(original: String, translation: String) -> String? {
        switch self {
        case .original:
            return original.isEmpty ? nil : original
        case .translation:
            return translation.isEmpty ? nil : translation
        case .originalAndTranslation:
            guard !original.isEmpty, !translation.isEmpty else { return nil }
            return original + "\n\n" + translation
        }
    }
}

enum ExplanationLevel: String, CaseIterable {
    case beginner
    case intermediate
    case advanced

    var title: String {
        switch self {
        case .beginner: return BiscuitLocalization.string("Beginner")
        case .intermediate: return BiscuitLocalization.string("Intermediate")
        case .advanced: return BiscuitLocalization.string("Advanced")
        }
    }

    var instruction: String {
        switch self {
        case .beginner:
            return "Write for a beginner. Use plain language, define grammar terms, and explain unfamiliar vocabulary before relying on it."
        case .intermediate:
            return "Write for an intermediate learner. Give a concise explanation of meaning, vocabulary, grammar, and nuance without overexplaining familiar basics."
        case .advanced:
            return "Write for an advanced learner. Emphasize register, idioms, pragmatic nuance, subtle grammar, and meaningful alternative interpretations."
        }
    }
}

enum InterfaceLanguageChoice: String, CaseIterable {
    case system
    case english
    case arabic = "ar"
    case czech = "cs"
    case danish = "da"
    case german = "de"
    case spanish = "es"
    case french = "fr"
    case indonesian = "id"
    case italian = "it"
    case japanese = "ja"
    case korean = "ko"
    case malay = "ms"
    case norwegianBokmal = "nb"
    case dutch = "nl"
    case norwegianNynorsk = "nn"
    case polish = "pl"
    case brazilianPortuguese = "pt-BR"
    case romanian = "ro"
    case russian = "ru"
    case swedish = "sv"
    case thai = "th"
    case turkish = "tr"
    case ukrainian = "uk"
    case vietnamese = "vi"
    case cantoneseSimplified = "yue-Hans"
    case cantoneseTraditional = "yue-Hant"
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"

    var localeIdentifier: String {
        self == .english ? "en" : rawValue
    }

    var title: String {
        guard self != .system else { return BiscuitLocalization.string("System language") }
        return Locale(identifier: localeIdentifier).localizedString(forIdentifier: localeIdentifier) ?? localeIdentifier
    }
}

enum SettingsPreferences {
    static let notificationDurationKey = "settings.notificationDuration"
    static let clipboardOutputKey = "language.clipboardOutput"
    static let offerTranslationAfterCopyKey = "language.offerTranslationAfterCopy"
    static let explanationLevelKey = "language.explanationLevel"
    static let interfaceLanguageKey = "general.interfaceLanguage"
    static let autoDirectionKey = "language.autoDirection"
    static let learningTargetCodeKey = "language.learningTargetCode"
    static let manualTargetCodeKey = "language.manualTargetCode"
    static let nativeCodeKey = "language.nativeCode"
    static let imageTitlesEnabledKey = "capture.imageTitlesEnabled"
    static let notificationDurations: [TimeInterval] = [1, 2.5, 5]
    static let defaultNotificationDuration: TimeInterval = 2.5

    private static let shortcutLetterNames: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 31: "O", 32: "U",
        34: "I", 35: "P", 37: "L", 38: "J", 40: "K", 45: "N", 46: "M"
    ]
    private static let shortcutOtherNames: [UInt32: String] = [
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 25: "9", 26: "7", 28: "8", 29: "0",
        24: "=", 27: "-", 30: "]", 33: "[", 36: "Return", 39: "'", 41: ";", 42: "\\", 43: ",",
        44: "/", 47: ".", 48: "Tab", 49: "Space", 50: "`", 51: "Delete", 53: "Esc"
    ]
    private static let shortcutPrintableKeyEquivalents: [UInt32: String] = [
        0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x", 8: "c", 9: "v",
        11: "b", 12: "q", 13: "w", 14: "e", 15: "r", 16: "y", 17: "t", 31: "o", 32: "u",
        34: "i", 35: "p", 37: "l", 38: "j", 40: "k", 45: "n", 46: "m",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 25: "9", 26: "7", 28: "8", 29: "0",
        24: "=", 27: "-", 30: "]", 33: "[", 36: "\r", 39: "'", 41: ";", 42: "\\", 43: ",",
        44: "/", 47: ".", 48: "\t", 49: " ", 50: "`", 51: "\u{7f}", 53: "\u{1b}"
    ]
    static func notificationDuration(defaults: UserDefaults) -> TimeInterval {
        guard let stored = defaults.object(forKey: notificationDurationKey) as? NSNumber else {
            return defaultNotificationDuration
        }
        let value = stored.doubleValue
        return notificationDurations.contains(value) ? value : defaultNotificationDuration
    }

    static func setNotificationDuration(_ duration: TimeInterval, defaults: UserDefaults) {
        guard notificationDurations.contains(duration) else { return }
        defaults.set(duration, forKey: notificationDurationKey)
    }

    static func clipboardOutput(defaults: UserDefaults) -> ClipboardOutput {
        defaults.string(forKey: clipboardOutputKey).flatMap(ClipboardOutput.init(rawValue:)) ?? .translation
    }

    static func setClipboardOutput(_ output: ClipboardOutput, defaults: UserDefaults) {
        defaults.set(output.rawValue, forKey: clipboardOutputKey)
    }

    static func offerTranslationAfterCopy(defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: offerTranslationAfterCopyKey)
    }

    static func setOfferTranslationAfterCopy(_ enabled: Bool, defaults: UserDefaults) {
        defaults.set(enabled, forKey: offerTranslationAfterCopyKey)
    }
    static func imageTitlesEnabled(defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: imageTitlesEnabledKey)
    }

    static func setImageTitlesEnabled(_ enabled: Bool, defaults: UserDefaults) {
        defaults.set(enabled, forKey: imageTitlesEnabledKey)
    }

    static func explanationLevel(defaults: UserDefaults) -> ExplanationLevel {
        defaults.string(forKey: explanationLevelKey).flatMap(ExplanationLevel.init(rawValue:)) ?? .intermediate
    }

    static func setExplanationLevel(_ level: ExplanationLevel, defaults: UserDefaults) {
        defaults.set(level.rawValue, forKey: explanationLevelKey)
    }

    static func interfaceLanguage(defaults: UserDefaults) -> InterfaceLanguageChoice {
        defaults.string(forKey: interfaceLanguageKey).flatMap(InterfaceLanguageChoice.init(rawValue:)) ?? .system
    }

    static func setInterfaceLanguage(_ choice: InterfaceLanguageChoice, defaults: UserDefaults) {
        defaults.set(choice.rawValue, forKey: interfaceLanguageKey)
        // Drop the legacy app-domain override so system mode follows macOS preferences.
        defaults.removeObject(forKey: "AppleLanguages")
    }

    static func automaticDirection(defaults: UserDefaults) -> Bool {
        guard defaults.object(forKey: autoDirectionKey) != nil else { return true }
        return defaults.bool(forKey: autoDirectionKey)
    }

    static func translationIntoCode(
        defaults: UserDefaults,
        fallbackLearningCode: String
    ) -> String {
        let learning = defaults.string(forKey: learningTargetCodeKey) ?? fallbackLearningCode
        guard !automaticDirection(defaults: defaults) else { return learning }
        return defaults.string(forKey: manualTargetCodeKey) ?? learning
    }

    @discardableResult
    static func setTranslationIntoCode(_ code: String, defaults: UserDefaults) -> String {
        let key = automaticDirection(defaults: defaults) ? learningTargetCodeKey : manualTargetCodeKey
        defaults.set(code, forKey: key)
        return key
    }
    static func selectManualTranslationTarget(_ code: String, defaults: UserDefaults) {
        defaults.set(false, forKey: autoDirectionKey)
        defaults.set(code, forKey: manualTargetCodeKey)
    }

    static func effectiveTargetCode(
        sourceCode: String?,
        nativeCode: String,
        otherCode: String,
        manualCode: String,
        automatic: Bool
    ) -> String {
        guard automatic else { return manualCode }
        return sourceCode == nativeCode ? otherCode : nativeCode
    }

    static func resolvedShortcut(
        index: Int,
        defaults: UserDefaults,
        defaultCodes: [UInt32],
        defaultModifiers: [UInt32]
    ) -> (UInt32, UInt32)? {
        guard defaultCodes.indices.contains(index), defaultModifiers.indices.contains(index) else { return nil }
        let codeKey = "shortcut.\(index).code"
        let modifiersKey = "shortcut.\(index).modifiers"
        let code = defaults.object(forKey: codeKey).map { _ in UInt32(defaults.integer(forKey: codeKey)) } ?? defaultCodes[index]
        let modifiers = defaults.object(forKey: modifiersKey).map { _ in UInt32(defaults.integer(forKey: modifiersKey)) } ?? defaultModifiers[index]
        return (code, modifiers)
    }

    @discardableResult
    static func resetShortcut(
        index: Int,
        defaults: UserDefaults,
        defaultCodes: [UInt32],
        defaultModifiers: [UInt32]
    ) -> (UInt32, UInt32)? {
        guard defaultCodes.indices.contains(index), defaultModifiers.indices.contains(index) else { return nil }
        let code = defaultCodes[index]
        let modifiers = defaultModifiers[index]
        defaults.set(Int(code), forKey: "shortcut.\(index).code")
        defaults.set(Int(modifiers), forKey: "shortcut.\(index).modifiers")
        return (code, modifiers)
    }

    static func shortcutKeyName(_ code: UInt32) -> String {
        if let value = shortcutLetterNames[code] { return value }
        guard let value = shortcutOtherNames[code] else {
            return BiscuitLocalization.format("Key %u", arguments: [code])
        }
        switch value {
        case "Return", "Tab", "Space", "Delete", "Esc":
            return BiscuitLocalization.string(value)
        default:
            return value
        }
    }

    static func shortcutKeyEquivalent(_ code: UInt32) -> String? {
        shortcutPrintableKeyEquivalents[code]
    }

    static func shortcutLabel(
        code: UInt32,
        modifiers: UInt32,
        commandMask: UInt32,
        shiftMask: UInt32,
        optionMask: UInt32,
        controlMask: UInt32
    ) -> String {
        var label = ""
        if modifiers & controlMask != 0 { label += "⌃" }
        if modifiers & optionMask != 0 { label += "⌥" }
        if modifiers & shiftMask != 0 { label += "⇧" }
        if modifiers & commandMask != 0 { label += "⌘" }
        return label + shortcutKeyName(code)
    }
}

struct PendingCopyOffer {
    private(set) var text: String?
    private(set) var expiresAt: Date?

    mutating func present(text: String, duration: TimeInterval, enabled: Bool, now: Date = Date()) {
        guard enabled, !text.isEmpty, duration > 0 else {
            clear()
            return
        }
        self.text = text
        expiresAt = now.addingTimeInterval(duration)
    }

    func isAvailable(now: Date = Date(), enabled: Bool) -> Bool {
        guard enabled, let text, !text.isEmpty, let expiresAt else { return false }
        return now < expiresAt
    }

    mutating func consume(now: Date = Date(), enabled: Bool) -> String? {
        defer { clear() }
        guard isAvailable(now: now, enabled: enabled) else { return nil }
        return text
    }

    mutating func clear() {
        text = nil
        expiresAt = nil
    }
}

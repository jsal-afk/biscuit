import AppKit
import Foundation

/// Resolves Biscuit-owned interface strings from the selected localization without
/// changing process-wide or global language preferences.
enum BiscuitLocalization {
    static let supportedLocaleIdentifiers = [
        "ar", "cs", "da", "de", "en", "es", "fr", "id", "it", "ja", "ko", "ms",
        "nb", "nl", "nn", "pl", "pt-BR", "ro", "ru", "sv", "th", "tr", "uk", "vi",
        "yue-Hans", "yue-Hant", "zh-Hans", "zh-Hant"
    ]

    private static let selectedLanguage = SettingsPreferences.interfaceLanguage(defaults: BiscuitPreferences.defaults)
    private static let launchLocaleIdentifier = resolveLaunchLocale(selectedLanguage)
    private static let launchLocale = Locale(identifier: launchLocaleIdentifier)
    private static let launchBundle = localizationBundle(for: launchLocaleIdentifier)

    static var localeIdentifier: String { launchLocaleIdentifier }
    static var locale: Locale { launchLocale }

    static func string(_ key: String) -> String {
        launchBundle.localizedString(forKey: key, value: key, table: nil)
    }

    static func format(_ key: String, arguments: [CVarArg]) -> String {
        String(
            format: string(key),
            locale: launchLocale,
            arguments: arguments
        )
    }

    private static func resolveLaunchLocale(_ choice: InterfaceLanguageChoice) -> String {
        guard choice == .system else { return choice.localeIdentifier }
        return Bundle.preferredLocalizations(
            from: supportedLocaleIdentifiers,
            forPreferences: Locale.preferredLanguages
        ).first ?? "en"
    }

    private static let interfaceDirection: NSUserInterfaceLayoutDirection =
        Locale.Language(identifier: launchLocaleIdentifier).characterDirection == .rightToLeft
            ? .rightToLeft
            : .leftToRight

    @MainActor
    static func applyInterfaceDirection(to window: NSWindow) {
        guard let contentView = window.contentView else { return }
        applyInterfaceDirection(to: contentView)
    }

    @MainActor
    static func applyInterfaceDirection(to rootView: NSView) {
        func apply(to view: NSView) {
            view.userInterfaceLayoutDirection = interfaceDirection
            for subview in view.subviews { apply(to: subview) }
        }
        apply(to: rootView)
    }

    @MainActor
    static func applyInterfaceDirection(to alert: NSAlert) {
        applyInterfaceDirection(to: alert.window)
    }

    private static func localizationBundle(for identifier: String) -> Bundle {
        guard let resourceURL = Bundle.main.resourceURL else { return Bundle.main }
        let localizationURL = resourceURL.appendingPathComponent("\(identifier).lproj", isDirectory: true)
        return Bundle(url: localizationURL) ?? Bundle.main
    }
}

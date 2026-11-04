import AppKit

@MainActor
final class CaptureOCRSettingsView: NSStackView {
    private let languagePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let autoDetect = NSButton(checkboxWithTitle: BiscuitLocalization.string("Also recognize other languages (auto-detect on each capture)"), target: nil, action: nil)
    private let correction = NSButton(checkboxWithTitle: BiscuitLocalization.string("Use language correction"), target: nil, action: nil)

    init(labelColumnWidth: CGFloat = 150) {
        CaptureOCRPreferences.registerDefaults()
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 8

        let languageRow = NSStackView()
        languageRow.orientation = .horizontal
        languageRow.alignment = .centerY
        languageRow.spacing = 10
        languageRow.addArrangedSubview(labelCell(BiscuitLocalization.string("Recognition language"), width: labelColumnWidth))
        languagePopup.translatesAutoresizingMaskIntoConstraints = false
        languagePopup.widthAnchor.constraint(equalToConstant: 205).isActive = true
        for language in CaptureOCRPreferences.supportedLanguages {
            let name = BiscuitLocalization.locale.localizedString(forIdentifier: language) ?? language
            languagePopup.addItem(withTitle: name)
            languagePopup.lastItem?.representedObject = language
        }
        if let index = CaptureOCRPreferences.supportedLanguages.firstIndex(of: CaptureOCRPreferences.primaryLanguage) {
            languagePopup.selectItem(at: index)
        }
        languagePopup.target = self
        languagePopup.action = #selector(changeLanguage(_:))
        languageRow.addArrangedSubview(languagePopup)
        let systemLanguage = NSButton(title: BiscuitLocalization.string("System language"), target: self, action: #selector(useSystemLanguage(_:)))
        languageRow.addArrangedSubview(systemLanguage)
        addArrangedSubview(languageRow)
        addArrangedSubview(helpRow(BiscuitLocalization.string("Uses the language macOS currently prefers for text recognition."), width: labelColumnWidth))

        autoDetect.state = BiscuitPreferences.defaults.bool(forKey: CaptureOCRPreferences.autoDetectKey) ? .on : .off
        autoDetect.target = self
        autoDetect.action = #selector(changeAutoDetect(_:))
        addArrangedSubview(controlRow("", control: autoDetect, width: labelColumnWidth))
        addArrangedSubview(helpRow(BiscuitLocalization.string("Attempts language detection for each capture; mixed-language screens can be less accurate."), width: labelColumnWidth))

        correction.state = BiscuitPreferences.defaults.bool(forKey: CaptureOCRPreferences.correctionKey) ? .on : .off
        correction.target = self
        correction.action = #selector(changeCorrection(_:))
        addArrangedSubview(controlRow("", control: correction, width: labelColumnWidth))
        addArrangedSubview(helpRow(BiscuitLocalization.string("Uses Vision language correction to normalize recognized text."), width: labelColumnWidth))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    private func labelCell(_ title: String, width: CGFloat) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.alignment = .right
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.widthAnchor.constraint(equalToConstant: width).isActive = true
        return label
    }

    private func controlRow(_ title: String, control: NSView, width: CGFloat) -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.addArrangedSubview(labelCell(title, width: width))
        row.addArrangedSubview(control)
        return row
    }

    private func helpRow(_ text: String, width: CGFloat) -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 10
        let blank = NSView()
        blank.widthAnchor.constraint(equalToConstant: width).isActive = true
        row.addArrangedSubview(blank)
        let help = NSTextField(wrappingLabelWithString: text)
        help.textColor = .secondaryLabelColor
        help.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        help.maximumNumberOfLines = 2
        row.addArrangedSubview(help)
        return row
    }

    @objc private func changeLanguage(_ sender: NSPopUpButton) {
        guard let language = sender.selectedItem?.representedObject as? String else { return }
        BiscuitPreferences.defaults.set(language, forKey: CaptureOCRPreferences.languageKey)
    }
    @objc private func useSystemLanguage(_ sender: Any?) {
        let language = CaptureOCRPreferences.defaultLanguage
        BiscuitPreferences.defaults.set(language, forKey: CaptureOCRPreferences.languageKey)
        if let index = CaptureOCRPreferences.supportedLanguages.firstIndex(of: language) {
            languagePopup.selectItem(at: index)
        }
    }

    @objc private func changeAutoDetect(_ sender: NSButton) {
        BiscuitPreferences.defaults.set(sender.state == .on, forKey: CaptureOCRPreferences.autoDetectKey)
    }

    @objc private func changeCorrection(_ sender: NSButton) {
        BiscuitPreferences.defaults.set(sender.state == .on, forKey: CaptureOCRPreferences.correctionKey)
    }
}

import AppKit
import Carbon

@MainActor
final class CopyNotificationController {
    private let duration: () -> TimeInterval
    private let offerEnabled: () -> Bool
    private let shortcutLabel: (Int) -> String
    private let onTranslate: (String) -> Void
    private let panel: NSPanel
    private let titleLabel: NSTextField
    private let actionRow: NSStackView
    private let copyButton: NSButton
    private let translateButton: NSButton
    private var notificationTimer: Timer?
    private var modifierTimer: Timer?
    private var visibleText: String?
    private var dismissAt = Date.distantPast
    private var offer = PendingCopyOffer()
    private var showingShortcutHints = false

    init(
        duration: @escaping () -> TimeInterval,
        offerEnabled: @escaping () -> Bool,
        shortcutLabel: @escaping (Int) -> String,
        onTranslate: @escaping (String) -> Void
    ) {
        self.duration = duration
        self.offerEnabled = offerEnabled
        self.shortcutLabel = shortcutLabel
        self.onTranslate = onTranslate

        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 330, height: 112),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        titleLabel = NSTextField(labelWithString: "")
        actionRow = NSStackView()
        copyButton = NSButton(title: BiscuitLocalization.string("Copy"), target: nil, action: nil)
        translateButton = NSButton(title: BiscuitLocalization.string("Translate"), target: nil, action: nil)
        buildPanel()
    }

    var hasVisibleText: Bool {
        panel.isVisible && visibleText != nil
    }

    func showCopiedText(_ text: String) {
        guard !text.isEmpty else { return }
        visibleText = text
        present(title: BiscuitLocalization.string("Text copied"), offersTranslation: true)
    }

    func showCopiedImage() {
        visibleText = nil
        offer.clear()
        present(title: BiscuitLocalization.string("Image copied"), offersTranslation: false)
    }

    func updateOfferPreference(_ enabled: Bool) {
        guard panel.isVisible, let visibleText else { return }
        let remaining = dismissAt.timeIntervalSinceNow
        guard remaining > 0 else {
            dismiss()
            return
        }
        offer.present(text: visibleText, duration: remaining, enabled: enabled, now: Date())
        updateButtons()
    }

    @discardableResult
    func repeatCopy() -> Bool {
        guard panel.isVisible, let visibleText else { return false }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(visibleText, forType: .string) else {
            titleLabel.stringValue = BiscuitLocalization.string("Could not copy text")
            return true
        }
        titleLabel.stringValue = BiscuitLocalization.string("Text copied again")
        return true
    }

    func takeTranslationText() -> String? {
        guard panel.isVisible else { return nil }
        guard let text = offer.consume(now: Date(), enabled: offerEnabled()) else {
            updateButtons()
            return nil
        }
        dismiss()
        return text
    }

    func dismiss() {
        notificationTimer?.invalidate()
        notificationTimer = nil
        modifierTimer?.invalidate()
        modifierTimer = nil
        visibleText = nil
        offer.clear()
        showingShortcutHints = false
        panel.orderOut(nil)
    }

    private func buildPanel() {
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.animationBehavior = .utilityWindow
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 8
        root.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)

        actionRow.orientation = .horizontal
        actionRow.alignment = .centerY
        actionRow.distribution = .fillEqually
        actionRow.spacing = 8
        actionRow.detachesHiddenViews = true
        copyButton.bezelStyle = .rounded
        copyButton.target = self
        copyButton.action = #selector(copyAgain(_:))
        translateButton.bezelStyle = .rounded
        translateButton.target = self
        translateButton.action = #selector(translateCopied(_:))
        actionRow.addArrangedSubview(copyButton)
        actionRow.addArrangedSubview(translateButton)
        root.addArrangedSubview(titleLabel)
        root.addArrangedSubview(actionRow)
        effect.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 16),
            root.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -16),
            root.topAnchor.constraint(equalTo: effect.topAnchor, constant: 12),
            root.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -12),
            root.widthAnchor.constraint(equalToConstant: 298)
        ])
        panel.contentView = effect
        BiscuitLocalization.applyInterfaceDirection(to: panel)
        BiscuitPresentation.setFrame(NSRect(x: 0, y: 0, width: 330, height: 92), for: panel, display: false)
        updateButtons()
    }

    private func present(title: String, offersTranslation: Bool) {
        notificationTimer?.invalidate()
        modifierTimer?.invalidate()
        titleLabel.stringValue = title
        let interval = max(0.1, duration())
        dismissAt = Date().addingTimeInterval(interval)
        if offersTranslation, let visibleText {
            offer.present(text: visibleText, duration: interval, enabled: offerEnabled())
        } else {
            offer.clear()
        }
        updateButtons()

        panel.contentView?.layoutSubtreeIfNeeded()
        let panelHeight = max(76, ceil((panel.contentView?.fittingSize.height ?? 76)))
        let size = NSSize(width: 330, height: panelHeight)
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? .zero
        BiscuitPresentation.setFrame(NSRect(x: visible.maxX - size.width - 16, y: visible.minY + 16, width: size.width, height: size.height), for: panel, display: true)
        guard BiscuitPresentation.show(panel, key: false) else { return }
        notificationTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }
        modifierTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshShortcutHints() }
        }
        refreshShortcutHints()
    }

    private func updateButtons() {
        let canCopy = visibleText != nil
        let canTranslate = visibleText != nil && offer.isAvailable(now: Date(), enabled: offerEnabled())
        copyButton.isHidden = !canCopy
        copyButton.isEnabled = canCopy
        translateButton.isHidden = !canTranslate
        translateButton.isEnabled = canTranslate
        actionRow.isHidden = !canCopy && !canTranslate
        applyShortcutLabels()
    }

    private func refreshShortcutHints() {
        guard panel.isVisible else { return }
        let current = GetCurrentKeyModifiers() & UInt32(optionKey) != 0
        guard current != showingShortcutHints else { return }
        showingShortcutHints = current
        applyShortcutLabels()
    }

    private func applyShortcutLabels() {
        copyButton.title = showingShortcutHints
            ? BiscuitLocalization.format("Copy (%1$@)", arguments: [shortcutLabel(0)])
            : BiscuitLocalization.string("Copy")
        translateButton.title = showingShortcutHints
            ? BiscuitLocalization.format("Translate (%1$@)", arguments: [shortcutLabel(1)])
            : BiscuitLocalization.string("Translate")
    }

    @objc private func copyAgain(_ sender: Any?) {
        _ = repeatCopy()
    }

    @objc private func translateCopied(_ sender: Any?) {
        guard let text = takeTranslationText() else { return }
        onTranslate(text)
    }
}

import AppKit
import ApplicationServices
import Foundation

public struct TodoItem: Codable, Identifiable, Equatable {
    public let id: UUID
    public var text: String
    public var isStarred: Bool
    public var dueDate: Date?
    public var isCompleted: Bool
    public let createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), text: String, isStarred: Bool = false, dueDate: Date? = nil,
                isCompleted: Bool = false, createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.text = text
        self.isStarred = isStarred
        self.dueDate = dueDate
        self.isCompleted = isCompleted
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum TodoStoreError: LocalizedError {
    case invalidFile
    case emptyText
    case itemUnavailable

    public var errorDescription: String? {
        switch self {
        case .invalidFile: return BiscuitLocalization.string("The todo file is invalid. It was left untouched so its contents can be recovered.")
        case .emptyText: return BiscuitLocalization.string("A todo needs some text.")
        case .itemUnavailable: return BiscuitLocalization.string("This todo is no longer available.")
        }
    }
}

@MainActor public final class TodoStore {
    public let dataDirectory: URL
    public let fileURL: URL
    public private(set) var items: [TodoItem]

    public init(dataDirectory: URL? = nil) throws {
        let root = dataDirectory ?? Self.defaultDataDirectory()
        self.dataDirectory = root
        self.fileURL = root.appendingPathComponent("todos.json", isDirectory: false)
        self.items = []
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let data = try Data(contentsOf: fileURL)
        let decoded: [TodoItem]
        do { decoded = try JSONDecoder().decode([TodoItem].self, from: data) }
        catch { throw TodoStoreError.invalidFile }
        guard Self.valid(decoded) else { throw TodoStoreError.invalidFile }
        self.items = Self.sorted(decoded)
    }

    @discardableResult public func add(text: String, dueDate: Date? = nil) throws -> TodoItem {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw TodoStoreError.emptyText }
        let item = TodoItem(text: text, dueDate: dueDate)
        let updated = Self.sorted([item] + items)
        try persist(updated)
        items = updated
        return item
    }

    public func updateText(_ text: String, for id: UUID) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw TodoStoreError.emptyText }
        try update(id) { item in
            guard item.text != text else { return false }
            item.text = text
            return true
        }
    }

    public func setStarred(_ starred: Bool, for id: UUID) throws {
        try update(id) { item in
            guard item.isStarred != starred else { return false }
            item.isStarred = starred
            return true
        }
    }

    public func setDueDate(_ date: Date?, for id: UUID) throws {
        try update(id) { item in
            guard item.dueDate != date else { return false }
            item.dueDate = date
            return true
        }
    }

    public func setCompleted(_ completed: Bool, for id: UUID) throws {
        try update(id) { item in
            guard item.isCompleted != completed else { return false }
            item.isCompleted = completed
            return true
        }
    }

    public func delete(_ id: UUID) throws {
        guard items.contains(where: { $0.id == id }) else { throw TodoStoreError.itemUnavailable }
        let updated = items.filter { $0.id != id }
        try persist(updated)
        items = updated
    }
    @discardableResult public func clearCompleted() throws -> Int {
        let updated = items.filter { !$0.isCompleted }
        let removedCount = items.count - updated.count
        guard removedCount > 0 else { return 0 }
        try persist(updated)
        items = updated
        return removedCount
    }


    private func update(_ id: UUID, change: (inout TodoItem) -> Bool) throws {
        guard let index = items.firstIndex(where: { $0.id == id }) else { throw TodoStoreError.itemUnavailable }
        var updated = items
        guard change(&updated[index]) else { return }
        updated[index].updatedAt = Date()
        updated = Self.sorted(updated)
        try persist(updated)
        items = updated
    }

    private func persist(_ items: [TodoItem]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(items)
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }

    private static func valid(_ items: [TodoItem]) -> Bool {
        var ids = Set<UUID>()
        return items.allSatisfy { item in
            ids.insert(item.id).inserted && !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private static func sorted(_ items: [TodoItem]) -> [TodoItem] {
        items.sorted {
            if $0.isStarred != $1.isStarred { return $0.isStarred }
            if $0.isCompleted != $1.isCompleted { return !$0.isCompleted }
            switch ($0.dueDate, $1.dueDate) {
            case let (left?, right?) where left != right: return left < right
            case (_?, nil): return true
            case (nil, _?): return false
            default: return $0.createdAt < $1.createdAt
            }
        }
    }

    private static func defaultDataDirectory() -> URL {
        if let override = ProcessInfo.processInfo.environment["BISCUIT_DATA_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("biscuit", isDirectory: true)
    }
    static func defaultFileURL() -> URL {
        defaultDataDirectory().appendingPathComponent("todos.json", isDirectory: false)
    }
}

private final class NonActivatingTodoPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor public final class TodoController: NSObject, NSTextFieldDelegate, NSWindowDelegate {
    static let edgeEnabledPreferenceKey = "todo.edgeEnabled"
    static let keepOnTopPreferenceKey = "keepsTodoPanelOnTop"
    static let panelTopLeftPreferenceKey = "todoPanelTopLeft"

    static func keepOnTopEnabled(defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: keepOnTopPreferenceKey)
    }

    static func savedPanelTopLeft(defaults: UserDefaults) -> NSPoint? {
        guard let encoded = defaults.string(forKey: panelTopLeftPreferenceKey) else { return nil }
        let point = NSPointFromString(encoded)
        guard point.x.isFinite, point.y.isFinite else { return nil }
        return point
    }

    static func savePanelTopLeft(_ point: NSPoint?, defaults: UserDefaults) {
        guard let point else {
            defaults.removeObject(forKey: panelTopLeftPreferenceKey)
            return
        }
        defaults.set(NSStringFromPoint(point), forKey: panelTopLeftPreferenceKey)
    }

    static func shouldHideAfterKeyLoss(keepOnTop: Bool, keyWindowIsPanel: Bool) -> Bool {
        !keepOnTop && !keyWindowIsPanel
    }

    static func shouldRevealAtScreenEdge(savedPanelTopLeft: NSPoint?) -> Bool {
        savedPanelTopLeft == nil
    }

    static func panelFrame(size: NSSize, visibleFrame: NSRect, savedTopLeft: NSPoint?) -> NSRect {
        let size = NSSize(
            width: min(max(0, size.width), visibleFrame.width),
            height: min(max(0, size.height), visibleFrame.height)
        )
        if let savedTopLeft {
            let x = min(max(savedTopLeft.x, visibleFrame.minX), visibleFrame.maxX - size.width)
            let y = min(max(savedTopLeft.y - size.height, visibleFrame.minY), visibleFrame.maxY - size.height)
            return NSRect(origin: NSPoint(x: x, y: y), size: size)
        }
        let y = (visibleFrame.midY - size.height / 2).rounded()
        return NSRect(x: visibleFrame.maxX - size.width, y: y, width: size.width, height: size.height)
    }

    static func shouldClearSavedPanelPosition(frame: NSRect, visibleFrame: NSRect) -> Bool {
        frame.maxX >= visibleFrame.maxX
    }

    public private(set) var store: TodoStore?
    private var startupError: Error?
    private var panel: NonActivatingTodoPanel?
    private var rowStack: NSStackView?
    private var scrollView: NSScrollView?
    private var addField: NSTextField?
    private var statusLabel: NSTextField?
    private var keepOnTopButton: NSButton?
    private var isShowingMoreMenu = false

    private var isKeepOnTopEnabled: Bool {
        Self.keepOnTopEnabled(defaults: BiscuitPreferences.defaults)
    }

    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var globalClickMonitor: Any?
    private var globalEscapeMonitor: Any?
    private var localDismissMonitor: Any?
    private var defaultsObserver: NSObjectProtocol?
    private var globalEscapeUnavailable = false
    private var needsAccessibilityPermission = false
    private var globalClickUnavailable = false
    private var escapePermissionButton: NSButton?
    private var showsCompleted = false
    private var dwellTimer: Timer?
    private var edgeOpenedPanel = false
    private var isMonitoring = false
    private var globalMonitoringUnavailable = false

    public override init() {
        do { store = try TodoStore() }
        catch { startupError = error }
        super.init()
        defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: BiscuitPreferences.defaults, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.syncEdgeMonitoring()
                self.updateKeepOnTopButton()
                self.updateMonitoringMessage()
                self.restoreIfKeptOnTop()
            }
        }
    }


    public func toggle() {
        if let panel, panel.isVisible {
            hidePanel()
        } else {
            showPanel(near: NSEvent.mouseLocation, openedByEdge: false)
        }
    }

    private func hidePanel() {
        panel?.orderOut(nil)
        edgeOpenedPanel = false
        removeDismissMonitors()
    }

    public func startEdgeMonitoring() {
        let key = Self.edgeEnabledPreferenceKey
        if BiscuitPreferences.defaults.object(forKey: key) == nil {
            BiscuitPreferences.defaults.register(defaults: [key: true])
        }
        syncEdgeMonitoring()
        restoreIfKeptOnTop()
    }

    private func syncEdgeMonitoring() {
        guard BiscuitPreferences.defaults.bool(forKey: Self.edgeEnabledPreferenceKey) else {
            dwellTimer?.invalidate()
            dwellTimer = nil
            if isMonitoring {
                if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
                if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
                globalMouseMonitor = nil
                localMouseMonitor = nil
                isMonitoring = false
            }
            if edgeOpenedPanel && !isKeepOnTopEnabled { hidePanel() }
            globalMonitoringUnavailable = false
            updateMonitoringMessage()
            return
        }
        guard !isMonitoring else { return }
        isMonitoring = true
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            DispatchQueue.main.async { self?.pointerMoved() }
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            self?.pointerMoved()
            return event
        }
        globalMonitoringUnavailable = globalMouseMonitor == nil
        updateMonitoringMessage()
        pointerMoved()
    }

    private func pointerMoved() {
        guard isMonitoring else { return }
        let point = NSEvent.mouseLocation
        if screenAtRightEdge(point) != nil {
            guard Self.shouldRevealAtScreenEdge(savedPanelTopLeft: Self.savedPanelTopLeft(defaults: BiscuitPreferences.defaults)),
                  dwellTimer == nil, panel?.isVisible != true else { return }
            dwellTimer = Timer.scheduledTimer(withTimeInterval: 0.65, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.dwellTimer = nil
                    guard BiscuitPreferences.defaults.bool(forKey: Self.edgeEnabledPreferenceKey),
                          Self.shouldRevealAtScreenEdge(savedPanelTopLeft: Self.savedPanelTopLeft(defaults: BiscuitPreferences.defaults)),
                          let screen = self.screenAtRightEdge(NSEvent.mouseLocation) else { return }
                    self.showPanel(on: screen, openedByEdge: true)
                }
            }
        } else {
            dwellTimer?.invalidate()
            dwellTimer = nil
        }
    }

    private func screenAtRightEdge(_ point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { screen in
            screen.frame.contains(point) && point.x >= screen.frame.maxX - 3
        }
    }

    private func showPanel(near point: NSPoint, openedByEdge: Bool) {
        if panel == nil { buildPanel() }
        let screen = openedByEdge
            ? NSScreen.screens.first(where: { $0.frame.contains(point) })
            : presentationScreen(near: point)
        guard let screen else { return }
        showPanel(on: screen, openedByEdge: openedByEdge)
    }

    private func presentationScreen(near point: NSPoint) -> NSScreen? {
        if let saved = Self.savedPanelTopLeft(defaults: BiscuitPreferences.defaults),
           let panel {
            let frame = NSRect(x: saved.x, y: saved.y - panel.frame.height,
                               width: panel.frame.width, height: panel.frame.height)
            let center = NSPoint(x: frame.midX, y: frame.midY)
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) { return screen }
            if let screen = NSScreen.screens.first(where: { $0.frame.intersects(frame) }) { return screen }
        }
        return NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func showPanel(on screen: NSScreen, openedByEdge: Bool) {
        guard store != nil else {
            if panel == nil { buildPanel() }
            presentPanel(on: screen, openedByEdge: openedByEdge)
            return
        }
        if panel == nil { buildPanel() }
        presentPanel(on: screen, openedByEdge: openedByEdge)
    }

    private func presentPanel(on screen: NSScreen, openedByEdge: Bool) {
        guard let panel else { return }
        let visible = screen.visibleFrame
        let frame = Self.panelFrame(
            size: NSSize(width: 430, height: 480),
            visibleFrame: visible,
            savedTopLeft: Self.savedPanelTopLeft(defaults: BiscuitPreferences.defaults)
        )
        BiscuitPresentation.setFrame(frame, for: panel, display: true)
        refreshRows()
        edgeOpenedPanel = openedByEdge
        guard BiscuitPresentation.show(panel, key: false) else { return }
        installDismissMonitors()
        updateMonitoringMessage()
    }

    private func updateKeepOnTopButton() {
        guard let button = keepOnTopButton else { return }
        let enabled = isKeepOnTopEnabled
        button.state = enabled ? .on : .off
        button.layer?.backgroundColor = enabled
            ? NSColor.controlAccentColor.withAlphaComponent(0.16).cgColor
            : NSColor.clear.cgColor
        button.contentTintColor = enabled ? NSColor.controlAccentColor : NSColor.labelColor
    }

    @objc private func toggleKeepOnTop(_ sender: NSButton) {
        BiscuitPreferences.defaults.set(sender.state == .on, forKey: Self.keepOnTopPreferenceKey)
        updateKeepOnTopButton()
        updateMonitoringMessage()
        restoreIfKeptOnTop()
    }

    private func restoreIfKeptOnTop() {
        guard isKeepOnTopEnabled, panel?.isVisible != true else { return }
        showPanel(near: NSEvent.mouseLocation, openedByEdge: false)
    }

    @objc private func showMoreMenu(_ sender: NSButton) {
        guard Self.savedPanelTopLeft(defaults: BiscuitPreferences.defaults) != nil else { return }
        let menu = NSMenu()
        let moveToEdge = NSMenuItem(
            title: BiscuitLocalization.string("Move to Screen Edge"),
            action: #selector(movePanelToScreenEdge(_:)),
            keyEquivalent: ""
        )
        moveToEdge.target = self
        menu.addItem(moveToEdge)
        isShowingMoreMenu = true
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.minY), in: sender)
        isShowingMoreMenu = false
    }

    @objc private func movePanelToScreenEdge(_ sender: Any?) {
        guard Self.savedPanelTopLeft(defaults: BiscuitPreferences.defaults) != nil,
              let panel else { return }
        Self.savePanelTopLeft(nil, defaults: BiscuitPreferences.defaults)
        guard let screen = panel.screen
                ?? NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
                ?? NSScreen.main
                ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let frame = Self.panelFrame(size: panel.frame.size, visibleFrame: visible, savedTopLeft: nil)
        BiscuitPresentation.setFrame(frame, for: panel, display: true, animate: true)
        updateMonitoringMessage()
    }

    private func buildPanel() {
        let created = NonActivatingTodoPanel(contentRect: NSRect(x: 0, y: 0, width: 430, height: 480),
                                             styleMask: [.titled, .closable, .nonactivatingPanel],
                                             backing: .buffered, defer: false)
        created.title = BiscuitLocalization.string("Todos")
        created.isReleasedWhenClosed = false
        created.isFloatingPanel = true
        created.hidesOnDeactivate = false
        created.level = .floating
        created.delegate = self

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 9
        root.translatesAutoresizingMaskIntoConstraints = false
        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .centerY
        header.distribution = .equalSpacing
        header.spacing = 8
        let keepOnTop = NSButton(title: BiscuitLocalization.string("Keep on Top"), target: self, action: #selector(toggleKeepOnTop(_:)))
        keepOnTop.setButtonType(.toggle)
        keepOnTop.isBordered = false
        keepOnTop.wantsLayer = true
        keepOnTop.layer?.cornerRadius = 10
        keepOnTop.font = .systemFont(ofSize: 13, weight: .semibold)
        keepOnTop.identifier = NSUserInterfaceItemIdentifier("todo.keepOnTop")
        keepOnTopButton = keepOnTop
        let more = NSButton()
        more.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: BiscuitLocalization.string("More"))
        more.imagePosition = .imageOnly
        more.isBordered = false
        more.target = self
        more.action = #selector(showMoreMenu(_:))
        more.identifier = NSUserInterfaceItemIdentifier("todo.more")
        more.toolTip = BiscuitLocalization.string("More")
        more.widthAnchor.constraint(equalToConstant: 24).isActive = true
        header.addArrangedSubview(keepOnTop)
        header.addArrangedSubview(more)
        root.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        updateKeepOnTopButton()

        if store != nil {
            let entry = NSStackView()
            entry.orientation = .horizontal
            entry.spacing = 6
            let field = NSTextField()
            field.placeholderString = BiscuitLocalization.string("Add a todo")
            field.target = self
            field.action = #selector(addTodo(_:))
            field.delegate = self
            let add = NSButton(title: BiscuitLocalization.string("Add"), target: self, action: #selector(addTodo(_:)))
            entry.addArrangedSubview(field)
            entry.addArrangedSubview(add)
            addField = field

            let listActions = NSStackView()
            listActions.orientation = .horizontal
            listActions.alignment = .centerY
            listActions.spacing = 8
            let showCompleted = NSButton(checkboxWithTitle: BiscuitLocalization.string("Show Completed"), target: self, action: #selector(toggleShowCompleted(_:)))
            showCompleted.state = showsCompleted ? .on : .off
            let clearCompleted = NSButton(title: BiscuitLocalization.string("Clear Completed"), target: self, action: #selector(clearCompleted(_:)))
            listActions.addArrangedSubview(showCompleted)
            listActions.addArrangedSubview(clearCompleted)
            let status = NSTextField(wrappingLabelWithString: BiscuitLocalization.string("Starred items stay at the top."))
            status.font = .systemFont(ofSize: 11)
            status.textColor = .secondaryLabelColor

            status.maximumNumberOfLines = 6
            status.lineBreakMode = .byWordWrapping
            statusLabel = status

            let allowEscape = NSButton(title: BiscuitLocalization.string("Enable global Escape…"), target: self, action: #selector(openAccessibilitySettings))
            allowEscape.isHidden = !needsAccessibilityPermission
            escapePermissionButton = allowEscape

            let scroll = NSScrollView()
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true
            scroll.drawsBackground = false
            scroll.borderType = .noBorder
            let list = TopStackView()
            list.orientation = .vertical
            list.alignment = .leading
            list.distribution = .fill
            list.spacing = 6
            list.edgeInsets = NSEdgeInsets(top: 4, left: 3, bottom: 8, right: 10)
            list.frame = NSRect(x: 0, y: 0, width: 400, height: 1)
            list.autoresizingMask = [.width]
            scroll.documentView = list
            scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
            scroll.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
            rowStack = list
            scrollView = scroll

            for view in [entry, listActions, status, allowEscape, scroll] {
                root.addArrangedSubview(view)
                view.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
            }
        } else {
            let reason = startupError?.localizedDescription ?? BiscuitLocalization.string("The saved todos are unavailable.")
            let message = NSTextField(wrappingLabelWithString:
                BiscuitLocalization.format("Todos could not be loaded. %@ Your saved data was left untouched.", arguments: [reason as NSString]))
            message.textColor = .systemRed
            message.maximumNumberOfLines = 5
            message.lineBreakMode = .byWordWrapping
            statusLabel = message
            let reveal = NSButton(title: BiscuitLocalization.string("Show Todos File in Finder"), target: self, action: #selector(revealTodoFile))
            root.addArrangedSubview(message)
            root.addArrangedSubview(reveal)
            message.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        }
        let content = BiscuitBackgroundView()
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            root.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12)
        ])
        created.contentView = content
        BiscuitLocalization.applyInterfaceDirection(to: created)
        panel = created
    }

    private func refreshRows() {
        guard let store, let list = rowStack else { return }
        for view in list.arrangedSubviews {
            list.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        let visibleItems = store.items.filter { showsCompleted || !$0.isCompleted }
        if visibleItems.isEmpty {
            let message = store.items.isEmpty
                ? BiscuitLocalization.string("Add a task above. Star important items, set an optional date, and mark work complete when done.")
                : BiscuitLocalization.string("No open todos. Turn on Show Completed to review or clear completed items.")
            let empty = NSTextField(wrappingLabelWithString: message)
            empty.textColor = .secondaryLabelColor
            list.addArrangedSubview(empty)
        } else {
            for item in visibleItems { list.addArrangedSubview(makeRow(for: item)) }
        }
        for view in list.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: list.widthAnchor, constant: -13).isActive = true
        }
        list.layoutSubtreeIfNeeded()
        let width = max(scrollView?.contentSize.width ?? 400, 300)
        list.setFrameSize(NSSize(width: width, height: max(list.fittingSize.height, 30)))
    }

    private func makeRow(for item: TodoItem) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 4
        row.edgeInsets = NSEdgeInsets(top: 5, left: 5, bottom: 5, right: 5)
        row.wantsLayer = true
        row.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        row.layer?.cornerRadius = 6

        let text = NSTextField(string: item.text)
        text.identifier = NSUserInterfaceItemIdentifier(item.id.uuidString)
        text.delegate = self
        text.toolTip = BiscuitLocalization.string("Edit todo text")
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        text.widthAnchor.constraint(greaterThanOrEqualToConstant: 72).isActive = true
        text.textColor = item.isCompleted ? .secondaryLabelColor : .labelColor
        row.addArrangedSubview(text)

        let star = NSButton(title: item.isStarred ? "★" : "☆", target: self, action: #selector(toggleStar(_:)))
        star.todoID = item.id
        star.toolTip = BiscuitLocalization.string(item.isStarred ? "Unstar" : "Star")
        star.widthAnchor.constraint(equalToConstant: 24).isActive = true
        row.addArrangedSubview(star)

        let due = NSButton(checkboxWithTitle: BiscuitLocalization.string("Due"), target: self, action: #selector(toggleDue(_:)))
        due.todoID = item.id
        due.state = item.dueDate == nil ? .off : .on
        due.toolTip = BiscuitLocalization.string("Enable or remove due date")
        row.addArrangedSubview(due)

        let date = NSDatePicker()
        date.todoID = item.id
        date.datePickerElements = [.yearMonthDay]
        date.datePickerStyle = .textFieldAndStepper
        date.dateValue = item.dueDate ?? Calendar.current.startOfDay(for: Date())
        date.isEnabled = item.dueDate != nil
        date.target = self
        date.action = #selector(changeDueDate(_:))
        date.widthAnchor.constraint(equalToConstant: 106).isActive = true
        row.addArrangedSubview(date)

        let complete = NSButton(checkboxWithTitle: BiscuitLocalization.string("Done"), target: self, action: #selector(toggleComplete(_:)))
        complete.todoID = item.id
        complete.state = item.isCompleted ? .on : .off
        row.addArrangedSubview(complete)

        let delete = NSButton(title: "×", target: self, action: #selector(deleteTodo(_:)))
        delete.todoID = item.id
        delete.toolTip = BiscuitLocalization.string("Delete todo")
        delete.widthAnchor.constraint(equalToConstant: 22).isActive = true
        row.addArrangedSubview(delete)
        return row
    }

    @objc private func toggleShowCompleted(_ sender: NSButton) {
        showsCompleted = sender.state == .on
        refreshRows()
    }

    @objc private func clearCompleted(_ sender: NSButton) {
        do {
            guard let store else { throw startupError ?? TodoStoreError.itemUnavailable }
            let count = try store.clearCompleted()
            refreshRows()
            statusLabel?.stringValue = count == 0
                ? BiscuitLocalization.string("No completed todos to clear.")
                : BiscuitLocalization.format("Cleared %d completed todo(s).", arguments: [count])
            statusLabel?.textColor = .secondaryLabelColor
        } catch {
            refreshRows()
            report(error)
        }
    }

    @objc private func addTodo(_ sender: NSControl) {
        guard let field = addField else { return }
        guard let store else {
            report(startupError ?? TodoStoreError.itemUnavailable)
            return
        }
        do {
            try store.add(text: field.stringValue)
            field.stringValue = ""
            updateMonitoringMessage()
            refreshRows()
        } catch { report(error) }
    }

    public func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField,
              let id = field.identifier.flatMap({ UUID(uuidString: $0.rawValue) }) else { return }
        do {
            guard let store else { throw startupError ?? TodoStoreError.itemUnavailable }
            try store.updateText(field.stringValue, for: id)
            updateMonitoringMessage()
            refreshRows()
        } catch {
            refreshRows()
            report(error)
        }
    }

    @objc private func toggleStar(_ sender: NSButton) {
        guard let id = sender.todoID else { return }
        performStoreChange { try $0.setStarred(!(self.store?.items.first(where: { $0.id == id })?.isStarred ?? false), for: id) }
    }

    @objc private func toggleDue(_ sender: NSButton) {
        guard let id = sender.todoID else { return }
        let date = sender.state == .on ? Calendar.current.startOfDay(for: Date()) : nil
        performStoreChange { try $0.setDueDate(date, for: id) }
    }

    @objc private func changeDueDate(_ sender: NSDatePicker) {
        guard let id = sender.todoID else { return }
        let date = Calendar.current.startOfDay(for: sender.dateValue)
        performStoreChange { try $0.setDueDate(date, for: id) }
    }

    @objc private func toggleComplete(_ sender: NSButton) {
        guard let id = sender.todoID else { return }
        performStoreChange { try $0.setCompleted(sender.state == .on, for: id) }
    }

    @objc private func deleteTodo(_ sender: NSButton) {
        guard let id = sender.todoID else { return }
        performStoreChange { try $0.delete(id) }
    }

    private func performStoreChange(_ change: (TodoStore) throws -> Void) {
        do {
            guard let store else { throw startupError ?? TodoStoreError.itemUnavailable }
            try change(store)
            refreshRows()
            updateMonitoringMessage()
        } catch {
            refreshRows()
            report(error)
        }
    }
    private func updateMonitoringMessage() {
        guard let statusLabel, store != nil else { return }
        var messages = [BiscuitLocalization.string("Starred items stay at the top.")]
        if globalMonitoringUnavailable {
            messages.append(BiscuitLocalization.string("Pointer-edge access is unavailable; use Option-D."))
        }
        if needsAccessibilityPermission {
            messages.append(BiscuitLocalization.string("Escape works when Todos has keyboard focus; allow Accessibility and reopen for global Escape."))
        } else if globalEscapeUnavailable {
            messages.append(BiscuitLocalization.string("Escape works only while Todos has keyboard focus."))
        } else {
            messages.append(BiscuitLocalization.string("Escape dismisses even while another app is active."))
        }
        if isKeepOnTopEnabled {
            messages.append(BiscuitLocalization.string("Keep on Top keeps the panel visible after focus changes."))
        } else {
            messages.append(BiscuitLocalization.string(globalClickUnavailable
                ? "Outside-click dismissal may fail in other apps."
                : "Click outside the panel to dismiss."))
        }
        statusLabel.stringValue = messages.joined(separator: " ")
        statusLabel.textColor = globalMonitoringUnavailable || globalEscapeUnavailable || (!isKeepOnTopEnabled && globalClickUnavailable)
            ? .systemOrange
            : .secondaryLabelColor
        escapePermissionButton?.isHidden = !needsAccessibilityPermission
    }
    private func installDismissMonitors() {
        guard panel?.isVisible == true, globalClickMonitor == nil,
              globalEscapeMonitor == nil, localDismissMonitor == nil else { return }
        let clickMask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: clickMask) { [weak self] _ in
            DispatchQueue.main.async { self?.dismissIfOutside() }
        }
        needsAccessibilityPermission = !AXIsProcessTrusted()
        if !needsAccessibilityPermission {
            globalEscapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard event.keyCode == 53 else { return }
                DispatchQueue.main.async {
                    guard let self, self.panel?.isVisible == true else { return }
                    self.hidePanel()
                }
            }
        }
        globalEscapeUnavailable = needsAccessibilityPermission || globalEscapeMonitor == nil
        localDismissMonitor = NSEvent.addLocalMonitorForEvents(matching: clickMask.union(.keyDown)) { [weak self] event in
            guard let self, self.panel?.isVisible == true else { return event }
            if event.type == .keyDown && event.keyCode == 53 {
                self.hidePanel()
                return nil
            }
            if event.type == .leftMouseDown || event.type == .rightMouseDown || event.type == .otherMouseDown {
                self.dismissIfOutside()
            }
            return event
        }
        globalClickUnavailable = globalClickMonitor == nil
    }

    private func removeDismissMonitors() {
        if let globalClickMonitor { NSEvent.removeMonitor(globalClickMonitor) }
        if let globalEscapeMonitor { NSEvent.removeMonitor(globalEscapeMonitor) }
        if let localDismissMonitor { NSEvent.removeMonitor(localDismissMonitor) }
        globalClickMonitor = nil
        globalEscapeMonitor = nil
        localDismissMonitor = nil
        globalEscapeUnavailable = false
        needsAccessibilityPermission = false
        globalClickUnavailable = false
    }

    @objc private func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func revealTodoFile() {
        let file = TodoStore.defaultFileURL()
        let target = FileManager.default.fileExists(atPath: file.path) ? file : file.deletingLastPathComponent()
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    private func dismissIfOutside() {
        guard let panel, panel.isVisible, !isShowingMoreMenu, !isKeepOnTopEnabled,
              !panel.frame.contains(NSEvent.mouseLocation) else { return }
        hidePanel()
    }

    public func windowDidMove(_ notification: Notification) {
        guard let panel, let movedWindow = notification.object as? NSWindow, movedWindow === panel else { return }
        let topLeft = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
        if let screen = panel.screen,
           Self.shouldClearSavedPanelPosition(frame: panel.frame, visibleFrame: screen.visibleFrame) {
            Self.savePanelTopLeft(nil, defaults: BiscuitPreferences.defaults)
        } else {
            Self.savePanelTopLeft(topLeft, defaults: BiscuitPreferences.defaults)
        }
    }

    public func windowDidResignKey(_ notification: Notification) {
        guard let panel, panel.isVisible,
              let resignedWindow = notification.object as? NSWindow, resignedWindow === panel,
              !isShowingMoreMenu,
              Self.shouldHideAfterKeyLoss(
                keepOnTop: isKeepOnTopEnabled,
                keyWindowIsPanel: NSApp.keyWindow === panel
              ) else { return }
        hidePanel()
    }

    public func windowWillClose(_ notification: Notification) {
        guard let panel, let closedWindow = notification.object as? NSWindow, closedWindow === panel else { return }
        edgeOpenedPanel = false
        removeDismissMonitors()
    }



    private func report(_ error: Error) {
        statusLabel?.stringValue = error.localizedDescription
        statusLabel?.textColor = .systemRed
        if panel?.isVisible != true { showError(error) }
    }

    private func showError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = BiscuitLocalization.string("Todos unavailable")
        alert.informativeText = error.localizedDescription
        BiscuitLocalization.applyInterfaceDirection(to: alert)
        _ = BiscuitPresentation.runModal(alert)
    }
}

private extension NSView {
    var todoID: UUID? {
        get { identifier.flatMap { UUID(uuidString: $0.rawValue) } }
        set { identifier = newValue.map { NSUserInterfaceItemIdentifier($0.uuidString) } }
    }
}

import AppKit
import Foundation
import UniformTypeIdentifiers

enum LanguageMode: Hashable {
    case translate
    case learn
}

struct StudyDraftKey: Hashable {
    let mode: LanguageMode
    let requestedText: String
    let noteID: UUID?
}

struct StudyDraft: Equatable {
    let original: String
    let explanation: String
    let vocabulary: String
    let personalNotes: String
    let provider: String?

    init(
        original: String,
        explanation: String,
        vocabulary: String,
        personalNotes: String,
        provider: String? = nil
    ) {
        self.original = original
        self.explanation = explanation
        self.vocabulary = vocabulary
        self.personalNotes = personalNotes
        self.provider = provider
    }
}

/// Keeps unsaved editors independent from the durable notebook and from one another.
struct StudyDraftStore {
    private var values: [StudyDraftKey: StudyDraft] = [:]

    func draft(for key: StudyDraftKey) -> StudyDraft? { values[key] }

    mutating func store(_ draft: StudyDraft, for key: StudyDraftKey) {
        values[key] = draft
    }

    mutating func rekey(from oldKey: StudyDraftKey, to newKey: StudyDraftKey) {
        guard oldKey != newKey, let draft = values.removeValue(forKey: oldKey) else { return }
        values[newKey] = draft
    }
}

struct StudyNote: Codable, Identifiable, Equatable {
    let id: UUID
    let date: Date
    let provider: String
    let original: String
    let explanation: String
    let vocabulary: String
    let personalNotes: String
    let legacyMarkdown: String?

    init(
        id: UUID = UUID(),
        date: Date = Date(),
        provider: String,
        original: String,
        explanation: String,
        vocabulary: String = "",
        personalNotes: String = "",
        legacyMarkdown: String? = nil
    ) {
        self.id = id
        self.date = date
        self.provider = provider
        self.original = original
        self.explanation = explanation
        self.vocabulary = vocabulary
        self.personalNotes = personalNotes
        self.legacyMarkdown = legacyMarkdown
    }

    private enum CodingKeys: String, CodingKey {
        case id, date, provider, original, explanation, vocabulary, personalNotes, legacyMarkdown
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        date = try values.decode(Date.self, forKey: .date)
        provider = try values.decodeIfPresent(String.self, forKey: .provider) ?? "Unknown"
        original = try values.decodeIfPresent(String.self, forKey: .original) ?? ""
        explanation = try values.decodeIfPresent(String.self, forKey: .explanation) ?? ""
        vocabulary = try values.decodeIfPresent(String.self, forKey: .vocabulary) ?? ""
        personalNotes = try values.decodeIfPresent(String.self, forKey: .personalNotes) ?? ""
        legacyMarkdown = try values.decodeIfPresent(String.self, forKey: .legacyMarkdown)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(date, forKey: .date)
        try values.encode(provider, forKey: .provider)
        try values.encode(original, forKey: .original)
        try values.encode(explanation, forKey: .explanation)
        try values.encode(vocabulary, forKey: .vocabulary)
        try values.encode(personalNotes, forKey: .personalNotes)
        try values.encodeIfPresent(legacyMarkdown, forKey: .legacyMarkdown)
    }
}

enum StudyNoteStoreError: LocalizedError {
    case invalidStore
    case noteUnavailable
    case pasteboardWriteFailed
    case protectedExportTarget

    var errorDescription: String? {
        switch self {
        case .invalidStore:
            return BiscuitLocalization.string("Study Notes could not be read. The original file was left untouched.")
        case .noteUnavailable:
            return BiscuitLocalization.string("This study note is no longer available.")
        case .pasteboardWriteFailed:
            return BiscuitLocalization.string("The study note could not be copied to the clipboard.")
        case .protectedExportTarget:
            return BiscuitLocalization.string("Study Notes cannot be exported over its notebook or original legacy file.")
        }
    }
}

/// Durable study notes are separate from generic Library text history. The legacy Markdown file is
/// imported once and is never modified or removed by this store.
@MainActor final class StudyNoteStore {
    let dataDirectory: URL
    let manifestURL: URL
    let legacyMarkdownURL: URL
    private(set) var notes: [StudyNote]

    init(dataDirectory: URL? = nil) throws {
        let root = dataDirectory ?? Self.defaultDataDirectory()
        self.dataDirectory = root
        manifestURL = root.appendingPathComponent("study-notes.json", isDirectory: false)
        legacyMarkdownURL = root.appendingPathComponent("study-notes.md", isDirectory: false)
        notes = []
        // Even an empty canonical array means migration finished, preventing deleted notes from returning.

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: manifestURL.path) {
            let data = try Data(contentsOf: manifestURL)
            let decoded: [StudyNote]
            do { decoded = try JSONDecoder().decode([StudyNote].self, from: data) }
            catch { throw StudyNoteStoreError.invalidStore }
            guard Self.valid(decoded) else { throw StudyNoteStoreError.invalidStore }
            notes = Self.ordered(decoded)
            return
        }

        guard fileManager.fileExists(atPath: legacyMarkdownURL.path) else { return }
        let markdown: String
        do { markdown = try String(contentsOf: legacyMarkdownURL, encoding: .utf8) }
        catch { throw StudyNoteStoreError.invalidStore }
        let imported = Self.parseLegacyMarkdown(markdown)
        guard !imported.isEmpty else { return }
        try persist(imported)
        notes = Self.ordered(imported)
    }

    static func defaultDataDirectory() -> URL {
        if let override = ProcessInfo.processInfo.environment["BISCUIT_DATA_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("biscuit", isDirectory: true)
    }

    @discardableResult
    func add(
        original: String,
        explanation: String,
        provider: String,
        vocabulary: String = "",
        personalNotes: String = "",
        date: Date = Date()
    ) throws -> StudyNote {
        let note = StudyNote(
            date: date,
            provider: provider,
            original: original,
            explanation: explanation,
            vocabulary: vocabulary,
            personalNotes: personalNotes
        )
        try save(note)
        return note
    }

    func save(_ note: StudyNote) throws {
        var updated = notes
        if let index = updated.firstIndex(where: { $0.id == note.id }) {
            updated[index] = note
        } else {
            updated.append(note)
        }
        let ordered = Self.ordered(updated)
        try persist(ordered)
        notes = ordered
    }

    func remove(_ id: UUID) throws {
        guard notes.contains(where: { $0.id == id }) else { throw StudyNoteStoreError.noteUnavailable }
        let updated = notes.filter { $0.id != id }
        try persist(updated)
        notes = updated
    }

    func search(_ query: String) -> [StudyNote] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return notes }
        return notes.filter { note in
            note.provider.localizedCaseInsensitiveContains(needle) ||
            note.original.localizedCaseInsensitiveContains(needle) ||
            note.explanation.localizedCaseInsensitiveContains(needle) ||
            note.vocabulary.localizedCaseInsensitiveContains(needle) ||
            note.personalNotes.localizedCaseInsensitiveContains(needle) ||
            (note.legacyMarkdown?.localizedCaseInsensitiveContains(needle) ?? false)
        }
    }

    func markdown(for note: StudyNote) -> String {
        if let legacyMarkdown = note.legacyMarkdown { return Self.terminated(legacyMarkdown) }
        var sections = ["# Study Note", "Date: \(Self.dateLabel(note.date))", "Provider: \(note.provider)"]
        if !note.vocabulary.isEmpty { sections.append("## Vocabulary\n\n\(note.vocabulary)") }
        if !note.original.isEmpty { sections.append("## Original\n\n\(note.original)") }
        if !note.explanation.isEmpty { sections.append("## Explanation\n\n\(note.explanation)") }
        if !note.personalNotes.isEmpty { sections.append("## Your Notes\n\n\(note.personalNotes)") }
        return sections.joined(separator: "\n\n") + "\n"
    }

    func markdown(for id: UUID) throws -> String {
        guard let note = notes.first(where: { $0.id == id }) else { throw StudyNoteStoreError.noteUnavailable }
        return markdown(for: note)
    }

    func export(_ note: StudyNote, to destination: URL) throws {
        guard let current = notes.first(where: { $0.id == note.id }) else { throw StudyNoteStoreError.noteUnavailable }
        try Data(markdown(for: current).utf8).write(to: try exportTarget(destination), options: .atomic)
    }

    func exportAll(to destination: URL) throws {
        let content = notes.isEmpty ? "# biscuit Study Notes\n" :
            "# biscuit Study Notes\n\n" + notes.map { markdown(for: $0).trimmingCharacters(in: .newlines) }.joined(separator: "\n\n") + "\n"
        try Data(content.utf8).write(to: try exportTarget(destination), options: .atomic)
    }

    private func exportTarget(_ destination: URL) throws -> URL {
        let target = destination.standardizedFileURL.resolvingSymlinksInPath()
        let protected = [manifestURL, legacyMarkdownURL].map { $0.standardizedFileURL.resolvingSymlinksInPath() }
        guard !protected.contains(target) else { throw StudyNoteStoreError.protectedExportTarget }
        return destination
    }

    private func persist(_ updated: [StudyNote]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(updated).write(to: manifestURL, options: .atomic)
    }

    private static func valid(_ notes: [StudyNote]) -> Bool {
        var ids = Set<UUID>()
        return notes.allSatisfy { ids.insert($0.id).inserted }
    }

    private static func ordered(_ notes: [StudyNote]) -> [StudyNote] {
        notes.sorted {
            if $0.date != $1.date { return $0.date > $1.date }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    private static func parseLegacyMarkdown(_ markdown: String) -> [StudyNote] {
        let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        guard !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }

        let headings = lines.indices.filter { index in
            guard lines[index].hasPrefix("## ") else { return false }
            let nextContent = lines[(index + 1)...].first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            return nextContent == "Language study" || nextContent?.hasPrefix("Vocabulary:") == true ||
                nextContent == "Source text:" || nextContent == "Translation / explanation:" || nextContent == "Notes:"
        }

        guard !headings.isEmpty else {
            let bodyLines = lines.filter { !$0.hasPrefix("# biscuit Study Notes") }
            let body = bodyLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { return [] }
            return [StudyNote(
                provider: "Legacy import",
                original: "",
                explanation: "",
                personalNotes: body,
                legacyMarkdown: normalized
            )]
        }

        var notes: [StudyNote] = []
        let firstHeading = headings[0]
        let preamble = lines[..<firstHeading].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if !preamble.isEmpty && preamble != "# biscuit Study Notes" {
            notes.append(StudyNote(provider: "Legacy import", original: "", explanation: "", personalNotes: preamble, legacyMarkdown: preamble))
        }

        for (position, headingIndex) in headings.enumerated() {
            let end = position + 1 < headings.count ? headings[position + 1] : lines.count
            let raw = lines[headingIndex..<end].joined(separator: "\n").trimmingCharacters(in: .newlines)
            let body = Array(lines[(headingIndex + 1)..<end])
            let fields = legacyFields(body)
            guard !fields.original.isEmpty || !fields.explanation.isEmpty || !fields.vocabulary.isEmpty || !fields.notes.isEmpty else {
                if !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    notes.append(StudyNote(provider: "Legacy import", original: "", explanation: "", personalNotes: raw, legacyMarkdown: raw))
                }
                continue
            }
            let title = lines[headingIndex].dropFirst(3).trimmingCharacters(in: .whitespaces)
            notes.append(StudyNote(
                date: parsedDate(title) ?? Date(),
                provider: "Legacy import",
                original: fields.original,
                explanation: fields.explanation,
                vocabulary: fields.vocabulary,
                personalNotes: fields.notes,
                legacyMarkdown: raw
            ))
        }
        return notes
    }

    private static func legacyFields(_ lines: [String]) -> (original: String, explanation: String, vocabulary: String, notes: String) {
        enum Field: Hashable { case ignored, original, explanation, vocabulary, notes }
        var field = Field.ignored
        var values: [Field: [String]] = [:]
        for line in lines {
            if line == "Language study" { field = .ignored; continue }
            if line == "Source text:" { field = .original; continue }
            if line == "Translation / explanation:" { field = .explanation; continue }
            if line == "Notes:" { field = .notes; continue }
            if line.hasPrefix("Vocabulary:") {
                field = .vocabulary
                let value = String(line.dropFirst("Vocabulary:".count)).trimmingCharacters(in: .whitespaces)
                if !value.isEmpty { values[.vocabulary, default: []].append(value) }
                continue
            }
            values[field, default: []].append(line)
        }
        func joined(_ field: Field) -> String {
            var fieldLines = values[field] ?? []
            if fieldLines.last?.isEmpty == true { fieldLines.removeLast() }
            return fieldLines.joined(separator: "\n")
        }
        return (joined(.original), joined(.explanation), joined(.vocabulary), joined(.notes))
    }

    private static func parsedDate(_ title: String) -> Date? {
        if let date = ISO8601DateFormatter().date(from: title) { return date }
        for dateStyle in [DateFormatter.Style.short, .medium, .long, .full] {
            for timeStyle in [DateFormatter.Style.none, .short, .medium, .long, .full] {
                let formatter = DateFormatter()
                formatter.dateStyle = dateStyle
                formatter.timeStyle = timeStyle
                formatter.isLenient = false
                if let date = formatter.date(from: title) { return date }
            }
        }
        return nil
    }

    private static func dateLabel(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    private static func terminated(_ text: String) -> String {
        text.hasSuffix("\n") ? text : text + "\n"
    }
}

@MainActor final class StudyNotebookWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSWindowDelegate {
    private let store: StudyNoteStore
    private let onOpen: (StudyNote) -> Void
    private var displayedNotes: [StudyNote] = []
    private let searchField = NSSearchField()
    private let tableView = NSTableView()
    private let detailView = NSTextView()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let copyButton = NSButton(title: BiscuitLocalization.string("Copy"), target: nil, action: nil)
    private let openButton = NSButton(title: BiscuitLocalization.string("Open in Study"), target: nil, action: nil)
    private let exportButton = NSButton(title: BiscuitLocalization.string("Export Note…"), target: nil, action: nil)
    private let exportAllButton = NSButton(title: BiscuitLocalization.string("Export All…"), target: nil, action: nil)
    private let deleteButton = NSButton(title: BiscuitLocalization.string("Delete"), target: nil, action: nil)

    init(store: StudyNoteStore, onOpen: @escaping (StudyNote) -> Void) {
        self.store = store
        self.onOpen = onOpen
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 590), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = BiscuitLocalization.string("biscuit Study Notes")
        window.minSize = NSSize(width: 680, height: 420)
        window.contentView = NSView()
        window.isReleasedWhenClosed = false
        super.init(window: window)
        buildInterface()
        BiscuitLocalization.applyInterfaceDirection(to: window)
        refresh()
    }

    required init?(coder: NSCoder) { nil }

    func showNotebook(selectedNoteID: UUID? = nil) {
        refresh(selecting: selectedNoteID)
        BiscuitPresentation.center(window)
        guard BiscuitPresentation.show(window) else { return }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildInterface() {
        guard let window, let content = window.contentView else { return }
        window.delegate = self
        searchField.placeholderString = BiscuitLocalization.string("Search saved study notes")
        searchField.delegate = self

        let dateColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("date"))
        dateColumn.title = BiscuitLocalization.string("Saved")
        dateColumn.width = 150
        let summaryColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("summary"))
        summaryColumn.title = BiscuitLocalization.string("Vocabulary / Original")
        summaryColumn.width = 260
        let providerColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("provider"))
        providerColumn.title = BiscuitLocalization.string("Provider")
        providerColumn.width = 120
        tableView.addTableColumn(dateColumn)
        tableView.addTableColumn(summaryColumn)
        tableView.addTableColumn(providerColumn)
        tableView.headerView = NSTableHeaderView()
        tableView.dataSource = self
        tableView.delegate = self
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = false
        tableView.rowHeight = 30
        tableView.frame = NSRect(x: 0, y: 0, width: 530, height: 400)
        let tableScroll = NSScrollView()
        tableScroll.hasVerticalScroller = true
        tableScroll.hasHorizontalScroller = true
        tableView.autoresizingMask = [.width, .height]
        tableScroll.documentView = tableView

        detailView.isEditable = false
        detailView.isSelectable = true
        detailView.font = .systemFont(ofSize: 13)
        detailView.textContainerInset = NSSize(width: 12, height: 12)
        let detailScroll = NSScrollView()
        detailScroll.hasVerticalScroller = true
        detailScroll.borderType = .bezelBorder
        detailView.frame = NSRect(x: 0, y: 0, width: 460, height: 400)
        detailView.autoresizingMask = [.width]
        detailScroll.documentView = detailView

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.addSubview(tableScroll)
        split.addSubview(detailScroll)
        split.setPosition(390, ofDividerAt: 0)

        let actions = NSStackView(views: [openButton, copyButton, exportButton, exportAllButton, deleteButton])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.distribution = .fill
        actions.spacing = 8
        for (button, action) in [(openButton, #selector(openSelected(_:))), (copyButton, #selector(copySelected(_:))), (exportButton, #selector(exportSelected(_:))), (exportAllButton, #selector(exportAll(_:))), (deleteButton, #selector(deleteSelected(_:)))] {
            button.target = self
            button.action = action
        }
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 2

        let root = NSStackView(views: [searchField, split, actions, statusLabel])
        root.orientation = .vertical
        root.alignment = .width
        root.distribution = .fill
        root.spacing = 10
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            root.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
            searchField.heightAnchor.constraint(equalToConstant: 28),
            split.heightAnchor.constraint(greaterThanOrEqualToConstant: 320),
            actions.heightAnchor.constraint(equalToConstant: 28)
        ])
        updateActions()
    }

    func refresh(selecting id: UUID? = nil) {
        displayedNotes = store.search(searchField.stringValue)
        if let id, !displayedNotes.contains(where: { $0.id == id }) {
            searchField.stringValue = ""
            displayedNotes = store.notes
        }
        tableView.reloadData()
        let selection = id.flatMap { target in displayedNotes.firstIndex(where: { $0.id == target }) }
        if let selection { tableView.selectRowIndexes(IndexSet(integer: selection), byExtendingSelection: false) }
        else if !displayedNotes.isEmpty { tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        showDetail(selectedNote)
        if let window { BiscuitLocalization.applyInterfaceDirection(to: window) }
    }

    private var selectedNote: StudyNote? {
        let row = tableView.selectedRow
        guard displayedNotes.indices.contains(row) else { return nil }
        return displayedNotes[row]
    }

    private func showDetail(_ note: StudyNote?) {
        detailView.string = note.map { store.markdown(for: $0) } ?? BiscuitLocalization.string("Select a saved note to view its original text, explanation, vocabulary and personal notes.")
        updateActions()
    }

    private func updateActions() {
        let hasSelection = selectedNote != nil
        openButton.isEnabled = hasSelection
        copyButton.isEnabled = hasSelection
        exportButton.isEnabled = hasSelection
        deleteButton.isEnabled = hasSelection
        exportAllButton.isEnabled = !store.notes.isEmpty
    }

    func numberOfRows(in tableView: NSTableView) -> Int { displayedNotes.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard displayedNotes.indices.contains(row), let identifier = tableColumn?.identifier else { return nil }
        let note = displayedNotes[row]
        let cellID = NSUserInterfaceItemIdentifier("StudyNotebookCell.\(identifier.rawValue)")
        let cell = (tableView.makeView(withIdentifier: cellID, owner: self) as? NSTableCellView) ?? {
            let view = NSTableCellView()
            let label = NSTextField(labelWithString: "")
            label.lineBreakMode = .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(label)
            view.textField = label
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 6),
                label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -6),
                label.centerYAnchor.constraint(equalTo: view.centerYAnchor)
            ])
            view.identifier = cellID
            return view
        }()
        switch identifier.rawValue {
        case "date": cell.textField?.stringValue = note.date.formatted(.dateTime.locale(BiscuitLocalization.locale))
        case "provider": cell.textField?.stringValue = note.provider
        default:
            let title = note.vocabulary.isEmpty ? note.original : note.vocabulary
            cell.textField?.stringValue = title.isEmpty ? BiscuitLocalization.string("Saved study note") : title
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) { showDetail(selectedNote) }
    func controlTextDidChange(_ notification: Notification) { refresh() }

    @objc private func openSelected(_ sender: Any?) {
        guard let note = selectedNote else { return }
        onOpen(note)
        statusLabel.stringValue = BiscuitLocalization.string("Opened this saved note in Language Learning.")
    }

    @objc private func copySelected(_ sender: Any?) {
        guard let note = selectedNote else { return }
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(store.markdown(for: note), forType: .string) else {
            statusLabel.stringValue = StudyNoteStoreError.pasteboardWriteFailed.localizedDescription
            return
        }
        statusLabel.stringValue = BiscuitLocalization.string("Copied the saved study note.")
    }

    @objc private func exportSelected(_ sender: Any?) {
        guard let note = selectedNote, let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = Self.exportFilename(for: note)
        BiscuitLocalization.applyInterfaceDirection(to: panel)
        BiscuitPresentation.beginSheet(panel, for: window) { [weak self] response in
            guard response == .OK, let destination = panel.url, let self else { return }
            do {
                try self.store.export(note, to: destination)
                self.statusLabel.stringValue = BiscuitLocalization.string("Exported the saved study note.")
            } catch {
                self.statusLabel.stringValue = BiscuitLocalization.format("Could not export study note: %1$@", arguments: [error.localizedDescription])
            }
        }
    }

    @objc private func exportAll(_ sender: Any?) {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = "biscuit-study-notes.md"
        BiscuitLocalization.applyInterfaceDirection(to: panel)
        BiscuitPresentation.beginSheet(panel, for: window) { [weak self] response in
            guard response == .OK, let destination = panel.url, let self else { return }
            do {
                try self.store.exportAll(to: destination)
                self.statusLabel.stringValue = BiscuitLocalization.string("Exported all saved study notes.")
            } catch {
                self.statusLabel.stringValue = BiscuitLocalization.format("Could not export study notes: %1$@", arguments: [error.localizedDescription])
            }
        }
    }

    @objc private func deleteSelected(_ sender: Any?) {
        guard let note = selectedNote, let window else { return }
        let alert = NSAlert()
        alert.messageText = BiscuitLocalization.string("Delete this study note?")
        alert.informativeText = BiscuitLocalization.string("This removes the note from the in-app notebook. The original legacy Markdown file, if any, is not changed.")
        alert.addButton(withTitle: BiscuitLocalization.string("Delete"))
        alert.addButton(withTitle: BiscuitLocalization.string("Cancel"))
        BiscuitLocalization.applyInterfaceDirection(to: alert)
        BiscuitPresentation.beginSheet(alert, for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            do {
                try self.store.remove(note.id)
                self.statusLabel.stringValue = BiscuitLocalization.string("Deleted the saved study note.")
                self.refresh()
            } catch {
                self.statusLabel.stringValue = BiscuitLocalization.format("Could not delete study note: %1$@", arguments: [error.localizedDescription])
            }
        }
    }

    private static func exportFilename(for note: StudyNote) -> String {
        let source = note.vocabulary.isEmpty ? note.original : note.vocabulary
        let stem = source.split(whereSeparator: \.isNewline).first.map(String.init) ?? "study-note"
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_"))
        let sanitized = String(stem.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
            .trimmingCharacters(in: CharacterSet(charactersIn: " -_"))
        return (sanitized.isEmpty ? "study-note" : String(sanitized.prefix(64))) + ".md"
    }
}


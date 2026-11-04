import Foundation

#if !BISCUIT_SMOKE
@main
#endif
@MainActor
enum StudyNotebookBehaviorChecks {
    private struct CheckFailure: Error, LocalizedError {
        let description: String
        var errorDescription: String? { description }
    }

    static func run() throws {
        let environment = ProcessInfo.processInfo.environment
        let buildRoot = environment["BISCUIT_BUILD_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? Bundle.main.bundleURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: buildRoot, withIntermediateDirectories: true)
        let scratch = buildRoot.appendingPathComponent("study-notebook-fixtures-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: scratch) }

        try verifyDraftCacheIsolatedAcrossKeys()
        try verifyMissingStoreIsEmpty(at: scratch.appendingPathComponent("missing", isDirectory: true))
        try verifySaveReopenSearchDeleteAndExport(at: scratch.appendingPathComponent("roundtrip", isDirectory: true))
        try verifyLegacyMigrationIsPreservingAndIdempotent(at: scratch.appendingPathComponent("legacy", isDirectory: true))
        try verifyFailedSaveAndInvalidStorePreserveDurableBytes(at: scratch)
        print("StudyNoteStore persistence, migration, deletion, search, export and draft-cache fixtures passed")
    }
    private static func verifyDraftCacheIsolatedAcrossKeys() throws {
        var drafts = StudyDraftStore()
        let learnKey = StudyDraftKey(mode: .learn, requestedText: "first fixture source", noteID: nil)
        let translateKey = StudyDraftKey(mode: .translate, requestedText: "second fixture source", noteID: nil)
        let savedNoteKey = StudyDraftKey(mode: .learn, requestedText: "", noteID: UUID())
        let learnDraft = StudyDraft(
            original: "edited fixture source",
            explanation: "fixture explanation",
            vocabulary: "fixture vocabulary",
            personalNotes: "fixture personal notes",
            provider: "claudeSubscription"
        )
        let translateDraft = StudyDraft(
            original: "second fixture source",
            explanation: "second fixture explanation",
            vocabulary: "",
            personalNotes: ""
        )
        drafts.store(learnDraft, for: learnKey)
        drafts.store(translateDraft, for: translateKey)
        try check(drafts.draft(for: learnKey) == learnDraft, "Switching modes must retain the complete first draft under its source key.")
        try check(drafts.draft(for: translateKey) == translateDraft, "A second source must not overwrite the first draft.")
        drafts.rekey(from: learnKey, to: savedNoteKey)
        try check(drafts.draft(for: savedNoteKey) == learnDraft, "Saving a draft must retain its current fields under the saved-note identity.")
        try check(drafts.draft(for: savedNoteKey)?.provider == "claudeSubscription", "Saved-note draft rekeying must preserve the provider that produced the explanation.")
        try check(drafts.draft(for: learnKey) == nil, "Rekeying a saved draft must not leave a stale source-key copy.")
        try check(drafts.draft(for: translateKey) == translateDraft, "Rekeying one draft must leave other mode/source drafts unchanged.")
    }

    #if !BISCUIT_SMOKE
    static func main() {
        do { try run() }
        catch {
            fputs("StudyNoteStore behavior checks failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
    #endif

    private static func verifyMissingStoreIsEmpty(at root: URL) throws {
        let store = try StudyNoteStore(dataDirectory: root)
        try check(store.notes.isEmpty, "A missing notebook must open as an empty notebook.")
        try check(!FileManager.default.fileExists(atPath: store.manifestURL.path), "Opening an empty notebook must not create a false saved note.")
    }

    private static func verifySaveReopenSearchDeleteAndExport(at root: URL) throws {
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let store = try StudyNoteStore(dataDirectory: root)
        let saved = try store.add(
            original: "A public fixture source.\nSecond line.",
            explanation: "Fixture explanation only; no provider request was made.",
            provider: "fixture-provider",
            vocabulary: "fixture vocabulary",
            personalNotes: "fixture personal note",
            date: date
        )
        let reopened = try StudyNoteStore(dataDirectory: root)
        try check(reopened.notes == [saved], "Saved IDs, date, provider, original, explanation, vocabulary and personal notes must round-trip exactly.")
        let revised = StudyNote(
            id: saved.id,
            date: saved.date,
            provider: "fixture-provider-revised",
            original: saved.original,
            explanation: saved.explanation,
            vocabulary: saved.vocabulary,
            personalNotes: "fixture personal note revised"
        )
        try reopened.save(revised)
        let afterSave = try StudyNoteStore(dataDirectory: root)
        try check(afterSave.notes == [revised], "Saving an existing note ID must update, not duplicate or lose, its durable fields.")
        try check(afterSave.search("FIXTURE VOCABULARY").map(\.id) == [saved.id], "Notebook search must include vocabulary case-insensitively.")
        try check(afterSave.search("fixture personal note revised").map(\.id) == [saved.id], "Notebook search must include personal notes.")

        let oneFile = root.appendingPathComponent("single-note.md")
        try afterSave.export(revised, to: oneFile)
        let singleMarkdown = try String(contentsOf: oneFile, encoding: .utf8)
        for expected in ["fixture-provider-revised", "fixture vocabulary", "A public fixture source.", "Fixture explanation only", "fixture personal note revised"] {
            try check(singleMarkdown.contains(expected), "Single-note Markdown export must include saved field: \(expected).")
        }
        let allFile = root.appendingPathComponent("all-notes.md")
        try afterSave.exportAll(to: allFile)
        let allMarkdown = try String(contentsOf: allFile, encoding: .utf8)
        try check(allMarkdown.contains("fixture-provider-revised") && allMarkdown.contains("fixture personal note revised"), "Notebook export must include complete real saved note data.")

        try afterSave.remove(saved.id)

        try reopened.remove(saved.id)
        try check(reopened.notes.isEmpty, "Delete must remove the saved note from the live notebook.")
        let afterDelete = try StudyNoteStore(dataDirectory: root)
        try check(afterDelete.notes.isEmpty, "Deleted notes must stay deleted after reopening.")
        do {
            try afterDelete.export(saved, to: root.appendingPathComponent("deleted.md"))
            throw CheckFailure(description: "A deleted note must not remain exportable through a stale value.")
        } catch StudyNoteStoreError.noteUnavailable { }

        let blockedExport = root.appendingPathComponent("study-notes.json")
        do {
            try afterDelete.exportAll(to: blockedExport)
            throw CheckFailure(description: "Notebook export must not overwrite its canonical persistence file.")
        } catch StudyNoteStoreError.protectedExportTarget { }
    }

    private static func verifyLegacyMigrationIsPreservingAndIdempotent(at root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let legacyURL = root.appendingPathComponent("study-notes.md")
        let savedDate = Date(timeIntervalSince1970: 1_790_000_000)
        let legacy = """
        # biscuit Study Notes

        ## \(savedDate.formatted())

        Language study

        Vocabulary: legacy fixture phrase

        Source text:
        legacy fixture original
        second original line

        Translation / explanation:
        legacy fixture explanation

        Notes:
        legacy fixture personal note
        """ + "\n"
        try Data(legacy.utf8).write(to: legacyURL, options: .atomic)
        let originalBytes = try Data(contentsOf: legacyURL)

        let migrated = try StudyNoteStore(dataDirectory: root)
        try check(migrated.notes.count == 1, "The exact legacy saveStudy heading/body format must import as one note.")
        guard let legacyNote = migrated.notes.first else { throw CheckFailure(description: "Migrated fixture is missing.") }
        try check(legacyNote.original == "legacy fixture original\nsecond original line", "Legacy source text must be recovered from the existing saveStudy format.")
        try check(legacyNote.explanation == "legacy fixture explanation", "Legacy explanation must be recovered.")
        try check(legacyNote.vocabulary == "legacy fixture phrase", "Legacy vocabulary must be retained as a note field.")
        try check(legacyNote.personalNotes == "legacy fixture personal note", "Legacy personal notes must be retained as a note field.")
        try check(abs(legacyNote.date.timeIntervalSince(savedDate)) < 60, "Legacy Date.formatted() headings must recover their saved date at the precision present in Markdown.")
        try check(legacyNote.provider == "Legacy import", "Legacy format without provider metadata must not invent a provider.")
        let migratedMarkdown = try migrated.markdown(for: legacyNote.id)
        try check(migratedMarkdown.contains("legacy fixture personal note"), "Legacy note Markdown remains exportable after import.")

        let newNote = try migrated.add(
            original: "native fixture original",
            explanation: "native fixture explanation",
            provider: "native-fixture-provider",
            vocabulary: "native fixture vocabulary",
            personalNotes: "native fixture personal note",
            date: savedDate.addingTimeInterval(60)
        )
        let afterNativeSave = try StudyNoteStore(dataDirectory: root)
        try check(afterNativeSave.notes.count == 2, "Legacy and newly saved native notes must coexist in canonical storage.")
        try afterNativeSave.remove(newNote.id)
        let afterNativeDelete = try StudyNoteStore(dataDirectory: root)
        try check(afterNativeDelete.notes.map(\.id) == [legacyNote.id], "A deleted native note must not be reimported on restart while legacy Markdown remains.")
        let bytesAfterNativeDelete = try Data(contentsOf: legacyURL)
        try check(bytesAfterNativeDelete == originalBytes, "Migration and deletion must leave original legacy Markdown bytes untouched.")
        try afterNativeDelete.remove(legacyNote.id)
        let afterLegacyDelete = try StudyNoteStore(dataDirectory: root)
        try check(afterLegacyDelete.notes.isEmpty, "Deleting imported notes must remain deleted even when their source Markdown remains.")
        let bytesAfterLegacyDelete = try Data(contentsOf: legacyURL)
        try check(bytesAfterLegacyDelete == originalBytes, "Deleting an imported notebook record must not delete or alter its original Markdown history.")
    }

    private static func verifyFailedSaveAndInvalidStorePreserveDurableBytes(at root: URL) throws {
        let failedRoot = root.appendingPathComponent("failed-save", isDirectory: true)
        let store = try StudyNoteStore(dataDirectory: failedRoot)
        let original = try store.add(original: "durable fixture", explanation: "before failure", provider: "fixture")
        let manifest = store.manifestURL
        let durableBytesBeforeFailure = try Data(contentsOf: manifest)
        let backup = root.appendingPathComponent("durable-before-failure.json")
        try FileManager.default.moveItem(at: manifest, to: backup)
        try FileManager.default.createDirectory(at: manifest, withIntermediateDirectories: false)
        let memoryBeforeFailure = store.notes
        var failed = false
        do {
            _ = try store.add(original: "must not persist", explanation: "fixture", provider: "fixture")
        } catch {
            failed = true
        }
        let durableBytesAfterFailure = try Data(contentsOf: backup)
        let memoryUnchanged = store.notes == memoryBeforeFailure
        try FileManager.default.removeItem(at: manifest)
        try FileManager.default.moveItem(at: backup, to: manifest)
        try check(failed, "A deterministic path obstruction must make the notebook save fail.")
        try check(memoryUnchanged, "A failed save must not replace in-memory notebook state.")
        try check(durableBytesAfterFailure == durableBytesBeforeFailure, "A failed save must preserve the prior durable bytes.")
        let reopened = try StudyNoteStore(dataDirectory: failedRoot)
        try check(reopened.notes == [original], "A failed save must leave the previous durable notebook recoverable.")

        let corruptRoot = root.appendingPathComponent("corrupt-store", isDirectory: true)
        try FileManager.default.createDirectory(at: corruptRoot, withIntermediateDirectories: true)
        let corruptManifest = corruptRoot.appendingPathComponent("study-notes.json")
        let corruptBytes = Data("not a notebook fixture".utf8)
        try corruptBytes.write(to: corruptManifest, options: .atomic)
        do {
            _ = try StudyNoteStore(dataDirectory: corruptRoot)
            throw CheckFailure(description: "A malformed canonical notebook must fail closed.")
        } catch StudyNoteStoreError.invalidStore { }
        let corruptBytesAfterFailure = try Data(contentsOf: corruptManifest)
        try check(corruptBytesAfterFailure == corruptBytes, "A malformed notebook must remain byte-for-byte untouched for recovery.")
    }

    private static func check(_ condition: @autoclosure () throws -> Bool, _ label: String) throws {
        guard try condition() else { throw CheckFailure(description: label) }
    }
}

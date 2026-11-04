import Foundation

struct MeasurementEntry: Codable, Equatable, Sendable {
    enum Operation: String, Codable, Sendable {
        case imageCapture, textCapture, translation, study
    }

    enum Outcome: String, Codable, Sendable {
        case succeeded, failed, cancelled
    }

    enum ModelProvenance: String, Codable, Sendable {
        case nativeBuiltIn, verifiedWebRoute
    }

    let schemaVersion: Int
    let date: Date
    let operation: Operation
    let outcome: Outcome
    // In capture entries, pixels describe the output image and points describe the selected ROI.
    // `scale` estimates display backing scale, not a stitched-output/ROI height ratio.
    let widthPixels: Int?
    let heightPixels: Int?
    let widthPoints: Double?
    let heightPoints: Double?
    let scale: Double?
    let captureMilliseconds: Double?
    let ocrMilliseconds: Double?
    let tableMilliseconds: Double?
    let translationMilliseconds: Double?
    let studyMilliseconds: Double?
    let endToEndMilliseconds: Double?
    let boxCount: Int?
    let characterCount: Int?
    let tableCount: Int?
    let tableRowCount: Int?
    let tableColumnCount: Int?
    let tableCellCount: Int?
    let averageConfidence: Double?
    let confidenceObservationCount: Int?
    let provider: String?
    var model: String?
    var modelProvenance: ModelProvenance?
    let recognitionEngine: String?
    let recognitionVariant: String?
    let recognitionLanguages: [String]?
    let languageCorrectionEnabled: Bool?
    let automaticLanguageDetectionEnabled: Bool?

    init(
        date: Date = Date(),
        operation: Operation,
        outcome: Outcome,
        widthPixels: Int? = nil,
        heightPixels: Int? = nil,
        widthPoints: Double? = nil,
        heightPoints: Double? = nil,
        scale: Double? = nil,
        captureMilliseconds: Double? = nil,
        ocrMilliseconds: Double? = nil,
        tableMilliseconds: Double? = nil,
        translationMilliseconds: Double? = nil,
        studyMilliseconds: Double? = nil,
        endToEndMilliseconds: Double? = nil,
        boxCount: Int? = nil,
        characterCount: Int? = nil,
        tableCount: Int? = nil,
        tableRowCount: Int? = nil,
        tableColumnCount: Int? = nil,
        tableCellCount: Int? = nil,
        averageConfidence: Double? = nil,
        confidenceObservationCount: Int? = nil,
        provider: String? = nil,
        model: String? = nil,
        recognitionEngine: String? = nil,
        recognitionVariant: String? = nil,
        recognitionLanguages: [String]? = nil,
        languageCorrectionEnabled: Bool? = nil,
        automaticLanguageDetectionEnabled: Bool? = nil
    ) {
        self.schemaVersion = 1
        self.date = date
        self.operation = operation
        self.outcome = outcome
        self.widthPixels = widthPixels
        self.heightPixels = heightPixels
        self.widthPoints = widthPoints
        self.heightPoints = heightPoints
        self.scale = scale
        self.captureMilliseconds = captureMilliseconds
        self.ocrMilliseconds = ocrMilliseconds
        self.tableMilliseconds = tableMilliseconds
        self.translationMilliseconds = translationMilliseconds
        self.studyMilliseconds = studyMilliseconds
        self.endToEndMilliseconds = endToEndMilliseconds
        self.boxCount = boxCount
        self.characterCount = characterCount
        self.tableCount = tableCount
        self.tableRowCount = tableRowCount
        self.tableColumnCount = tableColumnCount
        self.tableCellCount = tableCellCount
        self.averageConfidence = averageConfidence
        self.confidenceObservationCount = confidenceObservationCount
        self.provider = provider
        self.model = model
        self.modelProvenance = Self.catalogModelIdentifier(model, provider: provider) == nil ? nil : .nativeBuiltIn
        self.recognitionEngine = recognitionEngine
        self.recognitionVariant = recognitionVariant
        self.recognitionLanguages = recognitionLanguages
        self.languageCorrectionEnabled = languageCorrectionEnabled
        self.automaticLanguageDetectionEnabled = automaticLanguageDetectionEnabled
    }

    // Keep native identifiers aligned with NativeSubscription's defaults and the built-in Claude picker; Web routes require separate runtime verification.
    private static func catalogModelIdentifier(_ value: String?, provider: String?) -> String? {
        guard let value, let provider else { return nil }
        switch provider {
        case "chatgpt" where value == "gpt-5.3-codex" || value == "gpt-6.1-sol":
            return value
        case "claude" where value == "claude-sonnet-5-5" || value == "claude-haiku-4-5":
            return value
        default:
            return nil
        }
    }

    mutating func classifyModelIdentifier(verifiedWebRoute: String? = nil) {
        guard let model else {
            modelProvenance = nil
            return
        }
        if Self.catalogModelIdentifier(model, provider: provider) != nil {
            modelProvenance = .nativeBuiltIn
        } else if provider == "chatgptWeb", let verifiedWebRoute, model == verifiedWebRoute {
            modelProvenance = .verifiedWebRoute
        } else {
            self.model = nil
            modelProvenance = nil
        }
    }

    mutating func removeUnclassifiedModelIdentifier() {
        guard model != nil else {
            modelProvenance = nil
            return
        }
        if provider == "chatgptWeb", modelProvenance == .verifiedWebRoute { return }
        classifyModelIdentifier()
    }

    private func hasValidModelClassification() -> Bool {
        guard let model else { return modelProvenance == nil }
        switch modelProvenance {
        case .nativeBuiltIn:
            return Self.catalogModelIdentifier(model, provider: provider) == model
        case .verifiedWebRoute:
            return provider == "chatgptWeb"
        case nil:
            return false
        }
    }

    func isValid() -> Bool {
        let counts = [widthPixels, heightPixels, boxCount, characterCount, tableCount, tableRowCount,
                      tableColumnCount, tableCellCount, confidenceObservationCount].compactMap { $0 }
        let measurements = [widthPoints, heightPoints, scale, captureMilliseconds, ocrMilliseconds,
                            tableMilliseconds, translationMilliseconds, studyMilliseconds,
                            endToEndMilliseconds, averageConfidence].compactMap { $0 }
        guard schemaVersion == 1,
              date.timeIntervalSince1970.isFinite,
              counts.allSatisfy({ $0 >= 0 }),
              measurements.allSatisfy({ $0.isFinite && $0 >= 0 }),
              averageConfidence.map({ $0 <= 1 }) ?? true,
              hasValidModelClassification(),
              provider.map(Self.isSafeProvider) ?? true,
              recognitionLanguages.map({ $0.allSatisfy(Self.isSafeLanguageCode) }) ?? true,
              recognitionEngine.map({ $0 == "vision" }) ?? true,
              recognitionVariant.map({ ["accurate", "accurate-nocorrect"].contains($0) }) ?? true,
              (widthPixels == nil) == (heightPixels == nil),
              (widthPoints == nil) == (heightPoints == nil),
              (tableRowCount == nil) == (tableColumnCount == nil),
              (tableCellCount == nil) == (tableRowCount == nil),
              (averageConfidence == nil) == (confidenceObservationCount == nil),
              translationMilliseconds == nil || operation == .translation,
              studyMilliseconds == nil || operation == .study else { return false }

        if operation == .imageCapture || operation == .textCapture {
            guard provider == nil, model == nil else { return false }
        } else {
            guard let provider, Self.isSafeProvider(provider) else { return false }
        }
        if operation != .textCapture {
            guard ocrMilliseconds == nil, tableMilliseconds == nil, boxCount == nil, characterCount == nil,
                  tableCount == nil, tableRowCount == nil, tableColumnCount == nil, tableCellCount == nil,
                  averageConfidence == nil, confidenceObservationCount == nil, recognitionEngine == nil,
                  recognitionVariant == nil, recognitionLanguages == nil, languageCorrectionEnabled == nil,
                  automaticLanguageDetectionEnabled == nil else { return false }
        }
        return true
    }

    private static func isSafeProvider(_ value: String) -> Bool {
        ["apple", "chatgpt", "chatgptWeb", "claude", "claudeCLI"].contains(value)
    }

    private static func isSafeLanguageCode(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 32 else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
        return value.unicodeScalars.allSatisfy(allowed.contains)
    }
}

struct MeasurementSummary: Sendable {
    let runCount: Int
    let successfulRunCount: Int
    let failedRunCount: Int
    let cancelledRunCount: Int
    let endToEndP50: Double?
    let endToEndP95: Double?
    let ocrP50: Double?
    let translationP50: Double?
    let studyP50: Double?
    let totalBoxCount: Int?
    let totalCharacterCount: Int?
    let totalTableCount: Int?
    let totalTableCellCount: Int?
    let averageConfidence: Double?

    init(entries: [MeasurementEntry]) {
        runCount = entries.count
        var successes = 0
        var failures = 0
        var cancellations = 0
        var endToEndValues: [Double] = []
        var ocrValues: [Double] = []
        var translationValues: [Double] = []
        var studyValues: [Double] = []
        endToEndValues.reserveCapacity(entries.count)
        var boxes: Int?
        var characters: Int?
        var tables: Int?
        var tableCells: Int?
        var confidenceTotal = 0.0
        var confidenceCount = 0

        func add(_ value: Int?, to total: inout Int?) {
            guard let value else { return }
            total = (total ?? 0) + value
        }

        for entry in entries {
            switch entry.outcome {
            case .succeeded: successes += 1
            case .failed: failures += 1
            case .cancelled: cancellations += 1
            }
            if let value = entry.endToEndMilliseconds { endToEndValues.append(value) }
            switch entry.operation {
            case .textCapture:
                if let value = entry.ocrMilliseconds { ocrValues.append(value) }
                add(entry.boxCount, to: &boxes)
                add(entry.characterCount, to: &characters)
                add(entry.tableCount, to: &tables)
                add(entry.tableCellCount, to: &tableCells)
                if let average = entry.averageConfidence,
                   let count = entry.confidenceObservationCount, count > 0 {
                    confidenceTotal += average * Double(count)
                    confidenceCount += count
                }
            case .translation:
                if let value = entry.translationMilliseconds { translationValues.append(value) }
            case .study:
                if let value = entry.studyMilliseconds { studyValues.append(value) }
            case .imageCapture:
                break
            }
        }
        successfulRunCount = successes
        failedRunCount = failures
        cancelledRunCount = cancellations
        endToEndValues.sort()
        ocrValues.sort()
        translationValues.sort()
        studyValues.sort()
        endToEndP50 = Self.percentile(in: endToEndValues, fraction: 0.50)
        endToEndP95 = Self.percentile(in: endToEndValues, fraction: 0.95)
        ocrP50 = Self.percentile(in: ocrValues, fraction: 0.50)
        translationP50 = Self.percentile(in: translationValues, fraction: 0.50)
        studyP50 = Self.percentile(in: studyValues, fraction: 0.50)
        totalBoxCount = boxes
        totalCharacterCount = characters
        totalTableCount = tables
        totalTableCellCount = tableCells
        averageConfidence = confidenceCount == 0 ? nil : confidenceTotal / Double(confidenceCount)
    }

    static func percentile(_ values: [Double], fraction: Double) -> Double? {
        guard !values.isEmpty, fraction.isFinite, fraction >= 0, fraction <= 1 else { return nil }
        return Self.percentile(in: values.sorted(), fraction: fraction)
    }

    private static func percentile(in sortedValues: [Double], fraction: Double) -> Double? {
        guard !sortedValues.isEmpty, fraction.isFinite, fraction >= 0, fraction <= 1 else { return nil }
        let position = Double(sortedValues.count - 1) * fraction
        let lower = Int(position.rounded(.down))
        let upper = Int(position.rounded(.up))
        if lower == upper { return sortedValues[lower] }
        let interpolation = position - Double(lower)
        return sortedValues[lower] + (sortedValues[upper] - sortedValues[lower]) * interpolation
    }
}

actor MeasurementLogStore {
    static let fileName = "measurement-log.jsonl"

    enum StoreError: LocalizedError {
        case invalidLog
        case invalidEntry

        var errorDescription: String? {
            switch self {
            case .invalidLog: return BiscuitLocalization.string("The measurement log is invalid. It was left unchanged so it can be recovered.")
            case .invalidEntry: return BiscuitLocalization.string("This measurement could not be safely recorded. No measurement data was written.")
            }
        }
    }

    nonisolated let dataDirectory: URL
    nonisolated let fileURL: URL

    private let decoder: JSONDecoder
    private let encoder: JSONEncoder
    init(dataDirectory: URL? = nil) {
        let root = dataDirectory ?? Self.defaultDataDirectory()
        self.dataDirectory = root
        self.fileURL = root.appendingPathComponent(Self.fileName, isDirectory: false)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        self.decoder = decoder
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
    }

    func entries() throws -> [MeasurementEntry] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        var result: [MeasurementEntry] = []
        var cursor = data.startIndex
        while cursor < data.endIndex {
            let lineEnd = data[cursor...].firstIndex(of: 0x0A) ?? data.endIndex
            if cursor < lineEnd {
                var entry: MeasurementEntry
                do { entry = try decoder.decode(MeasurementEntry.self, from: data[cursor..<lineEnd]) }
                catch { throw StoreError.invalidLog }
                entry.removeUnclassifiedModelIdentifier()
                guard entry.isValid() else { throw StoreError.invalidLog }
                result.append(entry)
            }
            cursor = lineEnd == data.endIndex ? data.endIndex : data.index(after: lineEnd)
        }
        return result
    }

    func append(_ entry: MeasurementEntry) throws {
        guard entry.isValid() else { throw StoreError.invalidEntry }
        let manager = FileManager.default
        try manager.createDirectory(at: dataDirectory, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        if !manager.fileExists(atPath: fileURL.path),
           !manager.createFile(atPath: fileURL.path, contents: Data(), attributes: [.posixPermissions: 0o600]) {
            throw CocoaError(.fileWriteUnknown)
        }
        var data = try encoder.encode(entry)
        data.append(0x0A)
        let file = try FileHandle(forWritingTo: fileURL)
        defer { try? file.close() }
        try file.seekToEnd()
        try file.write(contentsOf: data)
        try file.synchronize()
    }

    func prepareLogFile() throws {
        let manager = FileManager.default
        try manager.createDirectory(at: dataDirectory, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        if !manager.fileExists(atPath: fileURL.path),
           !manager.createFile(atPath: fileURL.path, contents: Data(), attributes: [.posixPermissions: 0o600]) {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private static func defaultDataDirectory() -> URL {
        if let override = ProcessInfo.processInfo.environment["BISCUIT_DATA_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("biscuit", isDirectory: true)
    }
}


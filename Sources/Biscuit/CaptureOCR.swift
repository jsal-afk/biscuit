import Foundation
import Vision
import NaturalLanguage
import CoreGraphics

enum CaptureOCRPreferences {
    static let languageKey = "capture.ocr.language"
    static let autoDetectKey = "capture.ocr.autoDetect"
    static let correctionKey = "capture.ocr.languageCorrection"
    static let supportedLanguages = (try? VNRecognizeTextRequest().supportedRecognitionLanguages()) ?? ["en-US"]
    static let defaultLanguage: String = {
        let preferred = Locale(identifier: Locale.preferredLanguages.first ?? Locale.current.identifier).language.languageCode?.identifier
        return supportedLanguages.first(where: { Locale(identifier: $0).language.languageCode?.identifier == preferred })
            ?? (supportedLanguages.contains("en-US") ? "en-US" : supportedLanguages.first ?? "en-US")
    }()

    static func registerDefaults() {
        BiscuitPreferences.defaults.register(defaults: [
            languageKey: defaultLanguage,
            autoDetectKey: true,
            correctionKey: true
        ])
    }

    static var primaryLanguage: String {
        registerDefaults()
        let stored = BiscuitPreferences.defaults.string(forKey: languageKey) ?? defaultLanguage
        return supportedLanguages.contains(stored) ? stored : defaultLanguage
    }

    static var recognitionLanguages: [String] {
        let primary = primaryLanguage
        if let english = supportedLanguages.first(where: { $0 == "en-US" }) ?? supportedLanguages.first(where: { $0.hasPrefix("en-") }),
           english != primary {
            return [primary, english]
        }
        return [primary]
    }
}

public struct CaptureOCRResult: Sendable {
    public let text: String
    public let detectedLanguage: String?
    public let recognitionMilliseconds: Double
    public let tableMilliseconds: Double
    public let boxCount: Int
    public let characterCount: Int
    public let tableCount: Int
    public let tableRowCount: Int?
    public let tableColumnCount: Int?
    public let tableCellCount: Int?
    public let averageConfidence: Double?
    public let confidenceObservationCount: Int?
    public let recognitionEngine: String
    public let recognitionVariant: String
    public let recognitionLanguages: [String]
    public let languageCorrectionEnabled: Bool
    public let automaticLanguageDetectionEnabled: Bool
}

public enum CaptureOCR {
    private static let wordExpression = try! NSRegularExpression(pattern: "\\S+")
    public static func recognizeText(in imageURL: URL) throws -> String {
        try recognize(in: VNImageRequestHandler(url: imageURL, options: [:])).text
    }

    public static func recognizeText(in imageData: Data) throws -> String {
        try recognize(in: VNImageRequestHandler(data: imageData, options: [:])).text
    }
    public static func recognizeText(in image: CGImage) throws -> String {
        try recognize(in: VNImageRequestHandler(cgImage: image, options: [:])).text
    }


    public static func recognize(in image: CGImage) throws -> CaptureOCRResult {
        try recognize(in: VNImageRequestHandler(cgImage: image, options: [:]))
    }

    public static func recognize(in handler: VNImageRequestHandler) throws -> CaptureOCRResult {
        let textRequest = VNRecognizeTextRequest()
        let recognitionLanguages = CaptureOCRPreferences.recognitionLanguages
        let languageCorrectionEnabled = BiscuitPreferences.defaults.bool(forKey: CaptureOCRPreferences.correctionKey)
        let automaticLanguageDetectionEnabled = BiscuitPreferences.defaults.bool(forKey: CaptureOCRPreferences.autoDetectKey)
        textRequest.recognitionLanguages = recognitionLanguages
        textRequest.usesLanguageCorrection = languageCorrectionEnabled
        textRequest.automaticallyDetectsLanguage = automaticLanguageDetectionEnabled

        let startedAt = ProcessInfo.processInfo.systemUptime
        try handler.perform([textRequest])

        let recognizedLines = (textRequest.results ?? []).compactMap { observation -> (VNRecognizedText, CGRect)? in
            guard let candidate = observation.topCandidates(1).first,
                  !candidate.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return (candidate, observation.boundingBox)
        }
        let boxes = recognizedLines.flatMap { candidate, bounds in cells(from: candidate, lineBox: bounds) }
        let tableStartedAt = ProcessInfo.processInfo.systemUptime
        let formatted = format(boxes)
        let tableMilliseconds = max(0, ProcessInfo.processInfo.systemUptime - tableStartedAt) * 1_000
        let languageRecognizer = NLLanguageRecognizer()
        languageRecognizer.processString(formatted.text)
        let confidenceCount = recognizedLines.count
        let averageConfidence = confidenceCount == 0 ? nil : Double(
            recognizedLines.reduce(0.0) { $0 + Double($1.0.confidence) } / Double(confidenceCount)
        )
        let recognitionMilliseconds = max(0, ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
        return CaptureOCRResult(
            text: formatted.text,
            detectedLanguage: languageRecognizer.dominantLanguage?.rawValue,
            recognitionMilliseconds: recognitionMilliseconds,
            tableMilliseconds: tableMilliseconds,
            boxCount: boxes.count,
            characterCount: formatted.text.count,
            tableCount: formatted.tableCount,
            tableRowCount: formatted.tableRowCount,
            tableColumnCount: formatted.tableColumnCount,
            tableCellCount: formatted.tableCellCount,
            averageConfidence: averageConfidence,
            confidenceObservationCount: confidenceCount == 0 ? nil : confidenceCount,
            recognitionEngine: "vision",
            recognitionVariant: languageCorrectionEnabled ? "accurate" : "accurate-nocorrect",
            recognitionLanguages: recognitionLanguages,
            languageCorrectionEnabled: languageCorrectionEnabled,
            automaticLanguageDetectionEnabled: automaticLanguageDetectionEnabled
        )
    }

    public static func detectLanguage(in imageURL: URL) throws -> String? {
        try recognize(in: VNImageRequestHandler(url: imageURL, options: [:])).detectedLanguage
    }

    private static func cells(from candidate: VNRecognizedText, lineBox: CGRect) -> [OCRBox] {
        let text = candidate.string
        let fullBox = OCRBox(
            text: text,
            rect: CGRect(x: lineBox.minX, y: 1 - lineBox.maxY, width: lineBox.width, height: lineBox.height)
        )
        let matches = wordExpression.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard matches.count > 1 else { return [fullBox] }

        var words: [OCRBox] = []
        for match in matches {
            guard let range = Range(match.range, in: text) else { return [fullBox] }
            let substringBox: VNRectangleObservation?
            do {
                substringBox = try candidate.boundingBox(for: range)
            } catch {
                return [fullBox]
            }
            guard let substringBox else { return [fullBox] }
            let box = substringBox.boundingBox
            words.append(OCRBox(
                text: String(text[range]),
                rect: CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
            ))
        }
        words.sort { $0.rect.minX < $1.rect.minX }

        var cells: [OCRBox] = []
        var cellText = ""
        var cellRect = CGRect.null
        var previousMaxX: CGFloat?
        let columnGap = max(0.008, lineBox.height * 1.2)
        for word in words {
            if let previousMaxX, !cellText.isEmpty, word.rect.minX - previousMaxX > columnGap {
                cells.append(OCRBox(text: cellText, rect: cellRect))
                cellText = word.text
                cellRect = word.rect
            } else {
                if !cellText.isEmpty { cellText += " " }
                cellText += word.text
                cellRect = cellRect.isNull ? word.rect : cellRect.union(word.rect)
            }
            previousMaxX = max(previousMaxX ?? word.rect.maxX, word.rect.maxX)
        }
        if !cellText.isEmpty { cells.append(OCRBox(text: cellText, rect: cellRect)) }
        return cells.isEmpty ? [fullBox] : cells
    }

    private struct OCRBox {
        let text: String
        let rect: CGRect
    }

    private struct OCRRow {
        var boxes: [OCRBox]
        var top: CGFloat
        var bottom: CGFloat
        var maximumHeight: CGFloat { bottom - top }
        var center: CGFloat { (top + bottom) / 2 }
    }

    private struct FormattedOCR {
        let text: String
        let tableCount: Int
        let tableRowCount: Int?
        let tableColumnCount: Int?
        let tableCellCount: Int?
    }

    private static func format(_ boxes: [OCRBox]) -> FormattedOCR {
        guard !boxes.isEmpty else { return FormattedOCR(text: "", tableCount: 0, tableRowCount: nil, tableColumnCount: nil, tableCellCount: nil) }
        var rows: [OCRRow] = []
        for box in boxes.sorted(by: { $0.rect.midY < $1.rect.midY }) {
            let top = box.rect.minY
            let bottom = box.rect.maxY
            let match = rows.indices.min { left, right in
                rowDistance(rows[left], box: box) < rowDistance(rows[right], box: box)
            }
            if let index = match, rowDistance(rows[index], box: box) <= max(box.rect.height, rows[index].maximumHeight) * 0.62 {
                rows[index].boxes.append(box)
                rows[index].top = min(rows[index].top, top)
                rows[index].bottom = max(rows[index].bottom, bottom)
            } else {
                rows.append(OCRRow(boxes: [box], top: top, bottom: bottom))
            }
        }
        rows.sort { $0.center < $1.center }
        for index in rows.indices {
            rows[index].boxes.sort { $0.rect.minX < $1.rect.minX }
        }

        let multiCellCounts = rows.filter { $0.boxes.count > 1 }.reduce(into: [Int: Int]()) { counts, row in
            counts[row.boxes.count, default: 0] += 1
        }
        guard let columnCount = multiCellCounts
            .filter({ $0.key > 1 && $0.value > 1 })
            .max(by: { $0.value == $1.value ? $0.key < $1.key : $0.value < $1.value })?.key else {
            return FormattedOCR(
                text: rows.map { $0.boxes.map(\.text).joined(separator: " ") }.joined(separator: "\n"),
                tableCount: 0, tableRowCount: nil, tableColumnCount: nil, tableCellCount: nil
            )
        }

        let referenceRows = rows.filter { $0.boxes.count == columnCount }
        let columnStarts = (0..<columnCount).map { column in
            median(referenceRows.map { $0.boxes[column].rect.minX })
        }
        let text = rows.map { row in
            var cells = Array(repeating: "", count: columnCount)
            if row.boxes.count == columnCount {
                for (column, box) in row.boxes.enumerated() { cells[column] = box.text }
            } else {
                for box in row.boxes {
                    let column = columnStarts.indices.min(by: {
                        abs(columnStarts[$0] - box.rect.minX) < abs(columnStarts[$1] - box.rect.minX)
                    }) ?? 0
                    if cells[column].isEmpty {
                        cells[column] = box.text
                    } else {
                        cells[column] += " " + box.text
                    }
                }
            }
            return cells.joined(separator: "\t")
        }.joined(separator: "\n")
        return FormattedOCR(
            text: text,
            tableCount: 1,
            tableRowCount: rows.count,
            tableColumnCount: columnCount,
            tableCellCount: rows.count * columnCount
        )
    }

    private static func rowDistance(_ row: OCRRow, box: OCRBox) -> CGFloat {
        let verticalGap = max(0, max(row.top - box.rect.maxY, box.rect.minY - row.bottom))
        let overlap = max(0, min(row.bottom, box.rect.maxY) - max(row.top, box.rect.minY))
        return verticalGap > 0 ? verticalGap : max(0, abs(row.center - box.rect.midY) - overlap * 0.35)
    }

    private static func median(_ values: [CGFloat]) -> CGFloat {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
}


import Foundation

enum InboxBucket: String, Codable, CaseIterable, Identifiable {
    case now, waiting, later, archive
    var id: String { rawValue }
    var title: String { switch self { case .now: "Jetzt"; case .waiting: "Warten"; case .later: "Später"; case .archive: "Ablage" } }
    var subtitle: String { switch self { case .now: "Du bist dran"; case .waiting: "Läuft ohne dich"; case .later: "Noch nicht relevant"; case .archive: "Nur behalten" } }
    var systemImage: String { switch self { case .now: "bolt.fill"; case .waiting: "hourglass"; case .later: "clock.fill"; case .archive: "archivebox.fill" } }
}

enum InboxSourceType: String, Codable {
    case text, url, image, pdf, file
    var label: String { switch self { case .text: "Text"; case .url: "Link"; case .image: "Bild"; case .pdf: "PDF"; case .file: "Datei" } }
    var systemImage: String { switch self { case .text: "text.alignleft"; case .url: "link"; case .image: "photo"; case .pdf: "doc.richtext"; case .file: "doc" } }
}

struct InboxItem: Identifiable, Codable, Hashable {
    var id = UUID()
    var title: String
    var summary: String
    var bucket: InboxBucket
    var createdAt = Date()
    var dueDate: Date?
    var amount: String?
    var sourceType: InboxSourceType
    var originalText: String
    var sourceURL: URL?
    var attachmentRelativePath: String?
    var confidence: Double
    var needsReview: Bool
}

enum SharedInboxStore {
    static let appGroupID = "group.de.knodelt.inbox"
    private static let itemsFile = "inbox-items.json"
    private static let attachmentsFolder = "Attachments"

    static func loadItems() throws -> [InboxItem] {
        let url = try containerURL().appendingPathComponent(itemsFile)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([InboxItem].self, from: Data(contentsOf: url))
    }

    static func saveItems(_ items: [InboxItem]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(items)
        try data.write(to: try containerURL().appendingPathComponent(itemsFile), options: .atomic)
    }

    static func addItem(_ item: InboxItem) throws {
        var items = (try? loadItems()) ?? []
        items.insert(item, at: 0)
        try saveItems(items)
    }

    static func saveAttachment(data: Data, fileExtension: String) throws -> String {
        let directory = try containerURL().appendingPathComponent(attachmentsFolder, isDirectory: true)
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let ext = fileExtension.lowercased().replacingOccurrences(of: ".", with: "").filter { $0.isLetter || $0.isNumber }
        let name = "\(UUID().uuidString).\(ext.isEmpty ? "bin" : ext)"
        try data.write(to: directory.appendingPathComponent(name), options: .atomic)
        return "\(attachmentsFolder)/\(name)"
    }

    static func attachmentURL(for path: String?) -> URL? {
        guard let path, let container = try? containerURL() else { return nil }
        return container.appendingPathComponent(path)
    }

    private static func containerURL() throws -> URL {
        if let shared = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) { return shared }
        let fallback = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("InboxFallback", isDirectory: true)
        if !FileManager.default.fileExists(atPath: fallback.path) {
            try FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
        }
        return fallback
    }
}

enum ContentAnalyzer {
    static func analyze(text raw: String, sourceType: InboxSourceType, sourceURL: URL? = nil, attachmentRelativePath: String? = nil, now: Date = Date()) -> InboxItem {
        let text = raw.replacingOccurrences(of: "\u{00a0}", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        let due = detectDueDate(in: lower, now: now)
        let amount = detectAmount(in: text)
        let waiting = score(lower, ["wir melden uns", "rückmeldung folgt", "wird versendet", "wurde versendet", "unterwegs", "in bearbeitung", "wir prüfen", "wir bearbeiten", "warte auf", "warten auf"])
        let action = score(lower, ["bitte", "fällig", "bezahlen", "überweisen", "antwort", "bestätigen", "rückmeldung", "frist", "bis ", "termin", "rechnung", "angebot", "unterschreiben", "einreichen", "kündigen", "erledigen"]) + (due == nil ? 0 : 2)
        let later = score(lower, ["nächste woche", "naechste woche", "nächsten monat", "später", "wiedervorlage", "erinnern", "nicht vor"])

        let bucket: InboxBucket
        let confidence: Double
        if waiting >= 2 && waiting >= action { bucket = .waiting; confidence = min(0.95, 0.68 + Double(waiting) * 0.06) }
        else if action >= 2 { bucket = .now; confidence = min(0.96, 0.66 + Double(action) * 0.05) }
        else if later >= 1 { bucket = .later; confidence = min(0.90, 0.68 + Double(later) * 0.07) }
        else { bucket = .archive; confidence = text.isEmpty ? 0.45 : 0.70 }

        return InboxItem(
            title: makeTitle(text: text, lower: lower, bucket: bucket, sourceURL: sourceURL),
            summary: makeSummary(text: text, sourceURL: sourceURL),
            bucket: bucket,
            dueDate: due,
            amount: amount,
            sourceType: sourceType,
            originalText: text,
            sourceURL: sourceURL,
            attachmentRelativePath: attachmentRelativePath,
            confidence: confidence,
            needsReview: confidence < 0.72
        )
    }

    private static func score(_ text: String, _ phrases: [String]) -> Int { phrases.reduce(0) { $0 + (text.contains($1) ? 1 : 0) } }

    private static func detectAmount(in text: String) -> String? {
        for pattern in [#"\b\d{1,3}(?:\.\d{3})*,\d{2}\s?€"#, #"\b\d+(?:,\d{2})\s?€"#, #"\bEUR\s?\d{1,3}(?:\.\d{3})*,\d{2}\b"#] {
            if let value = firstMatch(pattern, text) { return value.replacingOccurrences(of: "EUR", with: "").trimmingCharacters(in: .whitespaces) }
        }
        return nil
    }

    private static func detectDueDate(in text: String, now: Date) -> Date? {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: now)
        if text.contains("übermorgen") { return calendar.date(byAdding: .day, value: 2, to: start) }
        if text.contains("morgen") { return calendar.date(byAdding: .day, value: 1, to: start) }
        if text.contains("heute") { return start }

        for pattern in [#"\b([0-3]?\d)\.([01]?\d)\.(20\d{2})\b"#, #"\b([0-3]?\d)\.([01]?\d)\.\b"#] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let match = regex.firstMatch(in: text, range: range), let dr = Range(match.range(at: 1), in: text), let mr = Range(match.range(at: 2), in: text), let day = Int(text[dr]), let month = Int(text[mr]) else { continue }
            var year = calendar.component(.year, from: now)
            let hasYear = match.numberOfRanges > 3 && match.range(at: 3).location != NSNotFound
            if hasYear, let yr = Range(match.range(at: 3), in: text), let parsed = Int(text[yr]) { year = parsed }
            var dc = DateComponents(year: year, month: month, day: day)
            if let date = calendar.date(from: dc) {
                if !hasYear && date < start { dc.year = year + 1; return calendar.date(from: dc) }
                return date
            }
        }

        let weekdays: [([String], Int)] = [(["sonntag"],1),(["montag"],2),(["dienstag"],3),(["mittwoch"],4),(["donnerstag"],5),(["freitag"],6),(["samstag","sonnabend"],7)]
        for (names, weekday) in weekdays where names.contains(where: text.contains) {
            let current = calendar.component(.weekday, from: start)
            var delta = (weekday - current + 7) % 7
            if delta == 0 { delta = 7 }
            return calendar.date(byAdding: .day, value: delta, to: start)
        }
        if text.contains("nächste woche") || text.contains("naechste woche") { return calendar.date(byAdding: .day, value: 7, to: start) }
        return nil
    }

    private static func makeTitle(text: String, lower: String, bucket: InboxBucket, sourceURL: URL?) -> String {
        if lower.contains("rechnung") { return bucket == .waiting ? "Auf Rechnung warten" : "Rechnung prüfen" }
        if lower.contains("angebot") { return bucket == .waiting ? "Auf Angebot warten" : "Angebot prüfen" }
        if lower.contains("termin") { return "Termin klären" }
        if lower.contains("bezahlen") || lower.contains("überweisen") { return "Zahlung erledigen" }
        if lower.contains("antwort") || lower.contains("rückmeldung") { return bucket == .waiting ? "Auf Rückmeldung warten" : "Antworten" }
        if bucket == .waiting { return "Auf Rückmeldung warten" }
        if let line = text.split(whereSeparator: \.isNewline).map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { !$0.isEmpty }) { return String(line.prefix(52)) }
        if let host = sourceURL?.host { return host.replacingOccurrences(of: "www.", with: "") }
        return "Neuer Eingang"
    }

    private static func makeSummary(text: String, sourceURL: URL?) -> String {
        let oneLine = text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\t", with: " ").split(separator: " ").joined(separator: " ")
        return oneLine.isEmpty ? (sourceURL?.absoluteString ?? "Kein Text erkannt.") : String(oneLine.prefix(180))
    }

    private static func firstMatch(_ pattern: String, _ text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range), let r = Range(match.range, in: text) else { return nil }
        return String(text[r])
    }
}

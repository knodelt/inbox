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

enum InboxKind: String, Codable {
    case payment, invoice, reply, appointment, offer, delivery, document, general

    var label: String {
        switch self {
        case .payment: "Zahlung"
        case .invoice: "Rechnung"
        case .reply: "Antwort"
        case .appointment: "Termin"
        case .offer: "Angebot"
        case .delivery: "Lieferung"
        case .document: "Dokument"
        case .general: "Aufgabe"
        }
    }

    var systemImage: String {
        switch self {
        case .payment: "eurosign.circle.fill"
        case .invoice: "doc.text.fill"
        case .reply: "arrowshape.turn.up.left.fill"
        case .appointment: "calendar"
        case .offer: "doc.badge.ellipsis"
        case .delivery: "shippingbox.fill"
        case .document: "doc.fill"
        case .general: "checkmark.circle.fill"
        }
    }
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
    var kind: InboxKind? = nil
    var merchant: String? = nil
    var service: String? = nil
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
        let normalized = normalize(raw)
        let cleaned = cleanOCR(normalized)
        let analysisText = cleaned.isEmpty ? normalized : cleaned
        let lower = analysisText.lowercased()

        let due = detectDueDate(in: lower, now: now)
        let amount = detectAmount(in: analysisText)
        let merchant = detectMerchant(in: analysisText)
        let service = detectService(in: analysisText)
        let kind = detectKind(in: lower)

        let waiting = score(lower, ["wir melden uns", "rückmeldung folgt", "wird versendet", "wurde versendet", "unterwegs", "in bearbeitung", "wir prüfen", "wir bearbeiten", "warte auf", "warten auf", "sobald wir"])
        let action = score(lower, ["bitte", "fällig", "bezahlen", "zahlen", "überweisen", "antwort", "bestätigen", "rückmeldung", "frist", "bis ", "termin", "rechnung", "angebot", "unterschreiben", "einreichen", "kündigen", "erledigen", "zahlung"]) + (due == nil ? 0 : 2) + (amount == nil ? 0 : 1)
        let later = score(lower, ["nächste woche", "naechste woche", "nächsten monat", "später", "wiedervorlage", "erinnern", "nicht vor"])

        let bucket: InboxBucket
        let confidence: Double
        if waiting >= 2 && waiting >= action {
            bucket = .waiting
            confidence = min(0.96, 0.72 + Double(waiting) * 0.05)
        } else if action >= 2 || ([.payment, .invoice, .reply, .appointment, .offer].contains(kind) && due != nil) {
            bucket = .now
            confidence = min(0.97, 0.72 + Double(action) * 0.045)
        } else if later >= 1 {
            bucket = .later
            confidence = min(0.92, 0.72 + Double(later) * 0.06)
        } else {
            bucket = .archive
            confidence = analysisText.isEmpty ? 0.45 : 0.70
        }

        let title = makeTitle(kind: kind, merchant: merchant, bucket: bucket, text: analysisText, sourceURL: sourceURL)
        let summary = makeSummary(kind: kind, merchant: merchant, service: service, amount: amount, due: due, text: analysisText, sourceURL: sourceURL)

        return InboxItem(
            title: title,
            summary: summary,
            bucket: bucket,
            dueDate: due,
            amount: amount,
            sourceType: sourceType,
            originalText: normalized,
            sourceURL: sourceURL,
            attachmentRelativePath: attachmentRelativePath,
            confidence: confidence,
            needsReview: confidence < 0.74,
            kind: kind,
            merchant: merchant,
            service: service
        )
    }

    private static func normalize(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\u{00a0}", with: " ")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func cleanOCR(_ text: String) -> String {
        let noise = Set([
            "posteingang", "entwürfe", "entwuerfe", "gesendet", "papierkorb", "zurück", "zurueck",
            "antworten", "weiterleiten", "mehr", "bearbeiten", "fertig", "abbrechen", "mail", "safari",
            "markieren", "bewegen", "löschen", "loeschen", "archivieren"
        ])

        let kept = text.split(whereSeparator: \.isNewline).compactMap { rawLine -> String? in
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { return nil }
            let lower = line.lowercased()
            if noise.contains(lower) { return nil }
            if firstMatch(#"^\d{1,2}:\d{2}$"#, line) != nil { return nil }
            if firstMatch(#"^\d{1,3}\s?%$"#, line) != nil { return nil }
            if line.count <= 2 && line.allSatisfy({ !$0.isLetter && !$0.isNumber }) { return nil }
            return line
        }
        return kept.joined(separator: "\n")
    }

    private static func detectKind(in text: String) -> InboxKind {
        if text.contains("bezahlen") || text.contains("überweisen") || text.contains("zahlung") || text.contains("zahlbar") || text.contains("bezahle") { return .payment }
        if text.contains("rechnung") { return .invoice }
        if text.contains("antwort") || text.contains("rückmeldung") || text.contains("zurückschreiben") { return .reply }
        if text.contains("termin") || text.contains("reservierung") { return .appointment }
        if text.contains("angebot") { return .offer }
        if text.contains("versendet") || text.contains("lieferung") || text.contains("paket") || text.contains("unterwegs") { return .delivery }
        if text.contains("dokument") || text.contains("bescheinigung") || text.contains("vertrag") { return .document }
        return .general
    }

    private static func detectService(in text: String) -> String? {
        let known = ["Klarna", "PayPal", "Amazon", "DHL", "UPS", "DPD", "Hermes"]
        return known.first { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    private static func detectMerchant(in text: String) -> String? {
        let patterns = [
            #"(?i)bestellung\s+bei\s+([^\n]{2,60})"#,
            #"(?i)(?:rechnung|angebot|zahlung)\s+(?:von|bei|an|für|fuer)\s+([^\n]{2,60})"#,
            #"(?i)(?:händler|haendler|anbieter):?\s+([^\n]{2,60})"#,
            #"(?i)(?:zahlung|rechnung|bestellung)[^\n]{0,30}?(?:für|fuer|bei|von|an)\s+([^\n]{2,60})"#,
            #"(?i)(?:bezahlen|bezahle|überweisen|ueberweisen)\s+(?:an|bei|für|fuer)?\s*([^\n]{2,60})"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1,
                  let r = Range(match.range(at: 1), in: text) else { continue }
            let rawCandidate = String(text[r])
            if let candidate = sanitizeMerchantCandidate(rawCandidate), !isLikelyService(candidate) {
                return candidate
            }
        }

        return detectMerchantFromLines(in: text)
    }

    private static func sanitizeMerchantCandidate(_ raw: String) -> String? {
        var value = raw
            .trimmingCharacters(in: CharacterSet(charactersIn: " .,:;–—-•"))
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)

        let stopPattern = #"(?i)\s+(?:steht|ist|sind|wird|werden|muss|musst|soll|sollst|kann|kannst|hat|haben|fällig|faellig|bezahlen|zahlen|überweisen|ueberweisen|bis|am|zum|heute|morgen|jetzt|noch|bereits|offen|ausstehend)\b.*$"#
        value = value.replacingOccurrences(of: stopPattern, with: "", options: .regularExpression)
        value = value.components(separatedBy: CharacterSet(charactersIn: ".,;:!?|•")).first ?? value
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: " .,:;–—-•"))

        let words = value.split(separator: " ")
        guard !words.isEmpty, words.count <= 6, value.count >= 2, value.count <= 42 else { return nil }

        let bad = ["deine", "dein", "ihre", "ihr", "zahlung", "rechnung", "bestellung", "betrag", "euro", "fällig", "faellig"]
        let lower = value.lowercased()
        if bad.contains(lower) { return nil }
        if value.allSatisfy({ $0.isNumber || $0.isWhitespace || ",.€".contains($0) }) { return nil }

        return value
    }

    private static func detectMerchantFromLines(in text: String) -> String? {
        let lines = text.split(whereSeparator: \.isNewline).map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        for line in lines {
            guard line.count >= 2, line.count <= 36 else { continue }
            let lower = line.lowercased()
            if detectAmount(in: line) != nil { continue }
            if detectService(in: line) != nil { continue }
            if ["zahlung", "rechnung", "bestellung", "fällig", "faellig", "bezahlen", "klarna"].contains(where: lower.contains) { continue }
            if firstMatch(#"^\d"#, line) != nil { continue }
            let letters = line.filter(\.isLetter)
            guard letters.count >= 3 else { continue }
            if let first = letters.first, first.isUppercase {
                return sanitizeMerchantCandidate(line)
            }
        }
        return nil
    }

    private static func isLikelyService(_ value: String) -> Bool {
        ["klarna", "paypal", "amazon", "dhl", "ups", "dpd", "hermes"].contains(value.lowercased())
    }

    private static func score(_ text: String, _ phrases: [String]) -> Int {
        phrases.reduce(0) { $0 + (text.contains($1) ? 1 : 0) }
    }

    private static func detectAmount(in text: String) -> String? {
        let patterns = [
            #"\b\d{1,3}(?:\.\d{3})*,\d{2}\s?€"#,
            #"\b\d+(?:,\d{2})\s?€"#,
            #"\bEUR\s?\d{1,3}(?:\.\d{3})*,\d{2}\b"#,
            #"\b\d{1,3}(?:\.\d{3})*,\d{2}\s?EUR\b"#
        ]
        for pattern in patterns {
            if let value = firstMatch(pattern, text) {
                return value.replacingOccurrences(of: "EUR", with: "", options: .caseInsensitive).trimmingCharacters(in: .whitespaces)
            }
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
            guard let match = regex.firstMatch(in: text, range: range),
                  let dr = Range(match.range(at: 1), in: text),
                  let mr = Range(match.range(at: 2), in: text),
                  let day = Int(text[dr]), let month = Int(text[mr]) else { continue }
            var year = calendar.component(.year, from: now)
            let hasYear = match.numberOfRanges > 3 && match.range(at: 3).location != NSNotFound
            if hasYear, let yr = Range(match.range(at: 3), in: text), let parsed = Int(text[yr]) { year = parsed }
            var dc = DateComponents(year: year, month: month, day: day)
            if let date = calendar.date(from: dc) {
                if !hasYear && date < start { dc.year = year + 1; return calendar.date(from: dc) }
                return date
            }
        }

        let monthMap: [String: Int] = [
            "januar": 1, "februar": 2, "märz": 3, "maerz": 3, "april": 4, "mai": 5, "juni": 6,
            "juli": 7, "august": 8, "september": 9, "oktober": 10, "november": 11, "dezember": 12
        ]
        let monthNames = monthMap.keys.sorted { $0.count > $1.count }.joined(separator: "|")
        let monthPattern = #"\b([0-3]?\d)\.?\s+("# + monthNames + #")\s*(20\d{2})?\b"#
        if let regex = try? NSRegularExpression(pattern: monthPattern, options: [.caseInsensitive]) {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            if let match = regex.firstMatch(in: text, range: range),
               let dr = Range(match.range(at: 1), in: text),
               let mr = Range(match.range(at: 2), in: text),
               let day = Int(text[dr]) {
                let monthName = String(text[mr]).lowercased()
                if let month = monthMap[monthName] {
                    var year = calendar.component(.year, from: now)
                    let hasYear = match.numberOfRanges > 3 && match.range(at: 3).location != NSNotFound
                    if hasYear, let yr = Range(match.range(at: 3), in: text), let parsed = Int(text[yr]) { year = parsed }
                    var dc = DateComponents(year: year, month: month, day: day)
                    if let date = calendar.date(from: dc) {
                        if !hasYear && date < start { dc.year = year + 1; return calendar.date(from: dc) }
                        return date
                    }
                }
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

    private static func makeTitle(kind: InboxKind, merchant: String?, bucket: InboxBucket, text: String, sourceURL: URL?) -> String {
        let name = merchant?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .payment:
            return name.map { "\($0) bezahlen" } ?? "Zahlung erledigen"
        case .invoice:
            return name.map { "Rechnung von \($0) prüfen" } ?? "Rechnung prüfen"
        case .reply:
            return bucket == .waiting ? "Auf Rückmeldung warten" : (name.map { "\($0) antworten" } ?? "Antworten")
        case .appointment:
            return name.map { "Termin mit \($0)" } ?? "Termin klären"
        case .offer:
            return name.map { "Angebot von \($0) prüfen" } ?? "Angebot prüfen"
        case .delivery:
            return name.map { "Lieferung von \($0)" } ?? "Lieferung verfolgen"
        case .document:
            return name.map { "Dokument von \($0)" } ?? "Dokument ablegen"
        case .general:
            if bucket == .waiting { return "Auf Rückmeldung warten" }
            if let line = bestContentLine(in: text) { return String(line.prefix(52)) }
            if let host = sourceURL?.host { return host.replacingOccurrences(of: "www.", with: "") }
            return "Neuer Eingang"
        }
    }

    private static func makeSummary(kind: InboxKind, merchant: String?, service: String?, amount: String?, due: Date?, text: String, sourceURL: URL?) -> String {
        var parts: [String] = []
        if let service { parts.append(service) }
        if let amount { parts.append(amount) }
        if let due { parts.append("fällig \(due.formatted(.dateTime.day().month(.abbreviated)))") }

        if !parts.isEmpty { return parts.joined(separator: " · ") }
        if let merchant { return merchant }
        if let line = bestContentLine(in: text) { return String(line.prefix(150)) }
        return sourceURL?.absoluteString ?? "Automatisch erkannt"
    }

    private static func bestContentLine(in text: String) -> String? {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let ranked = lines.map { line -> (String, Int) in
            let lower = line.lowercased()
            var value = 0
            if lower.contains("fällig") || lower.contains("faellig") || lower.contains("bis ") { value += 4 }
            if lower.contains("bezahlen") || lower.contains("rechnung") || lower.contains("angebot") || lower.contains("antwort") { value += 4 }
            if detectAmount(in: line) != nil { value += 3 }
            if line.count > 12 { value += 1 }
            return (line, value)
        }
        return ranked.max { $0.1 < $1.1 }?.0
    }

    private static func firstMatch(_ pattern: String, _ text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range), let r = Range(match.range, in: text) else { return nil }
        return String(text[r])
    }
}

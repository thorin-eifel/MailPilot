import Foundation

/// Aus einer E-Mail (und ihrem PDF-Anhang) ausgelesene Rechnung.
struct Invoice: Identifiable, Hashable {
    var messageId: String
    var threadKey: String?
    var account: String
    var sender: String
    var senderEmail: String
    var subject: String
    var mailDate: Date
    var vendor: String
    var number: String?
    var amount: Double?
    var vat: Double?
    var currency: String
    var issueDate: String?
    var dueDate: String?
    var description: String
    /// "pdf" = aus dem Anhang gelesen, "mail" = nur aus dem Mailtext.
    var source: String
    var fileName: String?
    var paid: Bool
    /// "ok", "not_invoice" (keine Rechnung) oder "failed" (Auslesen fehlgeschlagen).
    var status: String
    var error: String?

    var id: String { messageId }

    var isOpen: Bool { status == "ok" && !paid }

    func isOverdue(today: Date = Date()) -> Bool {
        guard isOpen, let due = Deadlines.parse(dueDate) else { return false }
        return due < Calendar.current.startOfDay(for: today)
    }

    func isDue(within days: Int, today: Date = Date()) -> Bool {
        guard isOpen, let due = Deadlines.parse(dueDate) else { return false }
        let start = Calendar.current.startOfDay(for: today)
        return due >= start && due <= start.addingTimeInterval(Double(days) * 86400)
    }
}

/// Ergebnis der Claude-Auslesung.
struct InvoiceExtraction: Decodable {
    var is_invoice: Bool
    var vendor: String?
    var invoice_number: String?
    var amount_gross: Double?
    var vat_amount: Double?
    var currency: String?
    var issue_date: String?
    var due_date: String?
    var description: String?
    var already_paid: Bool?
}

enum Money {
    static func format(_ value: Double, currency: String) -> String {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.numberStyle = .currency
        f.currencyCode = currency.isEmpty ? "EUR" : currency
        return f.string(from: NSNumber(value: value)) ?? String(format: "%.2f %@", value, currency)
    }

    /// Beträge je Währung, z. B. „1.234,50 € · 200,00 CHF“.
    static func summary(_ totals: [String: Double]) -> String {
        guard !totals.isEmpty else { return "0,00 €" }
        return totals.sorted { $0.key == "EUR" ? true : ($1.key == "EUR" ? false : $0.key < $1.key) }
            .map { format($0.value, currency: $0.key) }.joined(separator: " · ")
    }

    static func totals(_ list: [Invoice]) -> [String: Double] {
        var t: [String: Double] = [:]
        for i in list { if let a = i.amount { t[i.currency.isEmpty ? "EUR" : i.currency, default: 0] += a } }
        return t
    }

    /// „1.234,50“, „1234,5“, „1,234.50“ → 1234.5 (für das Bearbeiten-Formular).
    static func parse(_ text: String) -> Double? {
        var s = text.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "€", with: "").replacingOccurrences(of: " ", with: "")
        guard !s.isEmpty else { return nil }
        let lastComma = s.lastIndex(of: ","), lastDot = s.lastIndex(of: ".")
        if let c = lastComma, let d = lastDot {
            // Das zuletzt stehende Zeichen ist das Dezimaltrennzeichen.
            if c > d { s = s.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".") }
            else { s = s.replacingOccurrences(of: ",", with: "") }
        } else if lastComma != nil {
            s = s.replacingOccurrences(of: ",", with: ".")
        }
        return Double(s)
    }
}

/// CSV für die Buchhaltung: Semikolon, Dezimalkomma, deutsches Datum, UTF-8 mit BOM (öffnet sich in Excel korrekt).
enum InvoiceCSV {
    static let header = ["Rechnungsdatum", "Fälligkeit", "Aussteller", "Rechnungsnummer", "Betrag brutto", "davon USt", "Währung",
                         "Status", "Beschreibung", "Absender", "Betreff", "Konto", "Mail-Datum", "Quelle", "Datei"]

    private static func germanDate(_ iso: String?) -> String {
        guard let d = Deadlines.parse(iso) else { return "" }
        let f = DateFormatter()
        f.dateFormat = "dd.MM.yyyy"
        return f.string(from: d)
    }

    private static func number(_ v: Double?) -> String {
        guard let v else { return "" }
        return String(format: "%.2f", v).replacingOccurrences(of: ".", with: ",")
    }

    /// Maskiert Trennzeichen und verhindert Formel-Einschleusung durch Absender (=, +, -, @ am Zellanfang).
    static func text(_ s: String) -> String {
        var v = s.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
        if let first = v.first, "=+-@\t".contains(first) { v = "'" + v }
        if v.contains(";") || v.contains("\"") { v = "\"" + v.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        return v
    }

    static func make(_ list: [Invoice]) -> String {
        let f = DateFormatter()
        f.dateFormat = "dd.MM.yyyy"
        var lines = [header.joined(separator: ";")]
        for i in list {
            lines.append([
                germanDate(i.issueDate), germanDate(i.dueDate), text(i.vendor), text(i.number ?? ""), number(i.amount), number(i.vat),
                text(i.currency), i.paid ? "bezahlt" : "offen", text(i.description), text(i.senderEmail), text(i.subject),
                text(i.account), f.string(from: i.mailDate), i.source == "pdf" ? "PDF-Anhang" : "Mailtext", text(i.fileName ?? ""),
            ].joined(separator: ";"))
        }
        return "\u{FEFF}" + lines.joined(separator: "\r\n") + "\r\n"
    }
}

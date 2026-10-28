import Foundation

enum ThreadStatus: String, Codable, CaseIterable, Identifiable {
    case needsReply = "antwort_noetig"
    case waiting = "wartet_auf_andere"
    case info = "info"
    case done = "erledigt"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .needsReply: "Antwort nötig"
        case .waiting: "Wartet auf Antwort"
        case .info: "Zur Info"
        case .done: "Erledigt"
        }
    }

    var symbol: String {
        switch self {
        case .needsReply: "arrowshape.turn.up.left.fill"
        case .waiting: "hourglass"
        case .info: "info.circle"
        case .done: "checkmark.circle.fill"
        }
    }
}

enum Priority: String, Codable, CaseIterable, Identifiable {
    case high = "hoch"
    case normal = "normal"
    case low = "niedrig"

    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

/// Mail-Flaggenfarben in der Reihenfolge von Apple Mails `flag index`.
enum FlagColor: Int, Codable, CaseIterable, Identifiable {
    case red = 0, orange, yellow, green, blue, purple, gray

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .red: "Rot"
        case .orange: "Orange"
        case .yellow: "Gelb"
        case .green: "Grün"
        case .blue: "Blau"
        case .purple: "Lila"
        case .gray: "Grau"
        }
    }
}

/// Nachricht, wie sie das JXA-Skript aus Apple Mail liefert.
struct RawMessage: Decodable {
    var id: Int
    var messageId: String
    var account: String
    var mailbox: String
    var subject: String
    var sender: String
    var date: String
    var read: Bool?
    var inReplyTo: String?
    var references: [String]
    var to: [String]
    var cc: [String]
    var content: String
    var isSent: Bool
}

struct MailAccountInfo: Decodable, Identifiable, Hashable {
    var name: String
    var emails: [String]
    var inboxCount: Int
    var id: String { name }
}

struct StoredMessage: Identifiable, Hashable {
    var messageId: String
    var mailId: Int
    var account: String
    var mailbox: String
    var subject: String
    var sender: String
    var senderEmail: String
    var recipients: [String]
    var date: Date
    var isFromMe: Bool
    var inReplyTo: String?
    var references: [String]
    var content: String
    var threadKey: String?
    var category: String?
    var priority: Priority?
    var summary: String?
    var processed: Bool
    var error: String?

    var id: String { messageId }

    var senderName: String {
        MailAddress.parse(sender).name ?? senderEmail
    }

    /// Öffnet die Nachricht über das `message:`-URL-Schema direkt in Apple Mail.
    var mailURL: URL? {
        let encoded = "<\(messageId)>".addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        return URL(string: "message://\(encoded)")
    }
}

struct MailThread: Identifiable, Hashable {
    var threadKey: String
    var subject: String
    var normSubject: String
    var counterpart: String
    var lastDate: Date
    var lastFromMe: Bool
    var messageCount: Int
    var status: ThreadStatus
    var summary: String
    var nextStep: String
    var dueDate: String?
    var priority: Priority
    var category: String?
    var draft: String?
    var draftFor: String?
    var followupNotified: Bool

    var id: String { threadKey }

    func isOverdue(followUpDays: Int) -> Bool {
        status == .waiting && lastDate < Date().addingTimeInterval(-Double(followUpDays) * 86400)
    }
}

struct ActivityEntry: Identifiable, Hashable {
    var id: Int64
    var date: Date
    var messageId: String
    var subject: String
    var kind: String
    var detail: String
    var account: String
    var fromMailbox: String?
    var toMailbox: String?
    var dryRun: Bool
    var undone: Bool

    var canUndo: Bool { kind == "move" && !dryRun && !undone && fromMailbox != nil && toMailbox != nil }
}

struct Briefing: Hashable {
    var date: Date
    var text: String
}

enum MailAddress {
    /// Zerlegt `"Name" <mail@example.com>` in Name und Adresse.
    static func parse(_ raw: String) -> (name: String?, email: String) {
        if let lt = raw.lastIndex(of: "<"), let gt = raw.lastIndex(of: ">"), lt < gt {
            let email = String(raw[raw.index(after: lt)..<gt]).trimmingCharacters(in: .whitespaces).lowercased()
            let name = raw[..<lt].trimmingCharacters(in: CharacterSet(charactersIn: " \""))
            return (name.isEmpty ? nil : name, email)
        }
        return (nil, raw.trimmingCharacters(in: .whitespaces).lowercased())
    }

    /// Entfernt Re:/AW:/Fwd:/WG:-Präfixe für den Betreffvergleich.
    static func normalizeSubject(_ subject: String) -> String {
        var s = subject.trimmingCharacters(in: .whitespaces)
        let pattern = #"^\s*((re|aw|fw|fwd|wg|antw|sv|vs)\s*(\[\d+\])?\s*:\s*)+"#
        if let r = s.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
            s.removeSubrange(r)
        }
        return s.trimmingCharacters(in: .whitespaces).lowercased()
    }
}

extension Date {
    static func fromISO(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    var isoString: String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: self)
    }
}

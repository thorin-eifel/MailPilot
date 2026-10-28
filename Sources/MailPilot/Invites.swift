import Foundation

/// Ein Termin aus einer Einladung (iCalendar-Anhang).
struct InviteEvent: Hashable {
    var uid: String
    var summary: String
    var start: Date
    var end: Date
    var allDay: Bool
    var location: String
    var organizer: String
    var method: String
    var cancelled: Bool
    var recurring: Bool
    var notes: String
}

enum ICSParser {
    /// Windows-Zeitzonennamen, wie sie Outlook/Exchange schreibt, auf IANA-Namen.
    static let windowsZones: [String: String] = [
        "W. Europe Standard Time": "Europe/Berlin", "Central Europe Standard Time": "Europe/Budapest", "Central European Standard Time": "Europe/Warsaw",
        "Romance Standard Time": "Europe/Paris", "GMT Standard Time": "Europe/London", "E. Europe Standard Time": "Europe/Chisinau",
        "GTB Standard Time": "Europe/Bucharest", "FLE Standard Time": "Europe/Kiev", "Russian Standard Time": "Europe/Moscow", "Turkey Standard Time": "Europe/Istanbul",
        "UTC": "UTC", "Eastern Standard Time": "America/New_York", "Central Standard Time": "America/Chicago", "Mountain Standard Time": "America/Denver",
        "Pacific Standard Time": "America/Los_Angeles", "India Standard Time": "Asia/Kolkata", "China Standard Time": "Asia/Shanghai",
        "Tokyo Standard Time": "Asia/Tokyo", "AUS Eastern Standard Time": "Australia/Sydney",
    ]

    static func timeZone(_ id: String?) -> TimeZone {
        guard let id, !id.isEmpty else { return .current }
        let cleaned = id.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        return TimeZone(identifier: cleaned) ?? windowsZones[cleaned].flatMap { TimeZone(identifier: $0) } ?? .current
    }

    private struct Prop {
        var name: String
        var params: [String: String]
        var value: String
    }

    private static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\N", with: "\n").replacingOccurrences(of: "\\,", with: ",")
            .replacingOccurrences(of: "\\;", with: ";").replacingOccurrences(of: "\\\\", with: "\\")
    }

    private static func parseLine(_ line: String) -> Prop? {
        // Doppelpunkt außerhalb von Anführungszeichen trennt Name/Parameter vom Wert.
        var inQuote = false
        var split: String.Index?
        for i in line.indices {
            if line[i] == "\"" { inQuote.toggle() }
            else if line[i] == ":", !inQuote { split = i; break }
        }
        guard let split else { return nil }
        let head = line[..<split].split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        guard let name = head.first?.uppercased(), !name.isEmpty else { return nil }
        var params: [String: String] = [:]
        for p in head.dropFirst() {
            let kv = p.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 { params[kv[0].uppercased()] = kv[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
        }
        return Prop(name: name, params: params, value: String(line[line.index(after: split)...]))
    }

    /// „20261104T093000Z“, „20261104T093000“ (mit TZID) oder „20261104“ (ganztägig).
    static func parseDate(_ value: String, params: [String: String]) -> (date: Date, allDay: Bool)? {
        let v = value.trimmingCharacters(in: .whitespaces)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        if params["VALUE"] == "DATE" || v.count == 8 {
            f.timeZone = .current
            f.dateFormat = "yyyyMMdd"
            return f.date(from: v).map { ($0, true) }
        }
        let utc = v.hasSuffix("Z")
        f.timeZone = utc ? TimeZone(identifier: "UTC") : timeZone(params["TZID"])
        f.dateFormat = "yyyyMMdd'T'HHmmss"
        return f.date(from: utc ? String(v.dropLast()) : v).map { ($0, false) }
    }

    /// „PT1H30M“, „P1D“, „PT45M“ in Sekunden.
    static func parseDuration(_ v: String) -> TimeInterval? {
        guard v.hasPrefix("P") || v.hasPrefix("-P") else { return nil }
        var total = 0.0, number = "", inTime = false
        for ch in v.dropFirst(v.hasPrefix("-") ? 2 : 1) {
            if ch == "T" { inTime = true; continue }
            if ch.isNumber { number.append(ch); continue }
            let n = Double(number) ?? 0
            number = ""
            switch ch {
            case "W": total += n * 7 * 86400
            case "D": total += n * 86400
            case "H": total += n * 3600
            case "M": total += inTime ? n * 60 : 0
            case "S": total += n
            default: break
            }
        }
        return total
    }

    static func parse(_ text: String) -> [InviteEvent] {
        let unfolded = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n ", with: "").replacingOccurrences(of: "\n\t", with: "")
        var events: [InviteEvent] = []
        var method = ""
        var props: [Prop]?
        for raw in unfolded.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.uppercased() == "BEGIN:VEVENT" { props = []; continue }
            if line.uppercased() == "END:VEVENT" {
                if let p = props, let e = build(p, method: method) { events.append(e) }
                props = nil
                continue
            }
            guard let prop = parseLine(line) else { continue }
            if props != nil { props?.append(prop) } else if prop.name == "METHOD" { method = prop.value.uppercased() }
        }
        return events
    }

    private static func build(_ props: [Prop], method: String) -> InviteEvent? {
        func first(_ n: String) -> Prop? { props.first { $0.name == n } }
        guard let startProp = first("DTSTART"), let s = parseDate(startProp.value, params: startProp.params) else { return nil }
        var end: Date
        if let e = first("DTEND"), let d = parseDate(e.value, params: e.params) { end = d.date }
        else if let d = first("DURATION"), let secs = parseDuration(d.value) { end = s.date.addingTimeInterval(secs) }
        else { end = s.date.addingTimeInterval(s.allDay ? 86400 : 3600) }
        if end <= s.date { end = s.date.addingTimeInterval(s.allDay ? 86400 : 3600) }
        var uid = first("UID")?.value ?? UUID().uuidString
        if let r = first("RECURRENCE-ID") { uid += "#" + r.value }
        let org = first("ORGANIZER")
        let organizer = org?.params["CN"].map(unescape) ?? org?.value.replacingOccurrences(of: "mailto:", with: "", options: .caseInsensitive) ?? ""
        let status = (first("STATUS")?.value ?? "").uppercased()
        return InviteEvent(uid: uid, summary: unescape(first("SUMMARY")?.value ?? "(ohne Titel)"), start: s.date, end: end, allDay: s.allDay,
                           location: unescape(first("LOCATION")?.value ?? ""), organizer: organizer, method: method,
                           cancelled: status == "CANCELLED" || method == "CANCEL", recurring: first("RRULE") != nil,
                           notes: unescape(first("DESCRIPTION")?.value ?? ""))
    }
}

enum InviteScan {
    /// Betreffs, die auf eine Einladung hindeuten (Teilstrings, kleingeschrieben).
    static let subjectWords = ["einladung", "invitation", "invite", "termin", "meeting", "besprechung", "zugesagt", "angenommen", "abgelehnt", "aktualisiert",
                               "updated", "accepted", "declined", "canceled", "cancelled", "abgesagt", "webinar", "calendar"]
}

struct Invite: Identifiable, Hashable {
    var messageId: String
    var event: InviteEvent
    var account: String
    var subject: String
    var status: String
    var mailDate: Date

    var id: String { event.uid }
}

extension Store {
    func inviteCandidates(accounts: [String], since: Date, limit: Int) throws -> [StoredMessage] {
        let like = InviteScan.subjectWords.map { _ in "LOWER(subject) LIKE ?" }.joined(separator: " OR ")
        return try db.query("""
            SELECT * FROM messages WHERE is_from_me = 0 AND is_private = 0 AND processed = 1 AND date >= ? AND account IN \(inList(accounts))
            AND message_id NOT IN (SELECT message_id FROM invite_scan) AND (\(like) OR category = 'Termine') ORDER BY date DESC LIMIT ?
            """, [since] + accounts + InviteScan.subjectWords.map { "%\($0)%" } + [limit]).map(message)
    }

    func markInviteScanned(_ messageId: String) throws {
        try db.exec("INSERT OR IGNORE INTO invite_scan (message_id, ts) VALUES (?, ?)", [messageId, Date()])
    }

    /// Speichert einen Termin. Ändert sich Zeit oder Absage eines schon bekannten Termins, wird er wieder „neu“.
    func saveInvite(_ e: InviteEvent, messageId: String, account: String, subject: String, mailDate: Date) throws {
        let old = try db.query("SELECT start, end, cancelled, status FROM invites WHERE uid = ?", [e.uid]).first
        var status = "new"
        if let old {
            let same = abs(old.double("start") - e.start.timeIntervalSince1970) < 1 && abs(old.double("end") - e.end.timeIntervalSince1970) < 1 && old.bool("cancelled") == e.cancelled
            status = same ? (old.string("status") ?? "new") : "new"
        }
        try db.exec("""
            INSERT OR REPLACE INTO invites (uid, message_id, summary, start, end, all_day, location, organizer, method, status, recurring, cancelled, account, subject, mail_date, notes)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [e.uid, messageId, e.summary, e.start, e.end, e.allDay, e.location, e.organizer, e.method, status, e.recurring, e.cancelled, account, subject, mailDate, e.notes])
    }

    func invites(accounts: [String], limit: Int = 300) throws -> [Invite] {
        try db.query("SELECT * FROM invites WHERE account IN \(inList(accounts)) ORDER BY start ASC LIMIT ?", accounts + [limit]).map { r in
            Invite(messageId: r.string("message_id") ?? "",
                   event: InviteEvent(uid: r.string("uid") ?? "", summary: r.string("summary") ?? "", start: r.date("start"), end: r.date("end"), allDay: r.bool("all_day"),
                                      location: r.string("location") ?? "", organizer: r.string("organizer") ?? "", method: r.string("method") ?? "",
                                      cancelled: r.bool("cancelled"), recurring: r.bool("recurring"), notes: r.string("notes") ?? ""),
                   account: r.string("account") ?? "", subject: r.string("subject") ?? "", status: r.string("status") ?? "new", mailDate: r.date("mail_date"))
        }
    }

    func setInviteStatus(_ uid: String, _ status: String) throws {
        try db.exec("UPDATE invites SET status = ? WHERE uid = ?", [status, uid])
    }
}

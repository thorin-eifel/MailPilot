import Foundation

/// Termin und Erinnerung als einfache Werte (ohne EventKit – daher testbar).
struct PlannerEvent: Identifiable, Hashable {
    var eventID: String
    var calendarID: String
    var calendarTitle: String
    var colorHex: UInt32
    var title: String
    var start: Date
    var end: Date
    var allDay: Bool
    var location: String
    var url: URL?

    /// Wiederkehrende Termine teilen sich die Kennung; der Beginn macht jedes Vorkommen eindeutig.
    var id: String { "\(eventID)|\(Int(start.timeIntervalSince1970))" }
}

struct PlannerReminder: Identifiable, Hashable {
    var id: String
    var listID: String
    var listTitle: String
    var colorHex: UInt32
    var title: String
    var notes: String
    var due: Date?
    var hasTime: Bool
    var completed: Bool
    var priority: Int
    var url: URL?
}

enum ReminderGroup: Int, CaseIterable, Identifiable {
    case overdue, today, upcoming, noDate, done
    var id: Int { rawValue }

    var label: String {
        switch self {
        case .overdue: "Überfällig"
        case .today: "Heute"
        case .upcoming: "Demnächst"
        case .noDate: "Ohne Datum"
        case .done: "Erledigt"
        }
    }
}

/// Auswahl und Gruppierung (rein).
enum PlannerLogic {
    /// Erster Tag der Woche, in der `date` liegt (nach Region: in Deutschland Montag).
    static func weekStart(of date: Date, calendar: Calendar = .current) -> Date {
        calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
    }

    static func monthStart(of date: Date, calendar: Calendar = .current) -> Date {
        calendar.dateInterval(of: .month, for: date)?.start ?? calendar.startOfDay(for: date)
    }

    /// Alle Tage von `start` an – Kalendertage, keine 24-Stunden-Schritte (Zeitumstellung).
    static func days(from start: Date, count: Int, calendar: Calendar = .current) -> [Date] {
        let first = calendar.startOfDay(for: start)
        return (0..<count).compactMap { calendar.date(byAdding: .day, value: $0, to: first) }
    }

    /// Das Raster eines Monats: ganze Wochen, die den Monat umschließen.
    static func monthGrid(for date: Date, calendar: Calendar = .current) -> [Date] {
        guard let interval = calendar.dateInterval(of: .month, for: date) else { return [] }
        let first = weekStart(of: interval.start, calendar: calendar)
        let lastDay = calendar.date(byAdding: .second, value: -1, to: interval.end) ?? interval.end
        let lastWeek = weekStart(of: lastDay, calendar: calendar)
        let weeks = (calendar.dateComponents([.weekOfYear], from: first, to: lastWeek).weekOfYear ?? 0) + 1
        return days(from: first, count: max(weeks, 1) * 7, calendar: calendar)
    }

    /// Termine eines Tages: mehrtägige erscheinen an jedem Tag; ganztägige zuerst, dann nach Beginn.
    static func events(on day: Date, in all: [PlannerEvent], calendar: Calendar = .current) -> [PlannerEvent] {
        let start = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return [] }
        return all.filter { $0.start < end && max($0.end, $0.start.addingTimeInterval(1)) > start }
            .sorted { a, b in
                if a.allDay != b.allDay { return a.allDay }
                return (a.start, a.title) < (b.start, b.title)
            }
    }

    static func group(_ r: PlannerReminder, now: Date = Date(), calendar: Calendar = .current) -> ReminderGroup {
        if r.completed { return .done }
        guard let due = r.due else { return .noDate }
        if r.hasTime { if due < now { return .overdue } }
        else if calendar.startOfDay(for: due) < calendar.startOfDay(for: now) { return .overdue }
        return calendar.isDate(due, inSameDayAs: now) ? .today : .upcoming
    }

    /// Erinnerungen je Gruppe, nach Fälligkeit sortiert (Erledigte: zuletzt erledigte zuerst ist hier nicht bekannt, daher nach Titel).
    static func grouped(_ reminders: [PlannerReminder], showDone: Bool, now: Date = Date(), calendar: Calendar = .current) -> [(ReminderGroup, [PlannerReminder])] {
        var buckets: [ReminderGroup: [PlannerReminder]] = [:]
        for r in reminders { buckets[group(r, now: now, calendar: calendar), default: []].append(r) }
        return ReminderGroup.allCases.compactMap { g in
            guard showDone || g != .done, var list = buckets[g], !list.isEmpty else { return nil }
            list.sort { a, b in
                if let x = a.due, let y = b.due, x != y { return x < y }
                if (a.due == nil) != (b.due == nil) { return a.due != nil }
                return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
            }
            return (g, list)
        }
    }

    static func overdueCount(_ reminders: [PlannerReminder], now: Date = Date(), calendar: Calendar = .current) -> Int {
        reminders.filter { group($0, now: now, calendar: calendar) == .overdue }.count
    }

    /// „Mo., 3. Nov., 14:00“ bzw. ohne Uhrzeit.
    static func dueText(_ r: PlannerReminder, now: Date = Date(), calendar: Calendar = .current, locale: Locale = Locale(identifier: "de_DE")) -> String {
        guard let due = r.due else { return "" }
        let f = DateFormatter()
        f.locale = locale
        f.calendar = calendar
        let day: String
        if calendar.isDate(due, inSameDayAs: now) { day = "Heute" }
        else if let t = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(due, inSameDayAs: t) { day = "Morgen" }
        else { f.dateFormat = "EEE, d. MMM"; day = f.string(from: due) }
        guard r.hasTime else { return day }
        f.dateFormat = "HH:mm"
        return "\(day), \(f.string(from: due))"
    }
}

/// Schnelleingabe: „Steuerberater anrufen morgen 14 Uhr“, „Miete überweisen am 3.11.“, „Bericht in 2 Wochen“.
enum QuickAdd {
    struct Result: Equatable {
        var title: String
        var date: Date?
        var hasTime: Bool
    }

    private static let weekdays: [(names: [String], weekday: Int)] = [
        (["montag"], 2), (["dienstag"], 3), (["mittwoch"], 4), (["donnerstag"], 5), (["freitag"], 6), (["samstag", "sonnabend"], 7), (["sonntag"], 1),
    ]

    /// Trifft der Ausdruck, wird er aus `text` entfernt und die Treffer-Gruppen zurückgegeben.
    private static func take(_ pattern: String, from text: inout String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = text as NSString
        guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        var groups: [String] = []
        for i in 0..<m.numberOfRanges {
            let r = m.range(at: i)
            groups.append(r.location == NSNotFound ? "" : ns.substring(with: r))
        }
        text = ns.replacingCharacters(in: m.range, with: " ")
        return groups
    }

    static func parse(_ input: String, now: Date = Date(), calendar: Calendar = .current) -> Result {
        var text = input
        var time: (h: Int, m: Int)?
        if let g = take(#"(?<![\d:.])(?:um\s+)?(\d{1,2}):(\d{2})(?:\s*uhr)?(?![\d:])"#, from: &text), let h = Int(g[1]), let m = Int(g[2]), h < 24, m < 60 {
            time = (h, m)
        } else if let g = take(#"(?<![\d.])(?:um\s+)?(\d{1,2})\s*uhr(?!\w)"#, from: &text), let h = Int(g[1]), h < 24 {
            time = (h, 0)
        } else if let g = take(#"(?<![\d.:])um\s+(\d{1,2})(?![\d.:])"#, from: &text), let h = Int(g[1]), h < 24 {
            time = (h, 0)
        }

        let today = calendar.startOfDay(for: now)
        var day: Date?
        if let g = take(#"(?<![\d.])(\d{1,2})\.(\d{1,2})\.(\d{4}|\d{2})?(?!\d)"#, from: &text), let d = Int(g[1]), let mo = Int(g[2]) {
            var year = calendar.component(.year, from: now)
            var explicitYear = false
            if let y = Int(g[3]) { year = y < 100 ? 2000 + y : y; explicitYear = true }
            var candidate = calendar.date(from: DateComponents(year: year, month: mo, day: d))
            if let c = candidate, calendar.component(.day, from: c) != d { candidate = nil }   // 31.2. gibt es nicht
            if let c = candidate, c < today, !explicitYear { candidate = calendar.date(from: DateComponents(year: year + 1, month: mo, day: d)) }
            day = candidate
        } else if take(#"(?<![\p{L}])übermorgen(?![\p{L}])|(?<![\p{L}])uebermorgen(?![\p{L}])"#, from: &text) != nil {
            day = calendar.date(byAdding: .day, value: 2, to: today)
        } else if take(#"(?<![\p{L}])morgen(?![\p{L}])"#, from: &text) != nil {
            day = calendar.date(byAdding: .day, value: 1, to: today)
        } else if take(#"(?<![\p{L}])heute(?![\p{L}])"#, from: &text) != nil {
            day = today
        } else if let g = take(#"(?<![\p{L}])in\s+(\d{1,3})\s+(tagen?|wochen?)(?![\p{L}])"#, from: &text), let n = Int(g[1]) {
            day = calendar.date(byAdding: .day, value: g[2].lowercased().hasPrefix("woche") ? n * 7 : n, to: today)
        } else {
            for (names, weekday) in weekdays {
                if take("(?<![\\p{L}])(?:(?:am|nächsten|naechsten|kommenden)\\s+)*(?:\(names.joined(separator: "|")))(?![\\p{L}])", from: &text) != nil {
                    let current = calendar.component(.weekday, from: today)
                    let ahead = (weekday - current + 7) % 7
                    day = calendar.date(byAdding: .day, value: ahead == 0 ? 7 : ahead, to: today)
                    break
                }
            }
        }

        var date: Date?
        if let time {
            if let day {
                date = calendar.date(bySettingHour: time.h, minute: time.m, second: 0, of: day)
            } else {
                // Nur eine Uhrzeit: heute, wenn sie noch kommt, sonst morgen.
                let todayAt = calendar.date(bySettingHour: time.h, minute: time.m, second: 0, of: today)
                date = (todayAt.map { $0 > now } ?? false) ? todayAt : todayAt.flatMap { calendar.date(byAdding: .day, value: 1, to: $0) }
            }
        } else {
            date = day
        }

        // Übrig gebliebene Verbindungswörter am Rand und doppelte Leerzeichen entfernen.
        var words = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let glue: Set<String> = ["am", "um", "bis", "für", "ab", "zum", "zur", "den", "dem"]
        while let l = words.last, glue.contains(l.lowercased()) || l == "," { words.removeLast() }
        while let f = words.first, glue.contains(f.lowercased()) { words.removeFirst() }
        var title = words.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: " ,;-–"))
        if title.isEmpty { title = input.trimmingCharacters(in: .whitespacesAndNewlines) }
        return Result(title: title, date: date, hasTime: time != nil && date != nil)
    }
}

/// Vorlage für einen Termin oder eine Erinnerung aus einer Mail.
struct PlannerDraft: Identifiable, Hashable {
    enum Kind: String, CaseIterable, Identifiable {
        case reminder, event
        var id: String { rawValue }
        var label: String { self == .reminder ? "Erinnerung" : "Termin" }
    }

    var id = UUID()
    var kind: Kind
    var title: String
    var notes: String
    var url: URL?
    var date: Date
    var hasTime = true
    var listOrCalendarID = ""

    /// Vorgabe: der Tag nach der Frist/Mail um 9 Uhr, mindestens morgen.
    static func defaultDate(due: String? = nil, now: Date = Date(), calendar: Calendar = .current) -> Date {
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
        let base = Deadlines.parse(due).flatMap { $0 >= calendar.startOfDay(for: now) ? $0 : nil } ?? tomorrow
        return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: base) ?? base
    }

    /// Verweis, mit dem sich die Mail aus dem Kalender oder den Erinnerungen wieder öffnen lässt.
    static func link(messageId: String, ownClient: Bool) -> URL? {
        let encoded = "<\(messageId)>".addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        return URL(string: ownClient ? "mailpilot://message/\(encoded)" : "message://\(encoded)")
    }

    /// Die Nachrichtenkennung aus `mailpilot://message/…`.
    static func messageId(fromLink url: URL) -> String? {
        guard url.scheme == "mailpilot", url.host == "message" else { return nil }
        var s = String(url.absoluteString.dropFirst("mailpilot://message/".count)).removingPercentEncoding ?? ""
        if s.hasPrefix("<"), s.hasSuffix(">") { s = String(s.dropFirst().dropLast()) }
        return s.isEmpty ? nil : s
    }

    static func from(subject: String, sender: String, date: Date, link: URL?, kind: Kind, due: String? = nil) -> PlannerDraft {
        var notes = "Von \(sender), \(date.formatted(date: .abbreviated, time: .shortened))"
        if let link { notes += "\n\nMail öffnen: \(link.absoluteString)" }
        let title = subject.trimmingCharacters(in: .whitespaces).isEmpty ? "Mail von \(sender)" : subject
        return PlannerDraft(kind: kind, title: title, notes: notes, url: link, date: defaultDate(due: due))
    }
}

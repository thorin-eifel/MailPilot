import EventKit
import Foundation

/// Freie Zeiten aus dem Kalender für Antwortentwürfe. Es werden nur Zeiträume gelesen, nie Titel oder Orte.
enum FreeSlots {
    struct Options {
        var workStartHour = 9
        var workEndHour = 17
        var minutes = 60
        var horizonDays = 10
        var count = 3
        /// Wochentage (1 = Sonntag … 7 = Samstag), an denen Termine möglich sind
        var weekdays: Set<Int> = [2, 3, 4, 5, 6]
    }

    /// Vereinigt überlappende Zeiträume.
    static func merge(_ intervals: [DateInterval]) -> [DateInterval] {
        var out: [DateInterval] = []
        for i in intervals.sorted(by: { $0.start < $1.start }) {
            if let last = out.last, i.start <= last.end {
                out[out.count - 1] = DateInterval(start: last.start, end: max(last.end, i.end))
            } else {
                out.append(i)
            }
        }
        return out
    }

    /// Runden auf die nächste halbe Stunde.
    static func roundUp(_ d: Date, calendar: Calendar) -> Date {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: d)
        let m = c.minute ?? 0
        let rounded = m == 0 ? 0 : (m <= 30 ? 30 : 60)
        var base = calendar.date(from: DateComponents(year: c.year, month: c.month, day: c.day, hour: c.hour, minute: 0)) ?? d
        base = base.addingTimeInterval(Double(rounded) * 60)
        return base
    }

    /// Bis zu `count` freie Zeiträume, höchstens zwei je Tag (vormittags und nachmittags), frühestens in zwei Stunden.
    static func find(busy: [DateInterval], from now: Date, calendar: Calendar = .current, options o: Options = Options()) -> [DateInterval] {
        let merged = merge(busy)
        let length = Double(o.minutes) * 60
        let earliest = now.addingTimeInterval(2 * 3600)
        var result: [DateInterval] = []
        for offset in 0...o.horizonDays {
            guard let day = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now)),
                  o.weekdays.contains(calendar.component(.weekday, from: day)),
                  let open = calendar.date(bySettingHour: o.workStartHour, minute: 0, second: 0, of: day),
                  let close = calendar.date(bySettingHour: o.workEndHour, minute: 0, second: 0, of: day),
                  let noon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: day),
                  let afternoon = calendar.date(bySettingHour: 13, minute: 0, second: 0, of: day) else { continue }
            func firstSlot(in window: DateInterval) -> DateInterval? {
                guard window.duration >= length else { return nil }
                var cursor = roundUp(max(window.start, earliest), calendar: calendar)
                while cursor.addingTimeInterval(length) <= window.end {
                    let candidate = DateInterval(start: cursor, duration: length)
                    if let clash = merged.first(where: { $0.start < candidate.end && $0.end > candidate.start }) {
                        cursor = roundUp(clash.end, calendar: calendar)
                    } else {
                        return candidate
                    }
                }
                return nil
            }
            if noon > open, let s = firstSlot(in: DateInterval(start: open, end: min(noon, close))) { result.append(s) }
            if close > afternoon, let s = firstSlot(in: DateInterval(start: max(afternoon, open), end: close)) { result.append(s) }
            if result.count >= o.count { break }
        }
        return Array(result.prefix(o.count))
    }

    /// „Dienstag, 4. November, 10:00–11:00 Uhr“
    static func describe(_ slot: DateInterval, locale: Locale = Locale(identifier: "de_DE")) -> String {
        let day = DateFormatter()
        day.locale = locale
        day.dateFormat = "EEEE, d. MMMM"
        let time = DateFormatter()
        time.locale = locale
        time.dateFormat = "HH:mm"
        return "\(day.string(from: slot.start)), \(time.string(from: slot.start))–\(time.string(from: slot.end)) Uhr"
    }
}

/// Kalenderzugriff (EventKit): Termine als belegte Zeiträume.
final class CalendarAvailability: @unchecked Sendable {
    static let shared = CalendarAvailability()
    private let store = EKEventStore()

    var status: EKAuthorizationStatus { EKEventStore.authorizationStatus(for: .event) }
    var isAuthorized: Bool { status == .fullAccess }

    var statusText: String {
        switch status {
        case .fullAccess: "Zugriff erlaubt"
        case .denied: "Zugriff verweigert – in den Systemeinstellungen unter Datenschutz & Sicherheit → Kalender erlauben"
        case .restricted: "Zugriff eingeschränkt"
        case .writeOnly: "Nur Schreibzugriff – für freie Zeiten wird Lesezugriff gebraucht"
        default: "Noch nicht erlaubt"
        }
    }

    func requestAccess() async -> Bool {
        (try? await store.requestFullAccessToEvents()) ?? false
    }

    struct Info: Identifiable, Hashable {
        var id: String
        var title: String
        var source: String
    }

    /// Kalender, in denen Termine stehen können (ohne Feiertage und Geburtstage).
    func calendars() -> [Info] {
        guard isAuthorized else { return [] }
        return store.calendars(for: .event)
            .filter { $0.type != .birthday && $0.title != "Feiertage in Deutschland" && $0.title != "Deutsche Feiertage" }
            .map { Info(id: $0.calendarIdentifier, title: $0.title, source: $0.source?.title ?? "") }
            .sorted { ($0.source, $0.title) < ($1.source, $1.title) }
    }

    /// Belegte Zeiträume: Termine, die „beschäftigt“ anzeigen, nicht abgesagt, nicht ganztägig, nicht von mir abgelehnt.
    func busy(from start: Date, to end: Date, calendarIDs: [String]) -> [DateInterval] {
        guard isAuthorized else { return [] }
        let all = store.calendars(for: .event)
        let chosen = calendarIDs.isEmpty ? all.filter { $0.type != .birthday } : all.filter { calendarIDs.contains($0.calendarIdentifier) }
        guard !chosen.isEmpty else { return [] }
        let events = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: chosen))
        return events.compactMap { e in
            guard !e.isAllDay, e.availability != .free, e.status != .canceled else { return nil }
            if let me = e.attendees?.first(where: \.isCurrentUser), me.participantStatus == .declined { return nil }
            return DateInterval(start: e.startDate, end: max(e.endDate, e.startDate.addingTimeInterval(60)))
        }
    }
}

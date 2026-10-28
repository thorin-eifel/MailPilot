import AppKit
import EventKit
import Foundation

/// Kalender und Erinnerungen über EventKit – für die eigenen Ansichten und für Termine/Erinnerungen aus Mails.
/// (Die automatische Fristen-Übernahme läuft weiter über `ExportBridge`; beides schreibt in dieselben Systemkalender.)
@MainActor
final class Planner: ObservableObject {
    static let shared = Planner()
    private let store = EKEventStore()

    struct Target: Identifiable, Hashable {
        var id: String
        var title: String
        var source: String
        var colorHex: UInt32
        var writable: Bool
    }

    @Published private(set) var events: [PlannerEvent] = []
    @Published private(set) var reminders: [PlannerReminder] = []
    @Published private(set) var calendars: [Target] = []
    @Published private(set) var reminderLists: [Target] = []
    @Published private(set) var eventStatus: EKAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)
    @Published private(set) var reminderStatus: EKAuthorizationStatus = EKEventStore.authorizationStatus(for: .reminder)
    @Published var error: String?
    /// Vorlage aus einer Mail; das Dashboard zeigt dazu ein Blatt.
    @Published var draft: PlannerDraft?

    /// Nur für `--render`: feste Beispieldaten statt Systemzugriff.
    private var preview = false
    var eventsAllowed: Bool { preview || eventStatus == .fullAccess }
    var remindersAllowed: Bool { preview || reminderStatus == .fullAccess }
    var overdueCount: Int { PlannerLogic.overdueCount(reminders) }

    private var loadedRange: DateInterval?
    private var observer: NSObjectProtocol?

    private init() {
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.reload() }
        }
    }

    static func statusText(_ s: EKAuthorizationStatus, what: String) -> String {
        switch s {
        case .fullAccess: "Zugriff erlaubt"
        case .denied: "Zugriff verweigert – in den Systemeinstellungen unter Datenschutz & Sicherheit → \(what) erlauben"
        case .restricted: "Zugriff eingeschränkt"
        case .writeOnly: "Nur Schreibzugriff – zum Anzeigen wird Lesezugriff gebraucht"
        default: "Noch nicht erlaubt"
        }
    }

    func loadPreviewSamples(now: Date = Date()) {
        preview = true
        let cal = Calendar.current
        func at(_ day: Int, _ h: Int, _ m: Int = 0) -> Date {
            cal.date(bySettingHour: h, minute: m, second: 0, of: cal.date(byAdding: .day, value: day, to: cal.startOfDay(for: now))!)!
        }
        calendars = [Target(id: "a", title: "Arbeit", source: "iCloud", colorHex: 0x2D7D8C, writable: true), Target(id: "b", title: "Privat", source: "iCloud", colorHex: 0xC8372D, writable: true)]
        reminderLists = [Target(id: "r", title: "MailPilot", source: "iCloud", colorHex: 0x2D7D8C, writable: true)]
        func ev(_ t: String, _ s: Date, _ e: Date, _ c: Int, loc: String = "", allDay: Bool = false) -> PlannerEvent {
            PlannerEvent(eventID: t, calendarID: calendars[c].id, calendarTitle: calendars[c].title, colorHex: calendars[c].colorHex, title: t, start: s, end: e, allDay: allDay, location: loc, url: nil)
        }
        events = [ev("Teamrunde", at(0, 9), at(0, 10), 0, loc: "Raum 2"), ev("Steuerberater", at(0, 14), at(0, 15, 30), 0), ev("Zahnarzt", at(1, 8, 30), at(1, 9, 15), 1),
                  ev("Urlaub Schmidt", at(2, 0), at(4, 0), 0, allDay: true), ev("Angebot besprechen", at(2, 11), at(2, 12), 0, loc: "Video"), ev("Geburtstag Oma", at(3, 18), at(3, 21), 1)]
        func rem(_ t: String, _ due: Date?, time: Bool = true) -> PlannerReminder {
            PlannerReminder(id: t, listID: "r", listTitle: "MailPilot", colorHex: 0x2D7D8C, title: t, notes: "", due: due, hasTime: time, completed: false, priority: 0, url: nil)
        }
        reminders = [rem("Frist: Angebot Müller", at(-1, 9)), rem("Miete überweisen", at(0, 0), time: false), rem("Steuerberater zurückrufen", at(0, 16)), rem("Frist: Vertrag Schmidt", at(5, 9)), rem("Geschenk besorgen", nil)]
    }

    // MARK: Zugriff


    func requestEvents() async {
        _ = try? await store.requestFullAccessToEvents()
        eventStatus = EKEventStore.authorizationStatus(for: .event)
        await reload()
    }

    func requestReminders() async {
        _ = try? await store.requestFullAccessToReminders()
        reminderStatus = EKEventStore.authorizationStatus(for: .reminder)
        await reload()
    }

    // MARK: Lesen

    private static func hex(_ color: CGColor?) -> UInt32 {
        guard let color, let c = NSColor(cgColor: color)?.usingColorSpace(.sRGB) else { return 0x2D7D8C }
        return UInt32(c.redComponent * 255) << 16 | UInt32(c.greenComponent * 255) << 8 | UInt32(c.blueComponent * 255)
    }

    private func target(_ c: EKCalendar) -> Target {
        Target(id: c.calendarIdentifier, title: c.title, source: c.source?.title ?? "", colorHex: Self.hex(c.cgColor), writable: c.allowsContentModifications)
    }

    /// Lädt Kalender, Erinnerungslisten, offene Erinnerungen und die Termine im gewünschten Zeitraum.
    func load(range: DateInterval) async {
        loadedRange = range
        await reload()
    }

    func reload() async {
        if preview { return }
        eventStatus = EKEventStore.authorizationStatus(for: .event)
        reminderStatus = EKEventStore.authorizationStatus(for: .reminder)
        if eventsAllowed {
            let cals = store.calendars(for: .event)
            calendars = cals.filter { $0.type != .birthday }.map(target).sorted { ($0.source, $0.title) < ($1.source, $1.title) }
            if let range = loadedRange {
                let found = store.events(matching: store.predicateForEvents(withStart: range.start, end: range.end, calendars: cals))
                events = found.map { e in
                    PlannerEvent(eventID: e.eventIdentifier ?? UUID().uuidString, calendarID: e.calendar.calendarIdentifier, calendarTitle: e.calendar.title,
                                 colorHex: Self.hex(e.calendar.cgColor), title: e.title ?? "(ohne Titel)", start: e.startDate, end: e.endDate,
                                 allDay: e.isAllDay, location: e.location ?? "", url: e.url)
                }
            }
        } else {
            calendars = []
            events = []
        }
        if remindersAllowed {
            let lists = store.calendars(for: .reminder)
            reminderLists = lists.map(target).sorted { ($0.source, $0.title) < ($1.source, $1.title) }
            let predicate = store.predicateForReminders(in: lists)
            let items: [PlannerReminder] = await withCheckedContinuation { cont in
                store.fetchReminders(matching: predicate) { found in
                    let cal = Calendar.current
                    cont.resume(returning: (found ?? []).map { r in
                        let comps = r.dueDateComponents
                        return PlannerReminder(id: r.calendarItemIdentifier, listID: r.calendar.calendarIdentifier, listTitle: r.calendar.title,
                                               colorHex: Self.hex(r.calendar.cgColor), title: r.title ?? "(ohne Titel)", notes: r.notes ?? "",
                                               due: comps.flatMap { cal.date(from: $0) }, hasTime: comps?.hour != nil, completed: r.isCompleted,
                                               priority: r.priority, url: r.url)
                    })
                }
            }
            reminders = items
        } else {
            reminderLists = []
            reminders = []
        }
    }

    // MARK: Schreiben – Termine

    struct EventInput {
        var eventID: String?
        var calendarID: String
        var title: String
        var start: Date
        var end: Date
        var allDay: Bool
        var location: String
        var notes: String
        var url: URL?
    }

    /// Die Beschreibung eines bestehenden Termins (für den Bearbeiten-Dialog).
    func eventInput(for e: PlannerEvent) -> EventInput? {
        guard let item = store.event(withIdentifier: e.eventID) else { return nil }
        return EventInput(eventID: e.eventID, calendarID: item.calendar.calendarIdentifier, title: item.title ?? "", start: e.start, end: e.end,
                          allDay: item.isAllDay, location: item.location ?? "", notes: item.notes ?? "", url: item.url)
    }

    @discardableResult
    func saveEvent(_ input: EventInput) async -> Bool {
        guard eventsAllowed else { error = "Kein Zugriff auf den Kalender."; return false }
        let item = input.eventID.flatMap { store.event(withIdentifier: $0) } ?? EKEvent(eventStore: store)
        item.title = input.title
        item.isAllDay = input.allDay
        item.startDate = input.start
        item.endDate = input.allDay ? max(input.end, input.start) : max(input.end, input.start.addingTimeInterval(60))
        item.location = input.location.isEmpty ? nil : input.location
        item.notes = input.notes.isEmpty ? nil : input.notes
        item.url = input.url
        if let cal = store.calendar(withIdentifier: input.calendarID), cal.allowsContentModifications { item.calendar = cal }
        else if item.calendar == nil { item.calendar = store.defaultCalendarForNewEvents }
        do {
            try store.save(item, span: .thisEvent, commit: true)
            await reload()
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func deleteEvent(_ e: PlannerEvent) async {
        guard let item = store.event(withIdentifier: e.eventID) else { return }
        do {
            try store.remove(item, span: .thisEvent, commit: true)
            await reload()
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: Schreiben – Erinnerungen

    struct ReminderInput {
        var id: String?
        var listID: String
        var title: String
        var notes: String
        var due: Date?
        var hasTime: Bool
        var priority: Int
        var url: URL?
    }

    func reminderInput(for r: PlannerReminder) -> ReminderInput {
        ReminderInput(id: r.id, listID: r.listID, title: r.title, notes: r.notes, due: r.due, hasTime: r.hasTime, priority: r.priority, url: r.url)
    }

    @discardableResult
    func saveReminder(_ input: ReminderInput) async -> Bool {
        guard remindersAllowed else { error = "Kein Zugriff auf die Erinnerungen."; return false }
        let item = input.id.flatMap { store.calendarItem(withIdentifier: $0) as? EKReminder } ?? EKReminder(eventStore: store)
        item.title = input.title
        item.notes = input.notes.isEmpty ? nil : input.notes
        item.priority = input.priority
        item.url = input.url
        if let list = store.calendar(withIdentifier: input.listID), list.allowsContentModifications { item.calendar = list }
        else if item.calendar == nil { item.calendar = store.defaultCalendarForNewReminders() }
        if let due = input.due {
            let parts: Set<Calendar.Component> = input.hasTime ? [.year, .month, .day, .hour, .minute] : [.year, .month, .day]
            var comps = Calendar.current.dateComponents(parts, from: due)
            comps.calendar = Calendar.current
            item.dueDateComponents = comps
            // Nur mit Uhrzeit meldet sich die Erinnerung von selbst.
            for a in item.alarms ?? [] { item.removeAlarm(a) }
            if input.hasTime { item.addAlarm(EKAlarm(absoluteDate: due)) }
        } else {
            item.dueDateComponents = nil
            for a in item.alarms ?? [] { item.removeAlarm(a) }
        }
        do {
            try store.save(item, commit: true)
            await reload()
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func setCompleted(_ r: PlannerReminder, _ done: Bool) async {
        guard let item = store.calendarItem(withIdentifier: r.id) as? EKReminder else { return }
        item.isCompleted = done
        do {
            try store.save(item, commit: true)
            await reload()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func deleteReminder(_ r: PlannerReminder) async {
        guard let item = store.calendarItem(withIdentifier: r.id) as? EKReminder else { return }
        do {
            try store.remove(item, commit: true)
            await reload()
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Lässt die Standardliste/den Standardkalender wählen, wenn nichts gewählt ist.
    var defaultCalendarID: String { store.defaultCalendarForNewEvents?.calendarIdentifier ?? calendars.first(where: \.writable)?.id ?? "" }
    var defaultListID: String { store.defaultCalendarForNewReminders()?.calendarIdentifier ?? reminderLists.first(where: \.writable)?.id ?? "" }

    // MARK: Aus einer Mail

    /// Öffnet das Blatt „Termin/Erinnerung anlegen“ im Dashboard.
    func plan(_ kind: PlannerDraft.Kind, subject: String, sender: String, date: Date, messageId: String, ownClient: Bool, due: String? = nil) {
        draft = .from(subject: subject, sender: sender, date: date, link: PlannerDraft.link(messageId: messageId, ownClient: ownClient), kind: kind, due: due)
    }
}

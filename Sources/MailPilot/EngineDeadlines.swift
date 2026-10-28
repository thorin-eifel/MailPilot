import Foundation

/// Fristen aus Gesprächen: Auswahl und Texte (rein, ohne Zugriff auf Erinnerungen/Kalender – daher testbar).
enum Deadlines {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func parse(_ s: String?) -> Date? {
        guard let s, s.count == 10 else { return nil }
        return formatter.date(from: s)
    }

    static func format(_ d: Date) -> String { formatter.string(from: d) }

    /// Offene Gespräche mit einer Frist von heute an, ausgenommen Werbung und Newsletter.
    static func eligible(_ t: MailThread, today: Date = Date()) -> Bool {
        guard t.status != .done, let due = parse(t.dueDate), due >= Calendar.current.startOfDay(for: today) else { return false }
        if let c = t.category?.lowercased(), ["werbung", "newsletter"].contains(c) { return false }
        return true
    }

    static func title(for t: MailThread) -> String {
        "Frist: " + (t.subject.isEmpty ? t.counterpart : t.subject)
    }

    static func notes(for t: MailThread, url: String?) -> String {
        var parts = [t.counterpart]
        if !t.nextStep.isEmpty { parts.append("Nächster Schritt: \(t.nextStep)") }
        if !t.summary.isEmpty { parts.append(t.summary) }
        if let url { parts.append("Mail öffnen: \(url)") }
        return parts.joined(separator: "\n\n")
    }
}

private struct DeadlineError: LocalizedError {
    var errorDescription: String?
}

extension Engine {
    func loadExportTargets() async {
        do {
            let t = try await bridge.exportTargets()
            reminderLists = t.reminderLists
            calendars = t.calendars.filter(\.writable)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func setDueDate(_ thread: MailThread, to date: Date?) {
        var t = thread
        t.dueDate = date.map(Deadlines.format)
        try? store.upsert(t)
        reload()
    }

    /// Trägt die Frist eines Gesprächs als Erinnerung oder Kalendereintrag ein. Doppelte Einträge werden verhindert.
    @discardableResult
    func exportDeadline(_ thread: MailThread, kind: DeadlineKind, automatic: Bool = false) async -> Bool {
        guard let due = thread.dueDate, Deadlines.parse(due) != nil else {
            lastError = "Das Gespräch hat keine gültige Frist."
            return false
        }
        if store.hasExport(thread.threadKey, due: due, kind: kind.rawValue) {
            if !automatic { status = "Diese Frist ist bereits eingetragen." }
            return true
        }
        let msgs = messages(in: thread)
        let url = msgs.last(where: { !$0.isFromMe })?.mailURL?.absoluteString
        let title = Deadlines.title(for: thread)
        let notes = Deadlines.notes(for: thread, url: url)
        do {
            let id: String?
            switch kind {
            case .reminder:
                id = try await bridge.createReminder(title: title, notes: notes, due: due,
                                                     list: settings.reminderList.isEmpty ? "MailPilot" : settings.reminderList)
            case .calendar:
                guard !settings.calendarID.isEmpty else { throw DeadlineError(errorDescription: "Kein Kalender gewählt (Einstellungen → Fristen).") }
                id = try await bridge.createEvent(title: title, notes: notes, due: due, calendarID: settings.calendarID, url: url)
            }
            try store.addExport(thread.threadKey, due: due, kind: kind.rawValue, extId: id)
            if let m = msgs.last {
                store.log(m, kind: "deadline", detail: "\(kind == .reminder ? "Erinnerung" : "Kalendereintrag") für \(due) angelegt", dryRun: false)
            }
            status = "\(kind == .reminder ? "Erinnerung" : "Kalendereintrag") für den \(due) angelegt."
            reload()
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    /// Automatische Übernahme (Einstellungen → Fristen); höchstens `limit` neue Einträge je Durchlauf.
    func syncDeadlines(limit: Int = 8) async {
        let kinds = settings.deadlineTarget.kinds
        guard !kinds.isEmpty else { return }
        var created = 0
        for t in threads where Deadlines.eligible(t) {
            for kind in kinds {
                guard let due = t.dueDate, !store.hasExport(t.threadKey, due: due, kind: kind.rawValue) else { continue }
                if created >= limit { return }
                created += 1
                if await !exportDeadline(t, kind: kind, automatic: true) { return }
            }
        }
    }
}

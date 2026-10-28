import Foundation
import UserNotifications

/// Zeitpunkte für „Zurückstellen“.
enum SnoozeOption: String, CaseIterable, Identifiable {
    case tonight, tomorrow, nextMonday, nextWeek

    var id: String { rawValue }

    var label: String {
        switch self {
        case .tonight: "Heute Abend"
        case .tomorrow: "Morgen früh"
        case .nextMonday: "Montag"
        case .nextWeek: "In einer Woche"
        }
    }

    var symbol: String {
        switch self {
        case .tonight: "moon.fill"
        case .tomorrow: "sunrise.fill"
        case .nextMonday: "calendar"
        case .nextWeek: "calendar.badge.clock"
        }
    }

    /// Zielzeitpunkt; `nil`, wenn die Option nicht mehr sinnvoll ist (z. B. „Heute Abend“ nach 17:30 Uhr).
    func date(from now: Date, calendar: Calendar = .current) -> Date? {
        switch self {
        case .tonight:
            guard let t = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: now),
                  t.timeIntervalSince(now) > 30 * 60 else { return nil }
            return t
        case .tomorrow:
            return calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
                .flatMap { calendar.date(bySettingHour: 8, minute: 0, second: 0, of: $0) }
        case .nextMonday:
            return calendar.nextDate(after: now, matching: DateComponents(hour: 8, minute: 0, weekday: 2), matchingPolicy: .nextTime)
        case .nextWeek:
            return calendar.date(byAdding: .day, value: 7, to: now)
                .flatMap { calendar.date(bySettingHour: 8, minute: 0, second: 0, of: $0) }
        }
    }
}

/// Zurückstellen und Nachfassen.
extension Engine {
    // MARK: Zurückstellen

    func snooze(_ thread: MailThread, until date: Date?) {
        var t = thread
        t.snoozedUntil = date
        try? store.upsert(t)
        reload()
    }

    /// Holt Gespräche zurück, deren Zeit abgelaufen ist.
    func wakeSnoozedThreads() async {
        let due = threads.filter { t in t.snoozedUntil.map { $0 <= Date() } ?? false }
        guard !due.isEmpty else { return }
        for var t in due {
            t.snoozedUntil = nil
            try? store.upsert(t)
            notify(title: "Wieder da: \(t.subject)", body: t.nextStep.isEmpty ? t.counterpart : "\(t.counterpart) · \(t.nextStep)", id: "snooze-\(t.threadKey)", thread: t.threadKey)
        }
        reload()
    }
}

/// Auswahl und Aufbau von Nachfass-Mails (rein, ohne Mail-Zugriff – daher testbar).
enum FollowUp {
    /// Gespräche, bei denen ich zuletzt geschrieben habe, seit `followUpDays` Tagen keine Antwort kam und noch kein Entwurf liegt.
    static func candidates(_ threads: [MailThread], followUpDays: Int, now: Date = Date()) -> [MailThread] {
        func rank(_ p: Priority) -> Int { p == .high ? 0 : (p == .normal ? 1 : 2) }
        return threads
            .filter { $0.isFollowUpCase && !$0.isSnoozed && !$0.isPrivate && ($0.draft ?? "").isEmpty
                && $0.lastDate < now.addingTimeInterval(-Double(followUpDays) * 86400) }
            .sorted { rank($0.priority) != rank($1.priority) ? rank($0.priority) < rank($1.priority) : $0.lastDate < $1.lastDate }
    }

    /// „Angebot“ → „Re: Angebot“; vorhandene Re:/AW:-Präfixe bleiben.
    static func subject(for original: String) -> String {
        let s = original.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return "Nachfrage" }
        return MailAddress.normalizeSubject(s) == s.lowercased() ? "Re: \(s)" : s
    }

    /// Eigene letzte Nachricht als Zitat unter der Nachfrage.
    static func body(text: String, quoting mine: StoredMessage) -> String {
        let quoted = mine.content.prefix(900).split(separator: "\n", omittingEmptySubsequences: false).map { "> \($0)" }.joined(separator: "\n")
        return text + "\n\nAm \(mine.date.formatted(date: .numeric, time: .shortened)) schrieb ich:\n" + quoted
    }
}

extension Engine {
    // MARK: Nachfassen

    /// Bereitet für überfällige Gespräche Nachfass-Entwürfe vor (höchstens `limit` je Durchlauf).
    func generateFollowUps(limit: Int = 3) async {
        guard settings.autoFollowUpDrafts, claude != nil, UsageMonitor.shared.blockReason() == nil else { return }
        for t in FollowUp.candidates(threads, followUpDays: settings.followUpDays).prefix(limit) {
            status = "Nachfass-Entwurf: \(t.subject.prefix(40))"
            guard await redraft(t, hint: "", interactive: false) != nil else { break }
            notify(title: "Nachfass-Entwurf bereit", body: "\(t.subject) – \(t.counterpart)", id: "fu-draft-\(t.threadKey)", thread: t.threadKey)
        }
    }

    /// Öffnet ein neues Nachrichtenfenster an die Empfänger meiner letzten Nachricht. Gesendet wird nichts.
    func openFollowUp(for thread: MailThread, text: String, save: Bool = false) async {
        guard let mine = messages(in: thread).last(where: { $0.isFromMe }) else {
            lastError = "Keine gesendete Nachricht in diesem Gespräch gefunden."
            return
        }
        let own = Set(myAddresses)
        var to: [String] = []
        for r in mine.recipients {
            let email = MailAddress.parse(r).email
            if !email.isEmpty, !own.contains(email), !to.contains(email) { to.append(email) }
        }
        guard !to.isEmpty else {
            lastError = "Keine Empfänger für die Nachfrage gefunden."
            return
        }
        do {
            try await bridge.compose(sender: mine.sender, to: to, subject: FollowUp.subject(for: thread.subject),
                                     content: FollowUp.body(text: text, quoting: mine), save: save)
            if save { status = "Nachfrage als Entwurf in Mail abgelegt – dort noch prüfen und senden." }
        } catch {
            lastError = error.localizedDescription
        }
    }
}

extension Engine {
    /// Fragt die aktuelle Abo-Auslastung mit einem winzigen Aufruf ab.
    func refreshPlanLimits() async {
        guard let path = ClaudeClient.locate(preferred: settings.claudePath) else { lastError = ClaudeError.notFound.localizedDescription; return }
        var c = ClaudeClient(executable: path, model: "haiku")
        c.interactive = true
        do { _ = try await c.tagged("Limit-Abfrage").ping() } catch { lastError = error.localizedDescription }
        refreshUsage()
    }
}

/// Knöpfe an Mitteilungen und Tastenkürzel: Aktionen auf dem geöffneten bzw. angetippten Gespräch.
enum NotificationAction: String {
    case open = "OPEN", reply = "REPLY", snooze = "SNOOZE", done = "DONE"

    static let categoryID = "THREAD"

    static var category: UNNotificationCategory {
        UNNotificationCategory(identifier: categoryID, actions: [
            UNNotificationAction(identifier: reply.rawValue, title: "Antworten", options: [.foreground]),
            UNNotificationAction(identifier: snooze.rawValue, title: "Morgen früh wieder zeigen", options: []),
            UNNotificationAction(identifier: done.rawValue, title: "Erledigt", options: []),
        ], intentIdentifiers: [], options: [])
    }

    /// Antippen der Mitteilung selbst entspricht „Öffnen“.
    static func parse(_ identifier: String) -> NotificationAction {
        NotificationAction(rawValue: identifier) ?? .open
    }
}

extension Engine {
    var selectedThread: MailThread? { selectedThreadKey.flatMap { k in threads.first { $0.threadKey == k } } }

    func handle(_ action: NotificationAction, threadKey: String) async {
        guard let t = threads.first(where: { $0.threadKey == threadKey }) else { return }
        switch action {
        case .open:
            focusThread = threadKey
            openDashboard?()
        case .reply:
            focusThread = threadKey
            await openReply(for: t, text: t.draft ?? "")
        case .snooze:
            snooze(t, until: SnoozeOption.tomorrow.date(from: Date()))
        case .done:
            setStatus(.done, for: t)
        }
    }

    func snoozeSelected(_ option: SnoozeOption) {
        guard let t = selectedThread, let date = option.date(from: Date()) else { return }
        snooze(t, until: date)
        status = "„\(t.subject.prefix(40))“ zurückgestellt bis \(date.formatted(date: .abbreviated, time: .shortened))"
    }

    func markSelectedDone() {
        guard let t = selectedThread else { return }
        setStatus(.done, for: t)
    }

    func replySelected() async {
        guard let t = selectedThread else { return }
        await openReply(for: t, text: t.draft ?? "")
    }
}

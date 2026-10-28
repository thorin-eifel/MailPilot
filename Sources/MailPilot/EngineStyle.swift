import Foundation

/// Antwortstil: lernen, speichern, in Entwürfen verwenden.
extension Engine {
    var styleProfile: String { store.value("styleProfile") ?? "" }

    var styleInfo: String {
        guard !styleProfile.isEmpty else { return "Noch kein Stil gelernt." }
        let n = store.value("styleSampleCount") ?? "?"
        let date = store.value("styleProfileDate").flatMap(Double.init).map { Date(timeIntervalSince1970: $0).formatted(date: .abbreviated, time: .omitted) } ?? "?"
        return "Gelernt am \(date) aus \(n) gesendeten Mails."
    }

    func setStyleProfile(_ text: String) {
        store.setValue(text.isEmpty ? nil : text, for: "styleProfile")
        objectWillChange.send()
    }

    /// Stilprofil (falls aktiviert) und Beispiele früherer Mails an dieselbe Person.
    func styleContext(for thread: MailThread, messages msgs: [StoredMessage], examples wanted: Bool) -> (guide: String, examples: [String]) {
        guard settings.useStyleProfile, !styleProfile.isEmpty else { return ("", []) }
        guard wanted else { return (styleProfile, []) }
        let to = (msgs.last(where: { !$0.isFromMe })?.senderEmail).flatMap { $0.isEmpty ? nil : $0 }
            ?? msgs.last(where: { $0.isFromMe })?.recipients.first.map { MailAddress.parse($0).email } ?? ""
        return (styleProfile, store.sentExamples(toEmail: to))
    }

    /// Liest den Sendeverlauf der letzten `days` Tage nur für den Stil ein (keine Analyse, keine Gespräche).
    /// Mails an Empfänger mit Datenschutz-Ausnahme werden übersprungen.
    @discardableResult
    func loadSentHistory(days: Int = 180) async -> Int {
        guard !styleBusy else { return 0 }
        styleBusy = true
        defer { styleBusy = false }
        var added = 0
        do {
            let since = Date().addingTimeInterval(-Double(days) * 86400)
            let mine = Set(myAddresses)
            for _ in 0..<10 {
                status = "Sendeverlauf einlesen: \(added) Mails …"
                let known = try store.knownMessageIds(since: since.addingTimeInterval(-86400))
                let r = try await bridge.fetch(since: since, sentSince: since, accounts: enabledAccountNames, known: known, maxNew: 200,
                                               includeSent: true, contentLimit: 3000, inbox: false)
                for raw in r.messages {
                    let probe = StoredMessage(messageId: raw.messageId, mailId: raw.id, account: raw.account, mailbox: raw.mailbox, subject: raw.subject,
                                              sender: raw.sender, senderEmail: MailAddress.parse(raw.sender).email,
                                              recipients: raw.to + raw.cc, date: Date.fromISO(raw.date) ?? Date(), isFromMe: true, inReplyTo: nil,
                                              references: [], content: raw.content, threadKey: nil, category: nil, priority: nil, summary: nil,
                                              processed: false, error: nil)
                    if PrivacyPolicy.rule(for: probe, settings: settings) != nil { continue }
                    try store.insertStyleOnly(raw, myAddresses: mine)
                    added += 1
                }
                if r.remaining == 0 || r.messages.isEmpty { break }
            }
            status = "Sendeverlauf eingelesen: \(added) Mails"
        } catch {
            lastError = error.localizedDescription
        }
        return added
    }

    /// Lernt den Stil aus den gesendeten Mails. `manual` = vom Nutzer ausgelöst (ignoriert die Pause-Grenze).
    func learnStyle(manual: Bool) async {
        guard !styleBusy, let claude = manual ? claudeInteractive : self.claude else { return }
        styleBusy = true
        defer { styleBusy = false; objectWillChange.send() }
        let sent = (try? store.sentMessages(accounts: enabledAccountNames)) ?? []
        let samples = StyleLearner.samples(from: sent)
        guard samples.count >= StyleLearner.minSamples else {
            lastError = "Zu wenige geeignete gesendete Mails (\(samples.count) von mindestens \(StyleLearner.minSamples)). „Sendeverlauf einlesen“ holt ältere nach."
            return
        }
        status = "Stil lernen aus \(samples.count) Mails …"
        do {
            let profile = try await claude.learnStyle(samples: samples)
            guard !profile.isEmpty else { return }
            store.setValue(profile, for: "styleProfile")
            store.setValue(String(Date().timeIntervalSince1970), for: "styleProfileDate")
            store.setValue(String(samples.count), for: "styleSampleCount")
            status = "Antwortstil gelernt"
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Automatisch einmal lernen, sobald genug gesendete Mails vorliegen (höchstens ein Versuch pro Tag).
    func learnStyleIfNeeded() async {
        guard settings.useStyleProfile, styleProfile.isEmpty, initialComplete, claude != nil, UsageMonitor.shared.blockReason() == nil else { return }
        let today = Deadlines.format(Date())
        guard store.value("styleTried") != today else { return }
        let sent = (try? store.sentMessages(accounts: enabledAccountNames)) ?? []
        guard StyleLearner.samples(from: sent).count >= StyleLearner.minSamples else { return }
        store.setValue(today, for: "styleTried")
        await learnStyle(manual: false)
    }
}

/// Wochenbericht
extension Engine {
    /// Erstellt den Bericht: Kennzahlen lokal, Text von Claude. Ohne Claude (Pause, Fehler) gibt es die Kennzahlen trotzdem.
    func generateWeeklyReport(manual: Bool) async {
        guard !weeklyBusy else { return }
        weeklyBusy = true
        defer { weeklyBusy = false; reload() }
        let stats = Weekly.compute(store: store, accounts: enabledAccountNames, threads: threads, invoices: invoices)
        var text = ""
        if let claude = manual ? claudeInteractive : self.claude {
            do { text = try await claude.weeklyReport(stats: stats, settings: settings) } catch {
                if manual { lastError = error.localizedDescription }
                if case ClaudeError.blocked = error, !manual { return }
            }
        }
        try? store.saveReport(text: text, stats: stats)
        status = "Wochenbericht erstellt"
    }

    /// Montags ab der Briefing-Uhrzeit, einmal pro Woche.
    func weeklyReportIfDue() async {
        let cal = Calendar.current
        guard initialComplete, cal.component(.weekday, from: Date()) == 2, cal.component(.hour, from: Date()) >= settings.briefingHour,
              UsageMonitor.shared.blockReason() == nil else { return }
        if let last = weeklyReport?.date, Date().timeIntervalSince(last) < 5 * 86400 { return }
        await generateWeeklyReport(manual: false)
        notify(title: "Dein Wochenbericht ist da", body: "Wo du säumig bist, worauf du wartest und was sich verändert hat.", id: "weekly")
    }
}

/// Kontakte: Namen und VIP-Gruppe
extension Engine {
    /// Name des Absenders: aus der Mail, sonst aus den Kontakten, sonst die Adresse.
    func displayName(_ m: StoredMessage) -> String {
        if let n = MailAddress.parse(m.sender).name { return n }
        return (settings.useContactNames ? ContactsDirectory.shared.name(for: m.senderEmail) : nil) ?? m.senderEmail
    }

    /// Name zu einer Adresse wie `Anna <anna@x.de>`.
    func contactName(_ raw: String) -> String {
        let p = MailAddress.parse(raw)
        if let n = p.name { return n }
        return (settings.useContactNames ? ContactsDirectory.shared.name(for: p.email) : nil) ?? p.email
    }

    func requestContactsAccess() async {
        let ok = await ContactsDirectory.shared.requestAccess()
        if ok { await syncContacts() }
        objectWillChange.send()
    }

    /// Liest die Kontakte und gleicht die VIP-Gruppe ab.
    func syncContacts() async {
        guard ContactsDirectory.shared.isAuthorized else { return }
        do { try ContactsDirectory.shared.reload() } catch { lastError = "Kontakte konnten nicht gelesen werden: \(error.localizedDescription)"; return }
        if !settings.vipContactGroup.isEmpty {
            let members = ContactsDirectory.shared.members(ofGroup: settings.vipContactGroup)
            let merged = VIPSync.merge(existing: settings.vips, members: members)
            if merged != settings.vips { settings.vips = merged }
            status = "Kontakte abgeglichen: \(members.count) Personen in „\(settings.vipContactGroup)“"
        }
        objectWillChange.send()
    }
}

/// Freie Zeiten für Antwortentwürfe
extension Engine {
    nonisolated private static let schedulingWords = ["termin", "treffen", "meeting", "besprechung", "call", "telefonat", "gespräch", "verfügbar", "wann hast", "wann passt",
                                          "zeit für", "appointment", "schedule", "availab", "catch up", "kennenlernen", "rückruf", "vorbeikommen"]

    /// Hat die letzte eingehende Mail mit einer Terminabsprache zu tun?
    nonisolated static func mentionsScheduling(_ text: String) -> Bool {
        let t = text.lowercased()
        return schedulingWords.contains { t.contains($0) }
    }

    /// Freie Zeiten als Text („Dienstag, 4. November, 10:00–11:00 Uhr“) – nur wenn die Mail eine Terminabsprache nahelegt oder `force`.
    func freeSlotTexts(for msgs: [StoredMessage], force: Bool) -> [String] {
        guard settings.useFreeSlots, CalendarAvailability.shared.isAuthorized else { return [] }
        if !force {
            guard let last = msgs.last(where: { !$0.isFromMe }), Self.mentionsScheduling(last.subject + " " + last.content) else { return [] }
        }
        let now = Date()
        let end = Calendar.current.date(byAdding: .day, value: 12, to: now) ?? now
        let busy = CalendarAvailability.shared.busy(from: now, to: end, calendarIDs: settings.availabilityCalendars)
        var o = FreeSlots.Options()
        o.workStartHour = settings.workStartHour
        o.workEndHour = max(settings.workEndHour, settings.workStartHour + 1)
        o.minutes = settings.slotMinutes
        return FreeSlots.find(busy: busy, from: now, options: o).map { FreeSlots.describe($0) }
    }

    func requestCalendarAccess() async {
        _ = await CalendarAvailability.shared.requestAccess()
        objectWillChange.send()
    }
}

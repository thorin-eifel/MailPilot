import Foundation

/// Tests für Datenschutz, Nutzung, Suche, Antwortstil, Wochenbericht, Newsletter, Flaggen und Sicherung (`--selftest-more`).
enum SelfTest2 {
    nonisolated(unsafe) static var failures = 0

    static func check(_ ok: Bool, _ name: String) {
        print((ok ? "PASS  " : "FAIL  ") + name)
        if !ok { failures += 1 }
    }

    static func raw(_ id: String, subject: String = "Hallo", from: String = "A <a@b.de>", body: String = "", account: String = "iCloud",
                    sent: Bool = false, to: [String] = [], date: Date = Date()) -> RawMessage {
        RawMessage(id: 1, messageId: id, account: account, mailbox: sent ? "Sent" : "INBOX", subject: subject, sender: from, date: date.isoString,
                   read: false, inReplyTo: nil, references: [], to: to, cc: [], content: body, isSent: sent)
    }

    static func run() {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mp-more-\(UUID())", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        do {
            try privacyTests()
            try usageTests(tmp)
            try searchTests(tmp)
            try styleTests(tmp)
            try weeklyTests(tmp)
            try newsletterTests(tmp)
            try flagTests(tmp)
            try backupTests(tmp)
            try exportTests(tmp)
        } catch {
            check(false, "Tests liefen ohne Fehler: \(error)")
        }
        print(failures == 0 ? "\nAlle Tests bestanden." : "\n\(failures) Test(s) fehlgeschlagen.")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: Datenschutz

    static func privacyTests() throws {
        func msg(_ from: String, subject: String = "Hallo", body: String = "", mine: Bool = false, to: [String] = []) -> StoredMessage {
            var m = RulesSelfTest.msg("x", from: from, subject: subject, body: body, mine: mine)
            if !to.isEmpty { m.recipients = to }
            return m
        }
        var rule = PrivacyRule()
        rule.conditions = [RuleCondition(field: .domain, value: "kanzlei-mueller.de")]
        check(rule.matches(msg("anwalt@kanzlei-mueller.de")) && rule.matches(msg("x@mail.kanzlei-mueller.de")) && !rule.matches(msg("a@other.de")), "Datenschutz: Domain trifft eingehende Mails")
        check(rule.matches(msg("ich@example.org", mine: true, to: ["Dr. M <anwalt@kanzlei-mueller.de>"])) && !rule.matches(msg("ich@example.org", mine: true, to: ["x@other.de"])),
              "Datenschutz: bei gesendeten Mails zählen die Empfänger")
        var addr = PrivacyRule()
        addr.conditions = [RuleCondition(field: .sender, value: "bank@sparkasse.example")]
        check(addr.matches(msg("Bank@Sparkasse.example")) && addr.matches(msg("me@x.de", mine: true, to: ["bank@sparkasse.example"])), "Datenschutz: Adresse (ohne Groß-/Kleinschreibung), auch als Empfänger")
        var kw = PrivacyRule()
        kw.conditions = [RuleCondition(field: .subject, value: "Befund"), RuleCondition(field: .body, value: "Diagnose")]
        check(kw.matches(msg("a@b.de", subject: "Ihr Befund")) && kw.matches(msg("a@b.de", body: "die Diagnose lautet")) && !kw.matches(msg("a@b.de")), "Datenschutz: Stichworte, mindestens eine Bedingung")
        kw.matchAll = true
        check(!kw.matches(msg("a@b.de", subject: "Ihr Befund")) && kw.matches(msg("a@b.de", subject: "Befund", body: "Diagnose")), "Datenschutz: alle Bedingungen")
        var off = rule; off.enabled = false
        var empty = PrivacyRule(); empty.conditions = [RuleCondition(field: .domain, value: " ")]
        check(!off.matches(msg("a@kanzlei-mueller.de")) && !empty.matches(msg("a@b.de")), "Datenschutz: deaktivierte und leere Ausnahmen treffen nie")
        var s = AppSettings()
        s.privacyRules = [off, rule]
        check(PrivacyPolicy.rule(for: msg("a@kanzlei-mueller.de"), settings: s)?.id == rule.id, "Datenschutz: erste aktive Ausnahme gilt")

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mp-priv-\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = try Store(path: tmp)
        try store.insert(raw("p1", subject: "Vertrag", from: "Anwalt <a@kanzlei-mueller.de>", body: "streng vertraulicher Inhalt"), myAddresses: [])
        try store.markPrivate("p1", threadKey: "p1", keepBody: false, category: nil, priority: .normal, decidedBy: "Datenschutz")
        let m = try store.message(id: "p1")
        check(m?.content == "" && m?.isPrivate == true && m?.processed == true && m?.summary?.contains("Vertraulich") == true, "Datenschutz: Mailtext wird nicht gespeichert, Mail gilt als erledigt")
        try store.insert(raw("p2", subject: "Zweite", from: "A <a@kanzlei-mueller.de>", body: "Text bleibt"), myAddresses: [])
        try store.markPrivate("p2", threadKey: "p2", keepBody: true, category: nil, priority: nil, decidedBy: nil)
        check(try store.message(id: "p2")?.content == "Text bleibt", "Datenschutz: Mailtext kann behalten werden")
        check(try store.unprocessedMessages(limit: 10, accounts: ["iCloud"]).isEmpty, "Datenschutz: vertrauliche Mails landen nie in der Analyse-Warteschlange")
        var t = FeatureSelfTest.thread("p1", status: .info, lastFromMe: false)
        try store.upsert(t)
        try store.markThreadPrivate("p1")
        t = try store.thread("p1")!
        check(t.isPrivate && t.summary.contains("Vertraulich") && t.dueDate == nil && t.draft == nil && store.isThreadPrivate("p1") && !store.isThreadPrivate("zzz"), "Datenschutz: Gespräch wird vertraulich markiert und bereinigt")
        try store.saveInvoice(FeatureSelfTest.invoice("p1"))
        check(try store.invoiceQueue(category: "Rechnungen", accounts: ["iCloud"], limit: 5).isEmpty, "Datenschutz: nie in der Rechnungs-Warteschlange")
    }

    // MARK: Nutzung

    static func usageTests(_ tmp: URL) throws {
        let store = try Store(path: tmp.appendingPathComponent("u.sqlite"))
        func rec(_ purpose: String, ok: Bool = true, interactive: Bool = false, at: Date = Date(), tokens: Int = 100) -> UsageRecord {
            UsageRecord(date: at, purpose: purpose, model: "sonnet", inputTokens: tokens, outputTokens: 20, cacheReadTokens: 5, costUSD: 0.01, durationMs: 2000, ok: ok, interactive: interactive)
        }
        try store.addUsage(rec("Analyse")); try store.addUsage(rec("Analyse")); try store.addUsage(rec("Entwurf", interactive: true))
        try store.addUsage(rec("Analyse", ok: false)); try store.addUsage(rec("Alt", at: Date().addingTimeInterval(-3 * 86400)))
        let today = store.usageSummary(since: Calendar.current.startOfDay(for: Date()))
        check(today.calls == 4 && today.failures == 1 && today.inputTokens == 400 && today.outputTokens == 80 && abs(today.avgSeconds - 2) < 0.01, "Nutzung: Tagessumme (Aufrufe, Fehler, Token, Dauer)")
        check(store.autoCallsToday() == 3, "Nutzung: nur automatische Aufrufe zählen für die Obergrenze")
        let by = store.usageByPurpose(since: Date().addingTimeInterval(-7 * 86400))
        check(by.first?.purpose == "Analyse" && by.first?.calls == 3 && by.count == 3, "Nutzung: Aufrufe je Zweck")
        let days = store.usageByDay(days: 7)
        check(days.count == 7 && days.last?.calls == 4 && days.reduce(0) { $0 + $1.calls } == 5 && days[3].calls == 1, "Nutzung: Aufrufe je Tag (sieben Tage, auch leere)")

        let info: [String: Any] = ["status": "allowed_warning", "rateLimitType": "seven_day", "utilization": 0.68, "resetsAt": 1793599200.0,
                                   "unifiedWindows": ["five_hour": ["utilization": 0.71, "resetsAt": 1793209800.0, "status": "allowed"],
                                                      "seven_day": ["utilization": 0.68, "resetsAt": 1793599200.0, "status": "allowed"]]]
        let l = PlanLimits.parse(info)
        check(l?.fiveHour?.percent == 71 && l?.sevenDay?.percent == 68 && l?.sevenDay?.resetsAt == Date(timeIntervalSince1970: 1793599200), "Nutzung: Limit-Meldung der CLI wird gelesen")
        check(PlanLimits.parse(["rateLimitType": "five_hour", "utilization": 0.4, "resetsAt": 1793209800.0, "status": "allowed"])?.fiveHour?.percent == 40
              && PlanLimits.parse(["foo": 1]) == nil, "Nutzung: Meldung ohne Fensterliste, ungültige Meldung")

        // Schutz
        let mon = UsageMonitor()
        mon.configure(store: store)
        mon.update(UsageGuardSettings(enabled: true, fiveHourLimit: 0.9, sevenDayLimit: 0.9, maxCallsPerDay: 0))
        let future = Date().addingTimeInterval(7200)
        func limits(_ five: Double, _ seven: Double, resets: Date = future) -> PlanLimits {
            PlanLimits(fiveHour: PlanWindow(utilization: five, resetsAt: resets, status: "allowed"), sevenDay: PlanWindow(utilization: seven, resetsAt: resets, status: "allowed"), updatedAt: Date())
        }
        check(mon.blockReason() == nil, "Schutz: ohne Messung keine Pause")
        mon.record(rec("Test"), limits: limits(0.5, 0.5))
        check(mon.blockReason() == nil, "Schutz: unter den Grenzen keine Pause")
        mon.record(rec("Test"), limits: limits(0.93, 0.5))
        check(mon.blockReason()?.contains("5-Stunden") == true, "Schutz: 5-Stunden-Fenster über der Grenze → Pause")
        mon.record(rec("Test"), limits: limits(0.5, 0.95))
        check(mon.blockReason()?.contains("7-Tage") == true, "Schutz: 7-Tage-Fenster über der Grenze → Pause")
        mon.record(rec("Test"), limits: limits(0.99, 0.99, resets: Date().addingTimeInterval(-60)))
        check(mon.blockReason() == nil, "Schutz: abgelaufenes Fenster zählt nicht mehr")
        mon.update(UsageGuardSettings(enabled: false, fiveHourLimit: 0.9, sevenDayLimit: 0.9, maxCallsPerDay: 0))
        mon.record(rec("Test"), limits: limits(0.99, 0.99))
        check(mon.blockReason() == nil, "Schutz: abschaltbar")
        mon.update(UsageGuardSettings(enabled: false, fiveHourLimit: 0.9, sevenDayLimit: 0.9, maxCallsPerDay: 3))
        check(mon.blockReason()?.contains("Tageslimit") == true, "Schutz: Obergrenze automatischer Aufrufe pro Tag")
        mon.update(UsageGuardSettings(enabled: false, fiveHourLimit: 0.9, sevenDayLimit: 0.9, maxCallsPerDay: 0))
        mon.noteRateLimited()
        check(mon.blockReason()?.contains("Limit erreicht") == true, "Schutz: gemeldetes Limit → Pause")
        mon.clearBlock()
        check(mon.blockReason() == nil && PlanLimits.parse(info) != nil, "Schutz: Pause aufhebbar")
        let reloaded = UsageMonitor()
        reloaded.configure(store: store)
        check(reloaded.currentLimits != nil, "Schutz: letzte Messung überlebt einen Neustart")
    }

    // MARK: Suche

    static func searchTests(_ tmp: URL) throws {
        check(FTSQuery.make("") == nil && FTSQuery.make("   ") == nil && FTSQuery.make("\"*()") == nil, "Suche: leere Eingabe")
        check(FTSQuery.make("Rechnung Telekom") == "\"Rechnung\" \"Telekom\"*", "Suche: alle Wörter, letztes als Wortanfang")
        check(FTSQuery.make("\"Server Migration\" Angebot") == "\"Server Migration\" \"Angebot\"*", "Suche: Phrase in Anführungszeichen")
        check(FTSQuery.make("a:b (c) ^d* \"e") == "\"ab\" \"c\" \"d\" \"e\"", "Suche: FTS-Sonderzeichen werden entschärft")
        let store = try Store(path: tmp.appendingPathComponent("s.sqlite"))
        func add(_ id: String, subject: String, body: String, from: String = "Anna <anna@firma.example>", summary: String? = nil, thread: String? = nil) throws {
            try store.insert(raw(id, subject: subject, from: from, body: body), myAddresses: [])
            try store.saveAnalysis(of: id, threadKey: thread ?? id, category: "Info", priority: .normal, summary: summary)
        }
        try add("s1", subject: "Angebot Server-Migration", body: "Wir bieten die Migration Ihrer Server zum Festpreis an.", summary: "Angebot für Migration")
        try add("s2", subject: "Ärger mit der Rechnung", body: "Die Rechnung enthält einen falschen Betrag.", from: "Bernd <bernd@kunde.example>")
        try add("s3", subject: "Re: Angebot Server-Migration", body: "Danke, wir nehmen das Angebot an.", from: "Bernd <bernd@kunde.example>", thread: "s1")
        try add("s4", subject: "Newsletter", body: "Herbstrabatt auf alles")
        func subjects(_ q: String) -> [String] { ((try? store.search(q)) ?? []).map(\.subject) }
        check(store.searchIndexCount() >= 4, "Suche: Index enthält die Mails")
        check(subjects("arger").contains("Ärger mit der Rechnung") && subjects("ÄRGER").count == 1, "Suche: Umlaute und Groß-/Kleinschreibung egal")
        check(subjects("Migrat").count == 1, "Suche: Wortanfang findet Treffer, zusammengefasst je Gespräch (2 Mails + Gespräch = 1 Eintrag)")
        check(((try? store.search("Migration"))?.first?.matches ?? 0) >= 2, "Suche: Trefferzahl je Gespräch")
        check(subjects("Server Festpreis").count == 1 && subjects("Server Herbstrabatt").isEmpty, "Suche: mehrere Wörter müssen alle vorkommen")
        check(subjects("\"Migration Ihrer Server\"").count == 1 && subjects("\"Server Ihrer Migration\"").isEmpty, "Suche: Phrase")
        check(subjects("falschen Betrag").contains("Ärger mit der Rechnung"), "Suche: findet Text im Mailtext")
        check(subjects("kunde.example").contains("Ärger mit der Rechnung") || subjects("bernd").contains("Ärger mit der Rechnung"), "Suche: findet Absender")
        check(subjects("gibtesnicht").isEmpty, "Suche: kein Treffer")
        // Neuer Stand wird gefunden, alter nicht mehr
        try store.saveAnalysis(of: "s4", threadKey: "s4", category: "Info", priority: .normal, summary: "Wochenendaktion Kaffeemaschine")
        check(subjects("Kaffeemaschine").count == 1, "Suche: neue Zusammenfassung ist sofort suchbar")
        // Gespräche: Zusammenfassung durchsuchbar, Upsert verwaist den Index nicht
        var t = FeatureSelfTest.thread("s1", status: .waiting)
        t.subject = "Angebot Server-Migration"; t.summary = "Wartet auf Zusage zur Rechenzentrumsverlagerung"
        try store.upsert(t)
        let count1 = store.searchIndexCount()
        t.summary = "Zusage liegt vor, Termin im Dezember"
        try store.upsert(t)
        try store.upsert(t)
        check(store.searchIndexCount() == count1, "Suche: wiederholtes Speichern eines Gesprächs lässt keine Altlasten im Index")
        check(subjects("Rechenzentrumsverlagerung").isEmpty && subjects("Dezember").count == 1, "Suche: geänderte Gesprächs-Zusammenfassung ersetzt die alte")
        // Neuaufbau liefert dasselbe
        try store.rebuildSearchIndex()
        check(subjects("Dezember").count == 1 && subjects("arger").count == 1, "Suche: Neuaufbau des Index")
        // Vertrauliche Mails: kein Text im Index
        try store.markPrivate("s2", threadKey: "s2", keepBody: false, category: nil, priority: nil, decidedBy: nil)
        check(subjects("falschen Betrag").isEmpty && subjects("arger").count == 1, "Suche: vertrauliche Mails sind nur über Betreff/Absender auffindbar, nicht über den Text")
    }

    // MARK: Antwortstil

    static func styleTests(_ tmp: URL) throws {
        let quoted = "Hallo Anna,\n\nich schicke dir das Angebot bis Freitag.\n\nBeste Grüße\nThorsten\n\nAm 20.10.2026 um 09:15 schrieb Anna <anna@firma.example>:\n> Kannst du mir das Angebot schicken?\n> Danke"
        check(StyleLearner.cleanBody(quoted) == "Hallo Anna,\n\nich schicke dir das Angebot bis Freitag.\n\nBeste Grüße\nThorsten", "Stil: zitierter Verlauf (deutsch) wird abgeschnitten")
        check(StyleLearner.cleanBody("Thanks!\n\nOn Mon, Oct 20, 2026 at 9:15 AM Bob <b@x.com> wrote:\n> hi") == "Thanks!", "Stil: zitierter Verlauf (englisch)")
        check(StyleLearner.cleanBody("Zusage.\n\n-----Ursprüngliche Nachricht-----\nVon: x\nAn: y") == "Zusage." && StyleLearner.cleanBody("OK\n\nVon: Anna\nGesendet: Montag\nAn: Ich") == "OK", "Stil: Outlook-Köpfe und Weiterleitungen")
        check(StyleLearner.cleanBody("Zeile 1\n> zitiert\nZeile 2") == "Zeile 1\nZeile 2", "Stil: >-Zeilen fallen weg")
        let good = "Hallo Anna,\n\nich schicke dir das Angebot bis Freitag. Melde dich, falls etwas fehlt.\n\nBeste Grüße\nThorsten"
        check(StyleLearner.isUsable(good) && !StyleLearner.isUsable("Ok") && !StyleLearner.isUsable(String(repeating: "Wort ", count: 400)), "Stil: Länge der Proben (40–1500 Zeichen)")
        check(!StyleLearner.isUsable("Automatische Antwort: Ich bin bis zum 3.11. nicht im Büro und lese keine Mails. Dringende Fälle bitte an das Sekretariat.")
              && !StyleLearner.isUsable("https://a.example/x https://b.example/y https://c.example/z https://d.example/q kurz"), "Stil: Abwesenheitsnotizen und Link-Listen sind keine Proben")
        var sent: [StoredMessage] = []
        for i in 0..<6 {
            var m = RulesSelfTest.msg("s\(i)", from: "ich@example.org", subject: "Betreff \(i)", body: good, mine: true)
            m.recipients = ["anna@firma.example"]
            sent.append(m)
        }
        var other = RulesSelfTest.msg("o1", from: "ich@example.org", subject: "Anderes", body: good + " Danke!", mine: true)
        other.recipients = ["bernd@kunde.example"]
        var priv = other; priv.isPrivate = true; priv.messageId = "p1"
        sent.append(other); sent.append(priv)
        let samples = StyleLearner.samples(from: sent)
        check(samples.filter { $0.recipient == "anna@firma.example" }.count == 3 && samples.contains { $0.recipient == "bernd@kunde.example" } && samples.count == 4,
              "Stil: höchstens 3 Proben je Empfänger, vertrauliche Mails nie")
        check(!samples.contains { $0.body.contains("schrieb") }, "Stil: Proben enthalten keine Zitate")
        let store = try Store(path: tmp.appendingPathComponent("style.sqlite"))
        try store.insert(raw("e1", subject: "Angebot", from: "Ich <ich@example.org>", body: good + "\n\nAm 1.1.2026 schrieb Anna:\n> alt", account: "iCloud", sent: true, to: ["Anna <anna@firma.example>"]), myAddresses: ["ich@example.org"])
        try store.insert(raw("e2", subject: "Kurz", from: "Ich <ich@example.org>", body: "ok", account: "iCloud", sent: true, to: ["anna@firma.example"]), myAddresses: ["ich@example.org"])
        let ex = store.sentExamples(toEmail: "anna@firma.example")
        check(ex.count == 1 && ex[0].hasPrefix("Hallo Anna") && !ex[0].contains("schrieb") && store.sentExamples(toEmail: "niemand@x.de").isEmpty, "Stil: Beispiele früherer Mails an dieselbe Person, bereinigt")
        try store.insertStyleOnly(raw("h1", subject: "Alt", from: "Ich <ich@example.org>", body: good, account: "iCloud", sent: true, to: ["x@y.de"]), myAddresses: [])
        try store.insertStyleOnly(raw("h1", subject: "Alt", from: "Ich <ich@example.org>", body: good, account: "iCloud", sent: true, to: ["x@y.de"]), myAddresses: [])
        let h = try store.message(id: "h1")
        let queued = try store.unprocessedMessages(limit: 50, accounts: ["iCloud"]).contains { $0.messageId == "h1" }
        check(h?.processed == false && !queued && store.hasMessage("h1"),
              "Stil: Sendeverlauf wird nur archiviert – nie analysiert, nie doppelt")
        check(ClaudeClient.styleSection("").isEmpty && ClaudeClient.styleSection("  ").isEmpty, "Stil: ohne Leitfaden kein Abschnitt")
        let sec = ClaudeClient.styleSection("Du-Anrede, kurz.", examples: ["Hi Anna, passt."])
        check(sec.contains("Du-Anrede, kurz.") && sec.contains("--- Beispiel 1 ---") && sec.contains("Hi Anna, passt."), "Stil: Leitfaden und Beispiele im Prompt")
    }

    // MARK: Wochenbericht

    static func weeklyTests(_ tmp: URL) throws {
        let now = Date()
        func h(_ hours: Double) -> Date { now.addingTimeInterval(-hours * 3600) }
        let rows: [(thread: String, date: Date, mine: Bool)] = [
            ("a", h(30), false), ("a", h(26), true),          // 4 h
            ("b", h(20), false), ("b", h(8), true),           // 12 h
            ("c", h(10), false),                               // unbeantwortet
            ("d", h(100), false), ("d", h(90), true),         // außerhalb der Woche
        ]
        let m = Weekly.medianReplyHours(rows, from: now.addingTimeInterval(-7 * 86400), to: now)
        check(m.samples == 3 && m.hours == 10, "Wochenbericht: Median der Antwortzeit (4, 12 und 10 Stunden → 10)")
        check(Weekly.medianReplyHours([("x", h(5), false)], from: h(24), to: now).hours == nil, "Wochenbericht: ohne Antworten keine Antwortzeit")

        let store = try Store(path: tmp.appendingPathComponent("weekly.sqlite"))
        func add(_ id: String, daysAgo: Double, mine: Bool = false, category: String? = nil, from: String = "A <a@b.de>", thread: String? = nil) throws {
            try store.insert(raw(id, subject: "S \(id)", from: mine ? "Ich <ich@example.org>" : from, account: "iCloud", sent: mine, date: Date().addingTimeInterval(-daysAgo * 86400)), myAddresses: ["ich@example.org"])
            try store.saveAnalysis(of: id, threadKey: thread ?? id, category: mine ? nil : category, priority: .normal, summary: nil)
        }
        try add("w1", daysAgo: 1, category: "Newsletter"); try add("w2", daysAgo: 2, category: "Newsletter"); try add("w3", daysAgo: 3, category: "Rechnungen")
        try add("w4", daysAgo: 9, category: "Newsletter"); try add("w5", daysAgo: 12, category: "Rechnungen"); try add("w6", daysAgo: 13, category: "Rechnungen")
        try add("w7", daysAgo: 1.5, mine: true); try add("w8", daysAgo: 10, mine: true); try add("w9", daysAgo: 10.5, mine: true)
        var late = FeatureSelfTest.thread("late", status: .needsReply, lastFromMe: false, daysAgo: 6)
        var priv = FeatureSelfTest.thread("secret", status: .needsReply, lastFromMe: false, daysAgo: 8); priv.isPrivate = true
        let snoozed = FeatureSelfTest.thread("zzz", status: .needsReply, lastFromMe: false, daysAgo: 7, snoozed: Date().addingTimeInterval(86400))
        let waiting = FeatureSelfTest.thread("wait", status: .waiting, lastFromMe: true, daysAgo: 5)
        late.subject = "Offene Frage"
        let stats = Weekly.compute(store: store, accounts: ["iCloud"], threads: [late, priv, snoozed, waiting], invoices: [FeatureSelfTest.invoice("i1", due: "2020-01-01")])
        check(stats.received == 3 && stats.receivedPrevious == 3 && stats.sent == 1 && stats.sentPrevious == 2, "Wochenbericht: Zahlen dieser und der Vorwoche")
        check(stats.categories.first?.name == "Newsletter" && stats.categories.first?.delta == 1 && stats.categories.last?.name == "Rechnungen" && stats.categories.last?.delta == -1,
              "Wochenbericht: Kategorien nach Wachstum sortiert")
        check(stats.lateReplies.map(\.threadKey) == ["late"] && stats.overdueWaiting.map(\.threadKey) == ["wait"], "Wochenbericht: säumig – ohne vertrauliche und zurückgestellte Gespräche")
        check(stats.openNeedsReply == 1 && stats.snoozed == 1 && stats.invoicesOverdue == 1, "Wochenbericht: offene, zurückgestellte Gespräche, überfällige Rechnungen")
        let text = Weekly.promptText(stats)
        check(text.contains("Offene Frage") && !text.contains("secret") && text.contains("Newsletter 2/1"), "Wochenbericht: Prompt ohne vertrauliche Gespräche")
        check(WeeklyView.hours(0.5) == "30 Min." && WeeklyView.hours(5.4) == "5,4 Std." && WeeklyView.hours(60) == "2,5 Tage" && WeeklyView.deltaText(3) == "+3" && WeeklyView.deltaText(-2) == "−2" && WeeklyView.deltaText(0) == "±0",
              "Wochenbericht: Anzeige von Zeiten und Veränderungen")
        try store.saveReport(text: "## Überblick\nAlles gut.", stats: stats)
        let back = store.latestReport()
        check(back?.text.hasPrefix("## Überblick") == true && back?.stats.received == 3 && back?.stats.lateReplies.count == 1, "Wochenbericht: speichern und laden")
    }

    // MARK: Newsletter

    static func newsletterTests(_ tmp: URL) throws {
        let hdr = "<mailto:unsub@news.example?subject=unsubscribe>, <https://news.example/u/abc>"
        check(UnsubOption.parse(header: hdr, post: "List-Unsubscribe=One-Click") == UnsubOption(method: .oneClick, target: "https://news.example/u/abc"), "Newsletter: Ein-Klick-Abmeldung (RFC 8058)")
        check(UnsubOption.parse(header: hdr, post: nil) == UnsubOption(method: .link, target: "https://news.example/u/abc"), "Newsletter: Link, wenn kein Ein-Klick angeboten wird")
        check(UnsubOption.parse(header: "<mailto:unsub@news.example?subject=bye>", post: nil).method == .mailto, "Newsletter: nur E-Mail")
        check(UnsubOption.parse(header: "<http://news.example/u>", post: nil).method == .none && UnsubOption.parse(header: nil, post: nil).method == .none, "Newsletter: http und fehlender Header werden abgelehnt")
        for bad in ["https://192.168.1.1/admin", "https://localhost/u", "https://printer.local/u", "https://[::1]/u", "https://user:pw@news.example/u", "https://intranet/u", "https://10.0.0.5/x", "https://nas.lan/x"] {
            check(UnsubOption.parse(header: "<\(bad)>", post: "List-Unsubscribe=One-Click").method == .none, "Newsletter: unsicheres Ziel abgelehnt (\(bad))")
        }
        let mt = UnsubOption.parseMailto("mailto:unsub@news.example?subject=Abmelden%20bitte&body=stop")
        check(mt?.address == "unsub@news.example" && mt?.subject == "Abmelden bitte" && mt?.body == "stop" && UnsubOption.parseMailto("mailto:unsub@x.de")?.subject == "unsubscribe" && UnsubOption.parseMailto("https://x.de") == nil,
              "Newsletter: mailto mit Betreff und Text")
        check(Newsletter.isCandidate(total: 5, known: 5, read: 0) && Newsletter.isCandidate(total: 12, known: 12, read: 1) && !Newsletter.isCandidate(total: 12, known: 12, read: 2)
              && !Newsletter.isCandidate(total: 3, known: 3, read: 0) && !Newsletter.isCandidate(total: 8, known: 3, read: 0), "Newsletter: Schwellen (≥4 Mails, ≤10 % gelesen, Lesestatus bekannt)")

        let store = try Store(path: tmp.appendingPathComponent("news.sqlite"))
        func news(_ id: String, from: String, read: Bool?, daysAgo: Double, unsub: String? = nil) throws {
            var r = raw(id, subject: "Angebot \(id)", from: from, date: Date().addingTimeInterval(-daysAgo * 86400))
            r.read = read
            r.unsubscribe = unsub
            r.unsubscribePost = unsub == nil ? nil : "List-Unsubscribe=One-Click"
            try store.insert(r, myAddresses: [])
            try store.saveAnalysis(of: id, threadKey: id, category: "Newsletter", priority: .low, summary: nil)
        }
        for i in 0..<5 { try news("n\(i)", from: "Shop <news@shop.example>", read: false, daysAgo: Double(i * 10 + 1), unsub: i == 0 ? hdr : nil) }
        for i in 0..<5 { try news("r\(i)", from: "Blog <hi@blog.example>", read: i < 3, daysAgo: Double(i * 10 + 2)) }
        for i in 0..<5 { try news("u\(i)", from: "Neu <x@neu.example>", read: nil, daysAgo: Double(i + 1)) }
        let stats = try store.newsletterStats(category: "Newsletter", accounts: ["iCloud"], since: Date().addingTimeInterval(-90 * 86400))
        func c(_ e: String) -> NewsletterCandidate? { stats.first { $0.email == e } }
        check(c("news@shop.example")?.total == 5 && c("news@shop.example")?.read == 0 && Newsletter.isCandidate(total: 5, known: c("news@shop.example")!.known, read: 0), "Newsletter: Absender, der nie öffnet, ist Kandidat")
        check(!Newsletter.isCandidate(total: c("hi@blog.example")!.total, known: c("hi@blog.example")!.known, read: c("hi@blog.example")!.read), "Newsletter: gelesener Absender ist kein Kandidat")
        check(c("x@neu.example")?.known == 0 && !Newsletter.isCandidate(total: 5, known: 0, read: 0), "Newsletter: unbekannter Lesestatus → kein Vorschlag")
        try store.setRead(true, messageId: "n0")
        try store.setRead(true, messageId: "n1")
        let after = try store.newsletterStats(category: "Newsletter", accounts: ["iCloud"], since: Date().addingTimeInterval(-90 * 86400)).first { $0.email == "news@shop.example" }
        check(after?.read == 2 && !Newsletter.isCandidate(total: 5, known: 5, read: 2), "Newsletter: Lesestatus-Abgleich verändert den Vorschlag")
        check(store.latestUnsubHeader(email: "news@shop.example")?.header == hdr && store.latestUnsubHeader(email: "hi@blog.example") == nil, "Newsletter: Abmelde-Header wird mitgespeichert")
        try store.saveUnsub("news@shop.example", name: "Shop", option: UnsubOption(method: .oneClick, target: "https://news.example/u/abc"))
        var rec = store.unsubRecord("news@shop.example")
        check(rec?.status == "open" && rec?.option?.method == .oneClick, "Newsletter: Methode wird gemerkt")
        try store.saveUnsub("news@shop.example", name: "Shop", status: "done", done: Date())
        rec = store.unsubRecord("news@shop.example")
        check(rec?.status == "done" && rec?.option?.target == "https://news.example/u/abc" && rec?.done != nil && store.unsubEmails(status: "done") == ["news@shop.example"], "Newsletter: abbestellt – Methode und Datum bleiben")
        check(store.iEverWroteTo("news@shop.example") == false && store.messagesSince(from: "hi@blog.example", since: Date().addingTimeInterval(-86400 * 3)) == 1, "Newsletter: Hilfsabfragen")
    }

    // MARK: Flaggen

    static func flagTests(_ tmp: URL) throws {
        let e = ActivityEntry(id: 1, date: Date(), messageId: "m", subject: "S", kind: "flag", detail: "Rot", account: "iCloud", fromMailbox: nil, toMailbox: nil,
                              dryRun: false, undone: false, extra: ActivityEntry.flagExtra(flagged: false, index: -1))
        check(e.canUndoFlag && e.canUndo && e.previousFlag?.flagged == false && e.previousFlag?.index == -1, "Flaggen: früherer Zustand wird gelesen")
        var old = e; old.extra = nil
        var done = e; done.undone = true
        var dry = e; dry.dryRun = true
        check(!old.canUndoFlag && !done.canUndoFlag && !dry.canUndoFlag, "Flaggen: ohne bekannten Zustand, erledigt oder Probelauf kein Rückgängig")
        let was = ActivityEntry.flagExtra(flagged: true, index: 3)
        var e2 = e; e2.extra = was
        check(e2.previousFlag?.flagged == true && e2.previousFlag?.index == 3, "Flaggen: bereits markierte Mail behält ihre Farbe")
        let store = try Store(path: tmp.appendingPathComponent("flag.sqlite"))
        try store.insert(raw("f1", account: "iCloud"), myAddresses: [])
        let m = try store.message(id: "f1")!
        store.log(m, kind: "flag", detail: "Rot markiert", dryRun: false, extra: ActivityEntry.flagExtra(flagged: false, index: -1))
        store.log(m, kind: "flag", detail: "Rot markiert", dryRun: false)
        let list = try store.activity()
        check(list.count == 2 && list.filter(\.canUndoFlag).count == 1, "Flaggen: Zustand wird im Protokoll gespeichert, ältere Einträge bleiben ohne Rückgängig")
    }

    // MARK: Sicherung und Export

    static func backupTests(_ tmp: URL) throws {
        let support = tmp.appendingPathComponent("support", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let dbURL = support.appendingPathComponent("mailpilot.sqlite")
        var store: Store? = try Store(path: dbURL)
        try store!.insert(raw("b1", subject: "Wichtig", body: "Inhalt"), myAddresses: [])
        try store!.saveAnalysis(of: "b1", threadKey: "b1", category: "Info", priority: .normal, summary: "Zusammenfassung")
        let b1 = try Backups.create(store: store!, at: Backups.folder(in: support).appendingPathComponent("mailpilot-2026-01-01-0800.sqlite"))
        let keep = tmp.appendingPathComponent("keep-b1.sqlite")
        try FileManager.default.copyItem(at: b1, to: keep)
        check(FileManager.default.fileExists(atPath: b1.path) && Backups.validate(b1) == nil, "Sicherung: Schnappschuss wird erstellt und ist gültig")
        let perms = (try FileManager.default.attributesOfItem(atPath: b1.path)[.posixPermissions] as? Int) ?? 0
        check(perms & 0o077 == 0, "Sicherung: nur für den Besitzer lesbar")
        let copy = try Store(path: b1)
        check(try copy.message(id: "b1")?.summary == "Zusammenfassung" && copy.searchIndexCount() > 0, "Sicherung: enthält die Daten (auch den Suchindex)")
        let junk = tmp.appendingPathComponent("junk.sqlite")
        try Data("kein sqlite".utf8).write(to: junk)
        check(Backups.validate(junk) != nil, "Sicherung: beschädigte Datei wird abgelehnt")
        let other = tmp.appendingPathComponent("other.sqlite")
        let odb = try Database(path: other.path)
        try odb.exec("CREATE TABLE x (a TEXT)")
        check(Backups.validate(other)?.contains("keine MailPilot-Sicherung") == true, "Sicherung: fremde Datenbank wird abgelehnt")
        // Aufbewahrung
        for d in ["02", "03", "04"] {
            let u = Backups.folder(in: support).appendingPathComponent("mailpilot-2026-01-\(d)-0800.sqlite")
            try Data("x".utf8).write(to: u)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(Double(Int(d)!) * 3600)], ofItemAtPath: u.path)
        }
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(3600)], ofItemAtPath: b1.path)
        Backups.prune(keep: 2, in: support)
        let left = Backups.list(in: support)
        check(left.count == 2 && left[0].url.lastPathComponent.contains("01-04") && left[1].url.lastPathComponent.contains("01-03"), "Sicherung: nur die jüngsten bleiben")
        // Wiederherstellung
        try store!.insert(raw("b2", subject: "Neu nach Sicherung"), myAddresses: [])
        store = nil
        try Backups.stageRestore(from: keep, in: support)
        check(Backups.applyPendingRestore(in: support), "Wiederherstellung: wird beim Start eingespielt")
        let restored = try Store(path: dbURL)
        check(try restored.message(id: "b1") != nil && (try restored.message(id: "b2")) == nil, "Wiederherstellung: Stand der Sicherung ist zurück")
        let safety = (try FileManager.default.contentsOfDirectory(at: Backups.folder(in: support), includingPropertiesForKeys: nil)).filter { $0.lastPathComponent.hasPrefix("vor-wiederherstellung-") && $0.pathExtension == "sqlite" }
        let safetyHasB2 = try safety.first.map { try Store(path: $0).message(id: "b2") != nil } ?? false
        check(safety.count == 1 && safetyHasB2, "Wiederherstellung: bisheriger Stand bleibt als Sicherheitskopie erhalten")
        check(!Backups.applyPendingRestore(in: support), "Wiederherstellung: ohne wartende Datei passiert nichts")
    }

    static func exportTests(_ tmp: URL) throws {
        let store = try Store(path: tmp.appendingPathComponent("export.sqlite"))
        try store.insert(raw("x1", subject: "Offen", from: "A <a@b.de>", body: "geheimer Text"), myAddresses: [])
        try store.saveAnalysis(of: "x1", threadKey: "x1", category: "Info", priority: .normal, summary: "Zusammenfassung")
        try store.insert(raw("x2", subject: "Privat", from: "P <p@kanzlei.example>", body: "streng vertraulich"), myAddresses: [])
        try store.markPrivate("x2", threadKey: "x2", keepBody: true, category: nil, priority: nil, decidedBy: nil)
        var t1 = FeatureSelfTest.thread("x1", status: .needsReply, lastFromMe: false, due: "2026-11-15"); t1.subject = "Offen; mit \"Zeichen\""
        var t2 = FeatureSelfTest.thread("x2", status: .info, lastFromMe: false); t2.isPrivate = true
        try store.upsert(t1); try store.upsert(t2)
        var s = AppSettings(); s.vips = [VIPEntry(name: "Chef", match: "chef@firma.example")]
        func parse(_ d: Data) -> [String: Any] { (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:] }
        let plain = parse(try DataExport.json(store: store, accounts: ["iCloud"], settings: s, includeBodies: false))
        let msgs = plain["messages"] as? [[String: Any]] ?? []
        check(msgs.count == 2 && !msgs.contains { $0["body"] != nil } && (plain["threads"] as? [[String: Any]])?.count == 2, "Export: ohne Mailtexte (Standard)")
        let full = parse(try DataExport.json(store: store, accounts: ["iCloud"], settings: s, includeBodies: true))
        let fm = full["messages"] as? [[String: Any]] ?? []
        check(fm.first { $0["messageId"] as? String == "x1" }?["body"] as? String == "geheimer Text" && fm.first { $0["messageId"] as? String == "x2" }?["body"] == nil,
              "Export: Mailtexte nur auf Wunsch – vertrauliche Mails nie")
        check(((plain["settings"] as? [String: Any])?["vips"] as? [[String: Any]])?.count == 1 && plain["app"] as? String == "MailPilot", "Export: Einstellungen und Kopf")
        let other = parse(try DataExport.json(store: store, accounts: ["Google"], settings: s, includeBodies: true))
        check((other["messages"] as? [Any])?.isEmpty == true && (other["threads"] as? [Any])?.isEmpty == true, "Export: nur aktivierte Konten")
        let csv = DataExport.threadsCSV([t1, t2])
        let lines = csv.components(separatedBy: "\r\n")
        check(csv.hasPrefix("\u{FEFF}Betreff;Gegenüber;Status") && lines.count == 3 && lines[1].contains("\"Offen; mit \"\"Zeichen\"\"\"") && lines[1].contains(";15.11.2026;") && !csv.contains("Privat"),
              "Export: Gespräche als CSV – maskiert, ohne vertrauliche Gespräche")
    }
}

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
            try prefilterTests(tmp)
            try latestTests(tmp)
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

    // MARK: Vorfilter

    static func prefilterTests(_ tmp: URL) throws {
        let st = AppSettings()
        func m(from: String = "Shop <news@shop.example>", subject: String = "Unsere Herbst-Angebote", flags: String = "", unsub: String? = nil, mine: Bool = false) -> StoredMessage {
            var x = RulesSelfTest.msg("p", from: from.contains("<") ? MailAddress.parse(from).email : from, subject: subject, mine: mine)
            x.hdrFlags = flags
            x.unsub = unsub
            return x
        }
        func v(_ x: StoredMessage, settings: AppSettings = AppSettings(), history: [(category: String, n: Int)] = [], corrected: Bool = false, vip: Bool = false) -> Prefilter.Verdict? {
            Prefilter.verdict(for: x, settings: settings, history: history, hasCorrections: corrected, isVIP: vip)
        }
        check(v(m(flags: "auto"))?.category == "Benachrichtigungen", "Vorfilter: Auto-Submitted → Benachrichtigungen")
        check(v(m(flags: "bulk list", unsub: "<https://x>"))?.category == "Newsletter" && v(m(unsub: "<https://x>"))?.category == "Newsletter", "Vorfilter: Abmelde-Link → Newsletter")
        check(v(m(from: "noreply@dienst.example", subject: "Ihr Login"))?.category == "Benachrichtigungen" && v(m(from: "anna@firma.example", subject: "Hallo")) == nil, "Vorfilter: noreply-Absender, normale Absender bleiben Claude")
        check(v(m(subject: "Ihre Rechnung Nr. 4711", unsub: "<https://x>")) == nil && v(m(subject: "Terminbestätigung", flags: "auto")) == nil && v(m(subject: "Bestellung 123 versendet", unsub: "<https://x>")) == nil,
              "Vorfilter: Rechnungen, Termine und Bestellungen gehen immer an Claude")
        check(v(m(flags: "auto"), vip: true) == nil && v(m(flags: "auto"), corrected: true) == nil && v(m(flags: "auto", mine: true)) == nil, "Vorfilter: VIP, korrigierte Absender und gesendete Mails gehen an Claude")
        var priv = m(flags: "auto"); priv.isPrivate = true
        var off = AppSettings(); off.prefilterEnabled = false
        var noCat = AppSettings(); noCat.categories = noCat.categories.filter { $0.name != "Newsletter" && $0.name != "Benachrichtigungen" }
        check(v(priv) == nil && v(m(flags: "auto"), settings: off) == nil && v(m(unsub: "<https://x>"), settings: noCat) == nil, "Vorfilter: vertraulich, abgeschaltet oder Kategorie fehlt → Claude")
        check(v(m(), history: [("Newsletter", 5)])?.source == "Absender-Gedächtnis" && v(m(), history: [("Werbung", 3)])?.category == "Werbung", "Vorfilter: Absender-Gedächtnis (≥3 Mails, ≥90 %)")
        check(v(m(), history: [("Newsletter", 3), ("Info", 1)]) == nil && v(m(), history: [("Newsletter", 2)]) == nil && v(m(), history: [("Rechnungen", 9)]) == nil && v(m(), history: [("Handlung nötig", 9)]) == nil,
              "Vorfilter: gemischte, zu wenige oder wichtige Kategorien → Claude")
        check(v(m(subject: "Rechnung"), history: [("Newsletter", 9)]) == nil, "Vorfilter: Absender-Gedächtnis ignoriert Rechnungs-Betreffs")
        let a = Prefilter.analysis(for: m(subject: "Herbst-Angebote"), Prefilter.Verdict(category: "Newsletter", reason: "Test", source: "Vorfilter"))
        check(a.category == "Newsletter" && a.priority == .low && !a.needs_reply && a.thread_status == .info && a.summary == "Herbst-Angebote" && a.reply_draft == nil, "Vorfilter: lokale Analyse ohne Entwurf, niedrige Priorität")

        // Header-Kennzeichen und Verlauf im Speicher
        let store = try Store(path: tmp.appendingPathComponent("prefilter.sqlite"))
        func add(_ id: String, from: String, decided: String, category: String, flags: String? = nil, unsub: String? = nil) throws {
            var r = raw(id, subject: "Mail \(id)", from: from)
            r.headerFlags = flags
            r.unsubscribe = unsub
            try store.insert(r, myAddresses: [])
            try store.saveAnalysis(of: id, threadKey: id, category: category, priority: .low, summary: nil, decidedBy: decided)
        }
        try add("h1", from: "S <news@shop.example>", decided: "Claude", category: "Newsletter", flags: "bulk list", unsub: "<https://x>")
        try add("h2", from: "S <news@shop.example>", decided: "Claude", category: "Newsletter")
        try add("h3", from: "S <news@shop.example>", decided: "Vorfilter", category: "Newsletter")
        try add("h4", from: "S <news@shop.example>", decided: "Korrektur", category: "Werbung")
        try add("h5", from: "X <x@other.example>", decided: "Claude", category: "Info")
        let back = try store.message(id: "h1")
        let h2 = try store.message(id: "h2")
        check(back?.hdrFlags == "bulk list" && back?.unsub == "<https://x>" && h2?.hdrFlags == "", "Vorfilter: Header-Kennzeichen werden gespeichert")
        let hist = Dictionary(uniqueKeysWithValues: store.senderHistory(email: "news@shop.example", excluding: "h2").map { ($0.category, $0.n) })
        check(hist == ["Newsletter": 1, "Werbung": 1], "Vorfilter: Verlauf zählt nur Claude und Nutzer, nicht den Vorfilter und nicht die Mail selbst")
        try store.saveAnalysis(of: "h3", threadKey: "h3", category: "Newsletter", priority: .low, summary: nil, decidedBy: "Vorfilter")
        try store.saveAnalysis(of: "h5", threadKey: "h5", category: "Info", priority: .low, summary: nil, decidedBy: "Absender-Gedächtnis")
        check(store.locallyClassifiedCount(since: Date().addingTimeInterval(-86400)) == 2 && store.classifiedCount(since: Date().addingTimeInterval(-86400)) == 5, "Vorfilter: Zähler für die Nutzungsansicht")

        // Regeln aus älteren Versionen bleiben lesbar
        let oldRule = #"[{"id":"8D1B2E0A-0000-4000-8000-000000000001","name":"Alt","enabled":true,"matchAll":true,"conditions":[],"keepInInbox":false,"learned":false}]"#
        let rules = try JSONDecoder().decode([UserRule].self, from: Data(oldRule.utf8))
        check(rules.count == 1 && rules[0].name == "Alt" && !rules[0].skipClaude, "Regeln: ältere Dateien ohne neue Felder bleiben lesbar")
        let s2 = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"pollMinutes": 5}"#.utf8))
        check(s2.prefilterEnabled && s2.modelBulk == "haiku" && s2.initialScanDays == 180 && s2.probeMoveAccounts.isEmpty, "Einstellungen: neue Felder haben sichere Standardwerte")
    }

    // MARK: Einladungen, freie Zeiten, Kontakte, Mitteilungen

    static func latestTests(_ tmp: URL) throws {
        let utc = TimeZone(identifier: "UTC")!
        func iso(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ tz: TimeZone) -> Date {
            var c = Calendar(identifier: .gregorian); c.timeZone = tz
            return c.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
        }
        let ics = "BEGIN:VCALENDAR\r\nMETHOD:REQUEST\r\nBEGIN:VEVENT\r\nUID:abc-123@example.com\r\nSUMMARY:Projekt-Kickoff\\, intern\r\n"
            + "DTSTART;TZID=W. Europe Standard Time:20261104T100000\r\nDTEND;TZID=W. Europe Standard Time:20261104T113000\r\n"
            + "LOCATION:Raum 2\\; Trier\r\nORGANIZER;CN=\"Anna Weber\":mailto:anna@firma.example\r\nDESCRIPTION:Zeile 1\\nZeile\r\n  2\r\nRRULE:FREQ=WEEKLY\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"
        let e = ICSParser.parse(ics)
        check(e.count == 1 && e[0].uid == "abc-123@example.com" && e[0].summary == "Projekt-Kickoff, intern" && e[0].location == "Raum 2; Trier", "ICS: Titel und Ort (Maskierung)")
        check(e.first?.start == iso(2026, 11, 4, 10, 0, TimeZone(identifier: "Europe/Berlin")!) && e.first?.end == iso(2026, 11, 4, 11, 30, TimeZone(identifier: "Europe/Berlin")!), "ICS: Outlook-Zeitzone „W. Europe Standard Time“")
        check(e.first?.organizer == "Anna Weber" && e.first?.recurring == true && e.first?.cancelled == false && e.first?.method == "REQUEST" && e.first?.notes.contains("Zeile 1\nZeile 2") == true, "ICS: Organisator, Serie, Beschreibung mit Zeilenfortsetzung")
        let u = ICSParser.parse("BEGIN:VCALENDAR\nBEGIN:VEVENT\nUID:u1\nSUMMARY:UTC\nDTSTART:20261104T093000Z\nDURATION:PT45M\nEND:VEVENT\nEND:VCALENDAR")
        check(u.first?.start == iso(2026, 11, 4, 9, 30, utc) && u.first?.end == iso(2026, 11, 4, 10, 15, utc), "ICS: UTC-Zeit und Dauer")
        let d = ICSParser.parse("BEGIN:VCALENDAR\nBEGIN:VEVENT\nUID:u2\nSUMMARY:Tag\nDTSTART;VALUE=DATE:20261105\nEND:VEVENT\nEND:VCALENDAR")
        check(d.first?.allDay == true && d.first.map { $0.end.timeIntervalSince($0.start) } == 86400, "ICS: ganztägiger Termin ohne Ende dauert einen Tag")
        let c = ICSParser.parse("BEGIN:VCALENDAR\nMETHOD:CANCEL\nBEGIN:VEVENT\nUID:u3\nSUMMARY:Absage\nDTSTART:20261104T093000Z\nSTATUS:CANCELLED\nEND:VEVENT\nEND:VCALENDAR")
        check(c.first?.cancelled == true && ICSParser.parse("kein kalender").isEmpty && ICSParser.parse("BEGIN:VEVENT\nSUMMARY:x\nEND:VEVENT").isEmpty, "ICS: Absagen; Unbrauchbares wird ignoriert")
        check(ICSParser.parseDuration("PT1H30M") == 5400 && ICSParser.parseDuration("P1D") == 86400 && ICSParser.parseDuration("P1W") == 604800 && ICSParser.parseDuration("x") == nil, "ICS: Dauer")
        check(ICSParser.timeZone("Europe/Paris").identifier == "Europe/Paris" && ICSParser.timeZone("Romance Standard Time").identifier == "Europe/Paris" && ICSParser.timeZone("Gibt es nicht") == .current, "ICS: Zeitzonen (IANA, Windows, unbekannt)")

        let store = try Store(path: tmp.appendingPathComponent("invites.sqlite"))
        try store.insert(raw("i1", subject: "Einladung: Projekt-Kickoff", from: "Anna <anna@firma.example>"), myAddresses: [])
        try store.saveAnalysis(of: "i1", threadKey: "i1", category: "Info", priority: .normal, summary: nil)
        try store.insert(raw("i2", subject: "Hallo zusammen", from: "B <b@x.de>"), myAddresses: [])
        try store.saveAnalysis(of: "i2", threadKey: "i2", category: "Info", priority: .normal, summary: nil)
        try store.insert(raw("i3", subject: "Zusammenfassung", from: "B <b@x.de>"), myAddresses: [])
        try store.saveAnalysis(of: "i3", threadKey: "i3", category: "Termine", priority: .normal, summary: nil)
        let cand = try store.inviteCandidates(accounts: ["iCloud"], since: Date().addingTimeInterval(-86400), limit: 10).map(\.messageId).sorted()
        check(cand == ["i1", "i3"], "Einladungen: Kandidaten über Betreff oder Kategorie „Termine“")
        try store.markInviteScanned("i1")
        check(try store.inviteCandidates(accounts: ["iCloud"], since: Date().addingTimeInterval(-86400), limit: 10).map(\.messageId) == ["i3"], "Einladungen: bereits durchsuchte Mails werden nicht erneut geprüft")
        try store.saveInvite(e[0], messageId: "i1", account: "iCloud", subject: "Einladung", mailDate: Date())
        var list = try store.invites(accounts: ["iCloud"])
        check(list.count == 1 && list[0].status == "new" && list[0].event.summary == "Projekt-Kickoff, intern" && list[0].event.recurring, "Einladungen: Termin wird gespeichert")
        try store.setInviteStatus(e[0].uid, "added")
        try store.saveInvite(e[0], messageId: "i1", account: "iCloud", subject: "Einladung", mailDate: Date())
        check(try store.invites(accounts: ["iCloud"]).first?.status == "added", "Einladungen: dieselbe Einladung bleibt „eingetragen“")
        var moved = e[0]; moved.start = moved.start.addingTimeInterval(3600); moved.end = moved.end.addingTimeInterval(3600)
        try store.saveInvite(moved, messageId: "i1", account: "iCloud", subject: "Aktualisiert", mailDate: Date())
        list = try store.invites(accounts: ["iCloud"])
        check(list.count == 1 && list[0].status == "new", "Einladungen: verschobener Termin wird wieder „neu“")
        check(try store.invites(accounts: ["Google"]).isEmpty, "Einladungen: nur aktivierte Konten")

        // Freie Zeiten
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let monday = iso(2026, 11, 2, 7, 0, cal.timeZone)               // Montag, 7 Uhr
        func b(_ day: Int, _ h1: Int, _ m1: Int, _ h2: Int, _ m2: Int) -> DateInterval { DateInterval(start: iso(2026, 11, day, h1, m1, cal.timeZone), end: iso(2026, 11, day, h2, m2, cal.timeZone)) }
        var o = FreeSlots.Options(); o.count = 4
        let free = FreeSlots.find(busy: [], from: monday, calendar: cal, options: o)
        check(free.count == 4 && cal.component(.hour, from: free[0].start) == 9 && cal.component(.hour, from: free[1].start) == 13 && free[0].duration == 3600, "Freie Zeiten: ohne Termine vormittags 9 und nachmittags 13 Uhr, je Tag zwei")
        let busy = FreeSlots.find(busy: [b(2, 9, 0, 10, 30), b(2, 13, 0, 17, 0)], from: monday, calendar: cal, options: o)
        check(cal.component(.hour, from: busy[0].start) == 10 && cal.component(.minute, from: busy[0].start) == 30 && cal.isDate(busy[1].start, inSameDayAs: iso(2026, 11, 3, 9, 0, cal.timeZone)),
              "Freie Zeiten: belegte Zeiten werden übersprungen, auf halbe Stunden gerundet")
        let weekend = FreeSlots.find(busy: [], from: iso(2026, 11, 7, 8, 0, cal.timeZone), calendar: cal, options: FreeSlots.Options())      // Samstag
        check(!weekend.isEmpty && weekend.allSatisfy { ![1, 7].contains(cal.component(.weekday, from: $0.start)) } && cal.component(.weekday, from: weekend[0].start) == 2, "Freie Zeiten: nie am Wochenende, ab Samstag der nächste Montag")
        let late = FreeSlots.find(busy: [], from: iso(2026, 11, 2, 15, 10, cal.timeZone), calendar: cal, options: FreeSlots.Options())
        check(late.first.map { $0.start >= iso(2026, 11, 2, 17, 10, cal.timeZone) || !cal.isDate($0.start, inSameDayAs: monday) } == true, "Freie Zeiten: frühestens in zwei Stunden")
        check(FreeSlots.merge([b(2, 9, 0, 10, 0), b(2, 9, 30, 11, 0), b(2, 12, 0, 13, 0)]).count == 2, "Freie Zeiten: überlappende Termine werden vereinigt")
        let text = FreeSlots.describe(DateInterval(start: iso(2026, 11, 3, 10, 0, cal.timeZone), duration: 3600))
        check(text.contains("10:00") && text.contains("11:00") && text.hasSuffix("Uhr"), "Freie Zeiten: Beschreibung (\(text))")
        check(Engine.mentionsScheduling("Können wir einen Termin vereinbaren?") && Engine.mentionsScheduling("Do you have availability next week?") && !Engine.mentionsScheduling("Danke für die Rechnung."),
              "Freie Zeiten: Mail fragt nach einem Termin")
        check(ClaudeClient.slotsSection([]).isEmpty && ClaudeClient.slotsSection(["Dienstag, 4. November, 10:00–11:00 Uhr"]).contains("- Dienstag, 4. November"), "Freie Zeiten: Abschnitt im Prompt")

        // Kontakte
        check(ContactsDirectory.displayName(given: "Anna", family: "Weber", nickname: "", organization: "Firma") == "Anna Weber"
              && ContactsDirectory.displayName(given: "", family: "", nickname: "Chef", organization: "Firma") == "Chef"
              && ContactsDirectory.displayName(given: "", family: "", nickname: "", organization: "Firma GmbH") == "Firma GmbH", "Kontakte: Anzeigename")
        ContactsDirectory.shared.setNames(["anna@firma.example": "Anna Weber"])
        check(ContactsDirectory.shared.name(for: "Anna@Firma.Example") == "Anna Weber" && ContactsDirectory.shared.name(for: "x@y.de") == nil, "Kontakte: Suche ohne Groß-/Kleinschreibung")
        ContactsDirectory.shared.setNames([:])
        let manual = VIPEntry(name: "Chefin", match: "chefin@firma.example")
        let old = VIPEntry(name: "Alt", match: "alt@x.de", fromContacts: true)
        let merged = VIPSync.merge(existing: [manual, old], members: [("Anna Weber", ["anna@firma.example", "anna@privat.example"]), ("Chefin", ["chefin@firma.example"])])
        check(merged.count == 3 && merged.contains { $0.match == "anna@firma.example" && $0.fromContacts } && !merged.contains { $0.match == "alt@x.de" } && merged.filter { $0.match == "chefin@firma.example" }.count == 1,
              "Kontakte: VIP-Abgleich ersetzt nur Einträge aus Kontakten, doppelte werden vermieden")
        let oldVIP = try JSONDecoder().decode([VIPEntry].self, from: Data(#"[{"id":"8D1B2E0A-0000-4000-8000-000000000002","name":"X","match":"x@y.de"}]"#.utf8))
        check(oldVIP.count == 1 && !oldVIP[0].fromContacts, "Kontakte: ältere VIP-Listen bleiben lesbar")

        // Mitteilungen
        check(NotificationAction.parse("REPLY") == .reply && NotificationAction.parse("SNOOZE") == .snooze && NotificationAction.parse("DONE") == .done && NotificationAction.parse("irgendwas") == .open, "Mitteilungen: Knöpfe werden zugeordnet, Antippen öffnet")
        check(NotificationAction.category.actions.map(\.identifier) == ["REPLY", "SNOOZE", "DONE"], "Mitteilungen: drei Knöpfe")
    }
}

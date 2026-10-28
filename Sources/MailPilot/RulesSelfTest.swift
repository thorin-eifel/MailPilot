import Foundation

/// Kommandozeilentests für Regeln, VIP und Lernen (`--selftest-rules`) sowie ein lesender Test der
/// Ordnerabfrage in Apple Mail (`--selftest-sync`). Es werden keine Mails verändert.
enum RulesSelfTest {
    nonisolated(unsafe) static var failures = 0

    static func check(_ ok: Bool, _ name: String) {
        print((ok ? "PASS  " : "FAIL  ") + name)
        if !ok { failures += 1 }
    }

    static func msg(_ id: String, from: String, subject: String = "Hallo", body: String = "",
                    account: String = "iCloud", mailbox: String = "INBOX", mine: Bool = false) -> StoredMessage {
        StoredMessage(messageId: id, mailId: 1, account: account, mailbox: mailbox, subject: subject, sender: "Test <\(from)>",
                      senderEmail: from, recipients: ["ich@example.org"], date: Date(), isFromMe: mine, inReplyTo: nil,
                      references: [], content: body, threadKey: nil, category: nil, priority: nil, summary: nil,
                      processed: true, error: nil, decidedBy: nil)
    }

    static func rule(_ name: String, _ conds: [(RuleField, String)], matchAll: Bool = true, category: String? = nil,
                     priority: Priority? = nil, flag: FlagColor? = nil, folder: String? = nil, keep: Bool = false) -> UserRule {
        var r = UserRule()
        r.name = name
        r.matchAll = matchAll
        r.conditions = conds.map { RuleCondition(field: $0.0, value: $0.1) }
        r.category = category
        r.priority = priority
        r.flag = flag
        r.folder = folder
        r.keepInInbox = keep
        return r
    }

    static func run() {
        var s = AppSettings()

        // Bedingungen
        let pay = rule("PayPal", [(.domain, "paypal.com")], category: "Rechnungen")
        s.rules = [pay]
        check(RuleEngine.evaluate(msg("1", from: "service@paypal.com"), settings: s).category == "Rechnungen", "Domain trifft exakte Domain")
        check(RuleEngine.evaluate(msg("2", from: "x@mail.paypal.com"), settings: s).category == "Rechnungen", "Domain trifft Subdomain")
        check(RuleEngine.evaluate(msg("3", from: "x@notpaypal.com"), settings: s).category == nil, "Domain trifft nicht ähnliche Domain")
        check(RuleEngine.evaluate(msg("4", from: "a@b.de", subject: "Ihre RECHNUNG Nr. 5"), settings: AppSettings.with([rule("S", [(.subject, "rechnung")], category: "Rechnungen")])).category == "Rechnungen", "Betreff-Stichwort ohne Groß-/Kleinschreibung")
        check(RuleEngine.evaluate(msg("5", from: "anna.meier@firma.de"), settings: AppSettings.with([rule("N", [(.sender, "meier")], category: "Persönlich")])).category == "Persönlich", "Absender-Namensteil")
        check(RuleEngine.evaluate(msg("6", from: "a@b.de", body: "Bitte abbestellen"), settings: AppSettings.with([rule("B", [(.body, "abbestellen")], category: "Newsletter")])).category == "Newsletter", "Text-Stichwort")

        let both = rule("Beide", [(.domain, "shop.de"), (.subject, "Bestellung")], category: "Bestellungen")
        let any = rule("Eine", [(.domain, "shop.de"), (.subject, "Bestellung")], matchAll: false, category: "Bestellungen")
        let onlyDomain = msg("7", from: "a@shop.de", subject: "Angebot")
        check(RuleEngine.evaluate(onlyDomain, settings: AppSettings.with([both])).category == nil, "UND: eine Bedingung reicht nicht")
        check(RuleEngine.evaluate(onlyDomain, settings: AppSettings.with([any])).category == "Bestellungen", "ODER: eine Bedingung reicht")

        var off = pay; off.enabled = false
        check(RuleEngine.evaluate(msg("8", from: "a@paypal.com"), settings: AppSettings.with([off])).category == nil, "Deaktivierte Regel wirkt nicht")
        check(RuleEngine.evaluate(msg("9", from: "a@paypal.com"), settings: AppSettings.with([rule("X", [(.domain, "paypal.com")], category: "Gibt es nicht")])).category == nil, "Unbekannte Kategorie wird ignoriert")
        check(RuleEngine.evaluate(msg("10", from: "a@paypal.com"), settings: AppSettings.with([rule("Leer", [(.domain, "  ")], category: "Rechnungen")])).category == nil, "Leere Bedingung trifft nie")
        check(RuleEngine.evaluate(msg("11", from: "a@paypal.com", mine: true), settings: s) == RuleEffect(), "Gesendete Mails bleiben unberührt")

        // Vorrang
        let first = rule("Erste", [(.domain, "x.de")], category: "Newsletter")
        let second = rule("Zweite", [(.domain, "x.de")], category: "Werbung", priority: .low, folder: "Spezial")
        let e = RuleEngine.evaluate(msg("12", from: "a@x.de"), settings: AppSettings.with([first, second]))
        check(e.category == "Newsletter" && e.priority == .low && e.folder == "Spezial", "Erste Regel gewinnt je Feld, spätere füllen Lücken")
        check(e.decidedBy == "Regel: Erste", "Herkunft nennt die erste wirksame Regel")

        // VIP
        var v = AppSettings()
        v.vips = [VIPEntry(name: "Chefin", match: "chefin@firma.de"), VIPEntry(name: "Kunde", match: "@kunde.com")]
        let vip1 = RuleEngine.evaluate(msg("13", from: "Chefin@Firma.de"), settings: v)
        check(vip1.vip && vip1.priority == .high && vip1.flag == .red && vip1.decidedBy == "VIP", "VIP-Adresse (ohne Groß-/Kleinschreibung)")
        check(RuleEngine.evaluate(msg("14", from: "jemand@kunde.com"), settings: v).vip, "VIP-Domain mit @")
        check(!RuleEngine.evaluate(msg("15", from: "chefin@firma.de.evil.com"), settings: v).vip, "VIP-Adresse trifft keine Fremddomain")
        check(!RuleEngine.evaluate(msg("16", from: "anna.chefin@firma.de"), settings: v).vip, "VIP-Adresse ist exakt, kein Teilstring")
        v.rules = [rule("Niedrig", [(.domain, "firma.de")], priority: .low, flag: .blue)]
        let vip2 = RuleEngine.evaluate(msg("17", from: "chefin@firma.de"), settings: v)
        check(vip2.priority == .high && vip2.flag == .blue, "VIP hebt Priorität an, Regel-Flagge bleibt")
        v.vipFlagEnabled = false; v.rules = []
        check(RuleEngine.evaluate(msg("18", from: "chefin@firma.de"), settings: v).flag == nil, "VIP-Flagge abschaltbar")

        // Im Posteingang lassen
        check(RuleEngine.evaluate(msg("19", from: "a@keep.de"), settings: AppSettings.with([rule("K", [(.domain, "keep.de")], keep: true)])).keepInInbox, "Im Posteingang lassen")

        // Lernen
        do {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mp-rules-\(UUID()).sqlite")
            let store = try Store(path: tmp)
            defer { try? FileManager.default.removeItem(at: tmp) }
            let ls = AppSettings()

            func correct(_ id: String, _ from: String, to: String?, inbox: Bool = false) throws {
                try store.addCorrection(msg(id, from: from), from: "Newsletter", to: to, toInbox: inbox, source: "mail")
            }
            try correct("a", "news@shop.de", to: "Rechnungen")
            Learner.refreshSuggestions(store: store, settings: ls)
            check(try store.openSuggestions().isEmpty, "Eine Korrektur erzeugt noch keinen Vorschlag")
            try correct("b", "news@shop.de", to: "Rechnungen")
            Learner.refreshSuggestions(store: store, settings: ls)
            let sug = try store.openSuggestions()
            check(sug.count == 1 && sug[0].kind == "sender" && sug[0].category == "Rechnungen" && sug[0].count == 2, "Zwei gleiche Korrekturen → Absender-Vorschlag")
            check(sug.first?.rule.conditions.first?.field == .sender && sug.first?.rule.learned == true, "Vorschlag wird zur gelernten Regel")

            try store.setSuggestionStatus(sug[0].id, "dismissed")
            try correct("c", "news@shop.de", to: "Rechnungen")
            Learner.refreshSuggestions(store: store, settings: ls)
            check(try store.openSuggestions().isEmpty, "Verworfener Vorschlag kommt nicht wieder")

            try correct("d1", "a@lieferant.de", to: "Bestellungen")
            try correct("d2", "b@lieferant.de", to: "Bestellungen")
            Learner.refreshSuggestions(store: store, settings: ls)
            check(try store.openSuggestions().isEmpty, "Zwei Absender einer Domain reichen noch nicht")
            try correct("d3", "c@lieferant.de", to: "Bestellungen")
            Learner.refreshSuggestions(store: store, settings: ls)
            check(try store.openSuggestions().contains { $0.kind == "domain" && $0.value == "lieferant.de" }, "Drei Absender einer Domain → Domain-Vorschlag")

            for (i, a) in ["x", "y", "z"].enumerated() { try correct("g\(i)", "\(a)@gmail.com", to: "Persönlich") }
            Learner.refreshSuggestions(store: store, settings: ls)
            check(try !store.openSuggestions().contains { $0.value == "gmail.com" }, "Freemail-Domain wird nie vorgeschlagen")

            try correct("i1", "boss@firma.de", to: nil, inbox: true)
            try correct("i2", "boss@firma.de", to: nil, inbox: true)
            Learner.refreshSuggestions(store: store, settings: ls)
            check(try store.openSuggestions().contains { $0.value == "boss@firma.de" && $0.keepInInbox }, "Zurück in den Posteingang → „im Posteingang lassen“")

            var covered = AppSettings()
            covered.rules = [rule("Schon da", [(.sender, "neu@x.de")], category: "Rechnungen")]
            try correct("k1", "neu@x.de", to: "Rechnungen"); try correct("k2", "neu@x.de", to: "Rechnungen")
            Learner.refreshSuggestions(store: store, settings: covered)
            check(try !store.openSuggestions().contains { $0.value == "neu@x.de" }, "Bereits durch eine Regel abgedeckt → kein Vorschlag")

            try correct("u1", "u@y.de", to: "Gibt es nicht"); try correct("u2", "u@y.de", to: "Gibt es nicht")
            Learner.refreshSuggestions(store: store, settings: ls)
            check(try !store.openSuggestions().contains { $0.value == "u@y.de" }, "Unbekannte Zielkategorie → kein Vorschlag")

            var off = AppSettings(); off.learnFromCorrections = false
            try correct("o1", "o@z.de", to: "Rechnungen"); try correct("o2", "o@z.de", to: "Rechnungen")
            Learner.refreshSuggestions(store: store, settings: off)
            check(try !store.openSuggestions().contains { $0.value == "o@z.de" }, "Lernen abschaltbar")

            // Hinweise an Claude
            let hints = Learner.hints(for: msg("h", from: "news@shop.de"), store: store, settings: ls)
            check(hints.contains("Rechnungen") && hints.contains("umsortiert"), "Claude erhält die Korrektur als Hinweis")
            var vh = AppSettings(); vh.vips = [VIPEntry(name: "S", match: "news@shop.de")]
            check(Learner.hints(for: msg("h2", from: "news@shop.de"), store: store, settings: vh).contains("VIP"), "Claude erhält den VIP-Hinweis")
            check(Learner.hints(for: msg("h3", from: "ganz@neu.de"), store: store, settings: ls).isEmpty, "Kein Hinweis ohne Vorgeschichte")

            // Speicher: frisch verschobene Mails werden für die Korrekturprüfung zurückgehalten
            let raw = RawMessage(id: 1, messageId: "m1", account: "iCloud", mailbox: "INBOX", subject: "S", sender: "A <a@b.de>",
                                 date: Date().isoString, read: false, inReplyTo: nil, references: [], to: [], cc: [], content: "x", isSent: false)
            try store.insert(raw, myAddresses: [])
            try store.saveAnalysis(of: "m1", threadKey: "m1", category: "Newsletter", priority: .low, summary: "s", decidedBy: "Claude")
            try store.updateLocation("m1", mailbox: "Claude/Newsletter", mailId: 0)
            let fresh = try store.trackedMessages(accounts: ["iCloud"], prefix: "Claude/", since: Date().addingTimeInterval(-86400),
                                                  movedBefore: Date().addingTimeInterval(-900), limit: 10)
            let later = try store.trackedMessages(accounts: ["iCloud"], prefix: "Claude/", since: Date().addingTimeInterval(-86400),
                                                  movedBefore: Date().addingTimeInterval(60), limit: 10)
            check(fresh.isEmpty && later.count == 1, "Frisch verschobene Mails werden 15 Minuten nicht geprüft")
            check(later.first?.decidedBy == "Claude", "Herkunft der Kategorie wird gespeichert")
        } catch {
            check(false, "Lern-Tests liefen ohne Fehler: \(error)")
        }

        // Verschiebe-Schutz
        check(MoveGate.decide(sample: 25, found: 0) == "blocked", "Gate: nichts auffindbar → gesperrt")
        check(MoveGate.decide(sample: 25, found: 12) == "blocked", "Gate: weniger als die Hälfte auffindbar → gesperrt")
        check(MoveGate.decide(sample: 25, found: 13) == "ok", "Gate: Mehrheit auffindbar → frei")
        check(MoveGate.decide(sample: 25, found: 25) == "ok", "Gate: alles auffindbar → frei")
        check(MoveGate.decide(sample: 2, found: 0) == nil, "Gate: zu kleine Stichprobe → Probe-Mail entscheidet")

        // Alte Einstellungen ohne neue Felder bleiben lesbar
        let old = #"{"pollMinutes": 7, "model": "haiku"}"#
        if let decoded = try? JSONDecoder().decode(AppSettings.self, from: Data(old.utf8)) {
            check(decoded.pollMinutes == 7 && decoded.rules.isEmpty && decoded.learnFromCorrections, "Alte settings.json wird mit Standardwerten ergänzt")
        } else {
            check(false, "Alte settings.json wird mit Standardwerten ergänzt")
        }
        if let data = try? JSONEncoder().encode(v), let back = try? JSONDecoder().decode(AppSettings.self, from: data) {
            check(back.vips == v.vips && back.vipFlagEnabled == false, "Regeln und VIPs überstehen Speichern und Laden")
        }

        print(failures == 0 ? "\nAlle Tests bestanden." : "\n\(failures) Test(s) fehlgeschlagen.")
        exit(failures == 0 ? 0 : 1)
    }

    /// Nur lesend: Ordnerinhalte und Posteingang über die neuen Skripte abfragen.
    static func runSync() {
        let sema = DispatchSemaphore(value: 0)
        Task.detached {
            let bridge = MailBridge()
            do {
                let settings = AppSettings.load(from: Paths.settings)
                let all = CommandLine.arguments.contains("--all")
                let accounts = try await bridge.listAccounts().map(\.name).filter { all || settings.isEnabled($0) }
                let paths = Set(settings.categories.compactMap { settings.folderPath(for: $0) })
                let refs = accounts.flatMap { a in paths.map { MailBridge.FolderRef(account: a, path: $0) } }
                let start = Date()
                let listing = try await bridge.folderContents(refs)
                print("Ordnerabfrage: \(refs.count) Ordner angefragt, \(listing.count) gefunden, \(listing.values.reduce(0) { $0 + $1.count }) Mails in \(String(format: "%.1f", Date().timeIntervalSince(start))) s")
                for (r, ids) in listing.sorted(by: { ($0.key.account, $0.key.path) < ($1.key.account, $1.key.path) }) {
                    print("  \(r.account) / \(r.path): \(ids.count)")
                }
                // Trockenlauf der Korrekturerkennung gegen die echte Datenbank – nur Zählen, nichts schreiben.
                let store = try Store()
                let tracked = try store.trackedMessages(accounts: accounts, prefix: settings.folderPrefix,
                                                        since: Date().addingTimeInterval(-60 * 86400), movedBefore: Date(), limit: 5000)
                    .filter { paths.contains($0.mailbox) }
                let sets = listing.mapValues { Set($0) }
                var ok = 0, missing = 0, skipped = 0
                for m in tracked {
                    guard let here = sets[.init(account: m.account, path: m.mailbox)], !here.isEmpty else { skipped += 1; continue }
                    if here.contains(m.messageId) { ok += 1 } else { missing += 1 }
                }
                print("Korrekturprüfung (Trockenlauf): \(tracked.count) einsortierte Mails, \(ok) am erwarteten Ort, \(missing) würden als verschoben erkannt, \(skipped) übersprungen")
                for account in accounts {
                    let verdict = await MoveGate.verdict(account: account, store: store, bridge: bridge, settings: settings)
                    print("Verschiebe-Schutz „\(account)“: \(verdict ?? "ungeprüft (zu wenig Daten – Probe-Mail entscheidet)")")
                }
                if let acct = accounts.first {
                    let t = Date()
                    let r = try await bridge.inboxMembership(account: acct, ids: ["gibt-es-nicht@example.invalid"])
                    print("Posteingang „\(r.inbox)“ von \(acct) lesbar, Fremd-ID gefunden: \(!r.found.isEmpty) (\(String(format: "%.1f", Date().timeIntervalSince(t))) s)")
                }
            } catch {
                print("Sync-Fehler: \(error.localizedDescription)")
            }
            sema.signal()
        }
        sema.wait()
    }
}

private extension AppSettings {
    static func with(_ rules: [UserRule]) -> AppSettings {
        var s = AppSettings()
        s.rules = rules
        return s
    }
}

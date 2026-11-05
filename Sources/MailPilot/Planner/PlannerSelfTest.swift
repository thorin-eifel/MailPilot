import Foundation

/// Tests für Kalenderraster, Erinnerungsgruppen, Schnelleingabe und Verweise (`--selftest-more`).
extension SelfTest2 {
    static func plannerTests() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Berlin")!
        cal.firstWeekday = 2
        cal.locale = Locale(identifier: "de_DE")
        func d(_ y: Int, _ mo: Int, _ day: Int, _ h: Int = 0, _ mi: Int = 0) -> Date {
            cal.date(from: DateComponents(year: y, month: mo, day: day, hour: h, minute: mi))!
        }
        let now = d(2026, 10, 26, 10, 0)   // Montag
        func q(_ s: String) -> QuickAdd.Result { QuickAdd.parse(s, now: now, calendar: cal) }

        let a = q("Steuerberater anrufen morgen 14 Uhr")
        check(a.title == "Steuerberater anrufen" && a.date == d(2026, 10, 27, 14) && a.hasTime, "Schnelleingabe: morgen 14 Uhr")
        let b = q("Miete überweisen am 3.11.")
        check(b.title == "Miete überweisen" && b.date == d(2026, 11, 3) && !b.hasTime, "Schnelleingabe: Datum ohne Uhrzeit")
        check(q("Bericht in 2 Wochen").date == d(2026, 11, 9) && q("Bericht in 3 Tagen").title == "Bericht", "Schnelleingabe: in N Wochen/Tagen")
        let c = q("Zahnarzt Freitag 9:30")
        check(c.title == "Zahnarzt" && c.date == d(2026, 10, 30, 9, 30), "Schnelleingabe: Wochentag und Uhrzeit")
        check(q("Montag besprechen").date == d(2026, 11, 2), "Schnelleingabe: gleicher Wochentag heißt nächste Woche")
        check(q("Anruf um 8").date == d(2026, 10, 27, 8) && q("Anruf um 18 Uhr").date == d(2026, 10, 26, 18), "Schnelleingabe: nur Uhrzeit – heute oder morgen")
        check(q("Neujahr 1.1.").date == d(2027, 1, 1) && q("Frist 15.12.2026").date == d(2026, 12, 15), "Schnelleingabe: Jahr ergänzt")
        check(q("übermorgen Pakete abholen").date == d(2026, 10, 28) && q("heute Müll rausbringen").date == d(2026, 10, 26), "Schnelleingabe: heute/übermorgen")
        let plain = q("Einfach so")
        check(plain.title == "Einfach so" && plain.date == nil && !plain.hasTime, "Schnelleingabe: ohne Datum bleibt der Text")
        check(q("morgen").title == "morgen", "Schnelleingabe: nur ein Datumswort bleibt als Titel")

        // Raster
        check(PlannerLogic.weekStart(of: d(2026, 10, 28, 15), calendar: cal) == d(2026, 10, 26), "Woche beginnt am Montag")
        let week = PlannerLogic.days(from: d(2026, 10, 19), count: 9, calendar: cal)
        check(week.count == 9 && week[6] == d(2026, 10, 25) && week[7] == d(2026, 10, 26) && week[8] == d(2026, 10, 27), "Tage zählen über die Zeitumstellung hinweg")
        let grid = PlannerLogic.monthGrid(for: d(2026, 10, 15), calendar: cal)
        check(grid.count == 35 && grid.first == d(2026, 9, 28) && grid.last == d(2026, 11, 1), "Monatsraster: ganze Wochen")
        check(PlannerLogic.monthGrid(for: d(2027, 2, 10), calendar: cal).count == 28 && PlannerLogic.monthGrid(for: d(2026, 2, 10), calendar: cal).count == 35, "Monatsraster: Februar 2027 vier Wochen, 2026 fünf (beginnt sonntags)")

        func ev(_ title: String, _ s: Date, _ e: Date, allDay: Bool = false) -> PlannerEvent {
            PlannerEvent(eventID: title, calendarID: "c", calendarTitle: "K", colorHex: 0, title: title, start: s, end: e, allDay: allDay, location: "", url: nil)
        }
        let events = [ev("B spät", d(2026, 10, 27, 15), d(2026, 10, 27, 16)), ev("A früh", d(2026, 10, 27, 9), d(2026, 10, 27, 10)),
                      ev("Tag", d(2026, 10, 27), d(2026, 10, 28), allDay: true), ev("Reise", d(2026, 10, 26, 20), d(2026, 10, 28, 8)),
                      ev("Andere", d(2026, 10, 28, 9), d(2026, 10, 28, 10)), ev("Ende um Mitternacht", d(2026, 10, 26, 22), d(2026, 10, 27))]
        let tue = PlannerLogic.events(on: d(2026, 10, 27), in: events, calendar: cal).map(\.title)
        check(tue == ["Tag", "Reise", "A früh", "B spät"], "Tagesliste: ganztägig zuerst, mehrtägige dabei, Mitternachts-Ende nicht doppelt – \(tue)")

        // Erinnerungen
        func rem(_ title: String, due: Date?, time: Bool = true, done: Bool = false) -> PlannerReminder {
            PlannerReminder(id: title, listID: "l", listTitle: "Liste", colorHex: 0, title: title, notes: "", due: due, hasTime: time, completed: done, priority: 0, url: nil)
        }
        let rs = [rem("alt", due: d(2026, 10, 25, 9)), rem("gestern ohne Zeit", due: d(2026, 10, 25), time: false), rem("heute früh", due: d(2026, 10, 26, 8)),
                  rem("heute ohne Zeit", due: d(2026, 10, 26), time: false), rem("heute später", due: d(2026, 10, 26, 17)), rem("nächste Woche", due: d(2026, 11, 3, 9)),
                  rem("irgendwann", due: nil), rem("fertig", due: d(2026, 10, 20), done: true)]
        let groups = PlannerLogic.grouped(rs, showDone: false, now: now, calendar: cal)
        func titles(_ g: ReminderGroup) -> [String] { groups.first { $0.0 == g }?.1.map(\.title) ?? [] }
        check(titles(.overdue) == ["gestern ohne Zeit", "alt", "heute früh"], "Erinnerungen: überfällig – \(titles(.overdue))")
        check(titles(.today) == ["heute ohne Zeit", "heute später"] && titles(.upcoming) == ["nächste Woche"] && titles(.noDate) == ["irgendwann"], "Erinnerungen: heute, demnächst, ohne Datum")
        check(!groups.contains { $0.0 == .done } && PlannerLogic.grouped(rs, showDone: true, now: now, calendar: cal).last?.0 == .done, "Erinnerungen: Erledigte nur auf Wunsch")
        check(PlannerLogic.overdueCount(rs, now: now, calendar: cal) == 3, "Erinnerungen: Zahl der überfälligen")
        check(PlannerLogic.dueText(rem("x", due: d(2026, 10, 26, 17)), now: now, calendar: cal) == "Heute, 17:00"
              && PlannerLogic.dueText(rem("x", due: d(2026, 10, 27), time: false), now: now, calendar: cal) == "Morgen"
              && PlannerLogic.dueText(rem("x", due: d(2026, 11, 3, 9)), now: now, calendar: cal).hasSuffix("09:00"), "Erinnerungen: Fälligkeitstext")

        let parts = BriefingView.sections("Einleitung\n\n# Eins\n- a\n\n## Zwei\n- b\n# Drei")
        check(parts == ["Einleitung", "# Eins\n- a", "## Zwei\n- b", "# Drei"] && BriefingView.sections("").isEmpty && BriefingView.sections("# Nur").count == 1, "Briefing: Abschnitte an Überschriften")

        // Vorlagen und Verweise
        check(PlannerDraft.defaultDate(due: "2026-12-24", now: now, calendar: cal) == d(2026, 12, 24, 9)
              && PlannerDraft.defaultDate(due: "2026-01-01", now: now, calendar: cal) == d(2026, 10, 27, 9)
              && PlannerDraft.defaultDate(now: now, calendar: cal) == d(2026, 10, 27, 9), "Vorlage: Frist, sonst morgen 9 Uhr")
        let link = PlannerDraft.link(messageId: "abc.1+2@mail.example.de", ownClient: true)
        check(link?.scheme == "mailpilot" && link.flatMap(PlannerDraft.messageId(fromLink:)) == "abc.1+2@mail.example.de", "Verweis: eigene Mails lassen sich wieder öffnen")
        let apple = PlannerDraft.link(messageId: "abc@x.de", ownClient: false)
        check(apple?.scheme == "message" && apple.flatMap(PlannerDraft.messageId(fromLink:)) == nil, "Verweis: Apple-Mail-Mails bleiben bei message://")
        let draft = PlannerDraft.from(subject: "", sender: "Anna", date: now, link: link, kind: .reminder)
        check(draft.title == "Mail von Anna" && draft.notes.contains("mailpilot://message/") && draft.url == link, "Vorlage: Titel und Notiz aus der Mail")
    }

    /// Claudes Ergebnisse für die Liste des eigenen Postfachs.
    static func analysisLookupTests(_ tmp: URL) throws {
        let store = try Store(path: tmp.appendingPathComponent("lookup.sqlite"))
        try store.insert(raw("a1", subject: "Rechnung"), myAddresses: [])
        try store.insert(raw("a2", subject: "Unbearbeitet"), myAddresses: [])
        try store.saveAnalysis(of: "a1", threadKey: "t1", category: "Rechnungen", priority: .high, summary: "Rechnung über 40 €")
        let found = store.analyses(messageIds: ["a1", "a2", "fehlt"])
        check(found.count == 1 && found["a1"]?.category == "Rechnungen" && found["a1"]?.priority == .high && found["a1"]?.threadKey == "t1",
              "Postfach: nur analysierte Mails bekommen Claude-Ergebnisse")
        check(store.analyses(messageIds: []).isEmpty, "Postfach: leere Liste")
    }

    /// Vorgaben der Organisation: anwenden, sperren, laden.
    static func policyTests(_ tmp: URL) throws {
        let json = """
        {"organization":"CTW","supportContact":"it@ctw.example",
         "claude":{"enabled":false,"model":"haiku","environment":{"HTTPS_PROXY":"http://proxy.ctw.example:3128"}},
         "features":{"calendar":false,"contacts":false,"appleMail":false},
         "folderPrefix":"CTW/","dryRun":true,"maxAccounts":4,
         "privacyRules":[{"name":"Personal","conditions":[{"field":"domain","value":"betriebsrat.example"}]}],
         "providers":[{"name":"CTW Mail","imapHost":"imap.ctw.example","smtpHost":"smtp.ctw.example","smtpPort":465,"smtpSecurity":"tls","hint":"Domänenkonto"}],
         "onlyListedProviders":true}
        """
        let policy = try JSONDecoder().decode(Policy.self, from: Data(json.utf8))
        var user = AppSettings()
        user.useClaude = true; user.model = "opus"; user.folderPrefix = "Mein/"; user.useCalendar = true; user.useContacts = true; user.useAppleMail = true
        var own = PrivacyRule(); own.name = "Eigene"
        user.privacyRules = [own]
        let applied = policy.apply(to: user)
        check(!applied.useClaude && applied.model == "haiku" && applied.folderPrefix == "CTW/" && !applied.useCalendar && !applied.useContacts && !applied.useAppleMail && applied.dryRun,
              "Vorgaben: Claude, Modell, Präfix, Funktionen und Probelauf werden erzwungen")
        check(applied.privacyRules.count == 2 && applied.privacyRules[0].managed && applied.privacyRules[0].name == "Personal" && !applied.privacyRules[1].managed,
              "Vorgaben: Datenschutz-Ausnahmen der Organisation stehen vorn, die eigenen bleiben")
        check(policy.apply(to: applied) == applied && policy.apply(to: policy.apply(to: user)).privacyRules.count == 2, "Vorgaben: mehrfaches Anwenden ändert nichts und verdoppelt keine Regeln")
        check(Policy().apply(to: user) == user && Policy().isEmpty, "Vorgaben: leere Vorgaben ändern nichts")
        var tampered = applied; tampered.useClaude = true; tampered.folderPrefix = "x/"
        check(policy.apply(to: tampered) == applied, "Vorgaben: eine Änderung durch den Nutzer wird zurückgesetzt")
        check(policy.isLocked(.claudeEnabled) && policy.isLocked(.folderPrefix) && policy.isLocked(.privacyRules) && policy.isLocked(.providers) && !policy.isLocked(.archiveFolder)
              && !policy.isLocked(.notifications), "Vorgaben: gesperrt ist nur, was gesetzt ist")
        check(policy.lockedDescriptions.contains("Claude: ausgeschaltet") && policy.lockedDescriptions.contains("Höchstens 4 Konten"), "Vorgaben: Beschreibung für die Anzeige")
        check(policy.maxClientAccounts == 4 && Policy(maxAccounts: 99).maxClientAccounts == 16 && Policy(maxAccounts: 0).maxClientAccounts == 1 && Policy().maxClientAccounts == 16,
              "Vorgaben: Kontenzahl nur nach unten begrenzbar (1 bis 16)")
        let providers = MailProvider.available(policy: policy)
        check(providers.count == 1 && providers[0].name == "CTW Mail" && providers[0].smtpSecurity == .tls && providers[0].smtpPort == 465 && !providers[0].isCustom,
              "Vorgaben: nur die vorgegebenen Mail-Anbieter")
        var open = policy; open.onlyListedProviders = false
        check(MailProvider.available(policy: open).count == MailProvider.builtIn.count + 1 && MailProvider.available(policy: Policy()).count == MailProvider.builtIn.count, "Vorgaben: Anbieter ergänzen statt ersetzen")

        var fresh = AppSettings()
        fresh.protectNewAccount(knownAccounts: ["iCloud", "Work"])
        check(fresh.isEnabled("iCloud") && fresh.isEnabled("Work") && !fresh.isEnabled("Neu (IMAP)"), "Neue Konten: Claude ist zunächst aus, bekannte Konten bleiben freigegeben")
        var chosen = AppSettings(); chosen.enabledAccounts = ["Work"]
        chosen.protectNewAccount(knownAccounts: ["iCloud", "Work"])
        check(chosen.enabledAccounts == ["Work"], "Neue Konten: eine getroffene Auswahl bleibt unverändert")

        // Speichern: vorgegebene Ausnahmen kommen nicht in die Datei des Nutzers; alte Dateien ohne „managed“ bleiben lesbar
        let file = tmp.appendingPathComponent("settings-policy.json")
        applied.save(to: file)
        let reloaded = AppSettings.load(from: file)
        check(reloaded.privacyRules.count == 1 && reloaded.privacyRules[0].name == "Eigene" && !reloaded.privacyRules[0].managed, "Vorgaben: gespeichert werden nur die eigenen Ausnahmen")
        let old = #"{"privacyRules":[{"id":"6F1E8B4A-0000-4000-8000-000000000001","name":"Alt","enabled":true,"matchAll":false,"keepBody":false,"conditions":[]}]}"#
        let oldFile = tmp.appendingPathComponent("old-settings.json")
        try Data(old.utf8).write(to: oldFile)
        check(AppSettings.load(from: oldFile).privacyRules.first?.name == "Alt", "Einstellungen: Ausnahmen aus einer älteren Version bleiben erhalten")

        // Laden: Datei nur, wenn sie niemand außer root ändern kann; Profil nur, wenn verwaltet
        let pf = tmp.appendingPathComponent("policy.json")
        try Data(json.utf8).write(to: pf)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: pf.path)
        let suite = UserDefaults(suiteName: "mp-test-\(UUID())")!
        check(PolicyStore.load(defaults: suite, filePath: pf.path, requireRootFile: false).folderPrefix == "CTW/", "Vorgaben: Datei wird gelesen")
        check(PolicyStore.load(defaults: suite, filePath: pf.path, requireRootFile: true).isEmpty, "Vorgaben: Datei, die nicht root gehört, zählt nicht")
        try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: pf.path)
        check(PolicyStore.load(defaults: suite, filePath: pf.path, requireRootFile: false).isEmpty, "Vorgaben: für alle beschreibbare Datei zählt nicht")
        suite.set(["folderPrefix": "MDM/"], forKey: "Policy")
        check(PolicyStore.load(defaults: suite, filePath: "/nicht/da", requireRootFile: false).isEmpty, "Vorgaben: ein vom Nutzer selbst gesetzter Wert (nicht verwaltet) zählt nicht")
        check(PolicyStore.decode(["folderPrefix": "MDM/", "claude": ["enabled": false]])?.claude?.enabled == false, "Vorgaben: Profil-Dictionary wird gelesen")
        check(PolicyStore.decode(["folderPrefix": 5]) == nil, "Vorgaben: falsche Typen werden abgelehnt")
    }
}

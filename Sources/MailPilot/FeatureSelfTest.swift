import AppKit
import CoreText
import Foundation

/// Tests für Zurückstellen, Nachfassen, Fristen und Rechnungen.
/// `--selftest-features`: ohne Mail-Zugriff. `--selftest-live [--claude] [--export] [--attach] [--compose]`: echte Anbindungen.
enum FeatureSelfTest {
    nonisolated(unsafe) static var failures = 0

    static func check(_ ok: Bool, _ name: String) {
        print((ok ? "PASS  " : "FAIL  ") + name)
        if !ok { failures += 1 }
    }

    static func thread(_ key: String, status: ThreadStatus = .waiting, lastFromMe: Bool = true, daysAgo: Double = 5,
                       priority: Priority = .normal, draft: String? = nil, snoozed: Date? = nil, due: String? = nil,
                       category: String? = nil) -> MailThread {
        MailThread(threadKey: key, subject: "Betreff \(key)", normSubject: "betreff \(key)", counterpart: "Anna", lastDate: Date().addingTimeInterval(-daysAgo * 86400),
                   lastFromMe: lastFromMe, messageCount: 2, status: status, summary: "Zusammenfassung", nextStep: "Nachfassen", dueDate: due,
                   priority: priority, category: category, draft: draft, draftFor: nil, followupNotified: false,
                   draftKind: draft == nil ? nil : "followup", snoozedUntil: snoozed)
    }

    static func invoice(_ id: String, vendor: String = "Muster GmbH", amount: Double? = 119, vat: Double? = 19, due: String? = "2026-11-15",
                        paid: Bool = false, status: String = "ok") -> Invoice {
        Invoice(messageId: id, threadKey: "t-\(id)", account: "iCloud", sender: "Muster <buchhaltung@muster.example>", senderEmail: "buchhaltung@muster.example",
                subject: "Rechnung \(id)", mailDate: Date(), vendor: vendor, number: "RE-\(id)", amount: amount, vat: vat, currency: "EUR",
                issueDate: "2026-10-15", dueDate: due, description: "Wartung", source: "pdf", fileName: "re.pdf", paid: paid, status: status, error: nil)
    }

    // MARK: Offline

    static func run() {
        let cal = Calendar.current
        let wed = cal.date(from: DateComponents(year: 2026, month: 10, day: 28, hour: 10, minute: 0))!
        let tonight = SnoozeOption.tonight.date(from: wed)
        check(tonight.map { cal.component(.hour, from: $0) == 18 && cal.isDate($0, inSameDayAs: wed) } == true, "Zurückstellen: Heute Abend = 18 Uhr am selben Tag")
        check(SnoozeOption.tonight.date(from: cal.date(bySettingHour: 17, minute: 50, second: 0, of: wed)!) == nil, "Zurückstellen: Heute Abend entfällt kurz vor 18 Uhr")
        let tomorrow = SnoozeOption.tomorrow.date(from: wed)!
        check(cal.isDate(tomorrow, inSameDayAs: cal.date(byAdding: .day, value: 1, to: wed)!) && cal.component(.hour, from: tomorrow) == 8, "Zurückstellen: Morgen früh = nächster Tag 8 Uhr")
        let monday = SnoozeOption.nextMonday.date(from: wed)!
        check(cal.component(.weekday, from: monday) == 2 && cal.component(.hour, from: monday) == 8 && monday > wed
              && monday.timeIntervalSince(wed) < 8 * 86400, "Zurückstellen: Montag = nächster Montag 8 Uhr")
        let mondayNow = cal.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 10))!
        let nextMonday = SnoozeOption.nextMonday.date(from: mondayNow)!
        check(cal.component(.weekday, from: nextMonday) == 2 && nextMonday.timeIntervalSince(mondayNow) > 6 * 86400, "Zurückstellen: An einem Montag gilt der Montag darauf")
        let week = SnoozeOption.nextWeek.date(from: wed)!
        check(cal.isDate(week, inSameDayAs: cal.date(byAdding: .day, value: 7, to: wed)!) && cal.component(.hour, from: week) == 8, "Zurückstellen: In einer Woche = +7 Tage 8 Uhr")

        // Nachfassen
        let list = [
            thread("alt", daysAgo: 5), thread("alt-wichtig", daysAgo: 4, priority: .high), thread("neu", daysAgo: 1),
            thread("zurueck", daysAgo: 9, snoozed: Date().addingTimeInterval(3600)), thread("entwurf", daysAgo: 9, draft: "Hallo"),
            thread("antwort", status: .needsReply, lastFromMe: false, daysAgo: 9), thread("abgelaufen", daysAgo: 9, snoozed: Date().addingTimeInterval(-60)),
        ]
        let c = FollowUp.candidates(list, followUpDays: 3).map(\.threadKey)
        check(c == ["alt-wichtig", "abgelaufen", "alt"] || c == ["alt-wichtig", "alt", "abgelaufen"], "Nachfassen: nur überfällige Gespräche ohne Entwurf, nicht zurückgestellt, wichtige zuerst (\(c))")
        check(!c.contains("neu") && !c.contains("zurueck") && !c.contains("entwurf") && !c.contains("antwort"), "Nachfassen: neue, zurückgestellte, bereits entworfene und Antwort-Gespräche fehlen")
        check(FollowUp.subject(for: "Angebot") == "Re: Angebot" && FollowUp.subject(for: "AW: Angebot") == "AW: Angebot" && FollowUp.subject(for: "") == "Nachfrage",
              "Nachfassen: Betreff mit Re:-Präfix")
        var mine = RulesSelfTest.msg("m", from: "ich@example.org", body: "Zeile 1\nZeile 2", mine: true)
        mine.date = cal.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 9))!
        let body = FollowUp.body(text: "Kurze Nachfrage.", quoting: mine)
        check(body.hasPrefix("Kurze Nachfrage.") && body.contains("> Zeile 1\n> Zeile 2"), "Nachfassen: eigene Nachricht als Zitat")

        // Fristen
        let today = cal.date(from: DateComponents(year: 2026, month: 10, day: 28, hour: 15))!
        check(Deadlines.format(Deadlines.parse("2026-11-03")!) == "2026-11-03" && Deadlines.parse("03.11.2026") == nil, "Fristen: Datumsformat")
        check(Deadlines.eligible(thread("a", status: .needsReply, due: "2026-10-28"), today: today), "Fristen: heute fällig zählt")
        check(!Deadlines.eligible(thread("b", due: "2026-10-27"), today: today), "Fristen: vergangene Frist wird nicht eingetragen")
        check(!Deadlines.eligible(thread("c", status: .done, due: "2026-12-01"), today: today), "Fristen: erledigte Gespräche nicht")
        check(!Deadlines.eligible(thread("d", due: "2026-12-01", category: "Werbung"), today: today) && !Deadlines.eligible(thread("e", due: "2026-12-01", category: "Newsletter"), today: today),
              "Fristen: Werbung und Newsletter nicht")
        check(!Deadlines.eligible(thread("f"), today: today) && Deadlines.eligible(thread("g", due: "2026-12-01", category: "Rechnungen"), today: today), "Fristen: ohne Frist nein, Rechnung ja")
        check(Deadlines.title(for: thread("x")) == "Frist: Betreff x" && Deadlines.notes(for: thread("x"), url: "message://abc").contains("message://abc"), "Fristen: Titel und Notiz mit Mail-Link")
        check(DeadlineTarget.both.kinds == [.reminder, .calendar] && DeadlineTarget.off.kinds.isEmpty, "Fristen: Ziele")

        // Rechnungen: Geld, Auslesen von Zahlen
        check(Money.parse("1.234,50") == 1234.5 && Money.parse("1234,5") == 1234.5 && Money.parse("1,234.50") == 1234.5 && Money.parse("119") == 119
              && Money.parse("12,5 €") == 12.5 && Money.parse("") == nil && Money.parse("abc") == nil, "Rechnungen: Beträge in deutscher und englischer Schreibweise")
        check(Money.totals([invoice("1", amount: 100), invoice("2", amount: 50.5), invoice("3", amount: nil)])["EUR"] == 150.5, "Rechnungen: Summen je Währung")
        check(Money.format(1234.5, currency: "EUR").contains("1.234,50"), "Rechnungen: Betrag deutsch formatiert")

        // Rechnungen: Fälligkeit
        check(invoice("o", due: "2020-01-01").isOverdue() && !invoice("p", due: "2020-01-01", paid: true).isOverdue() && !invoice("q", due: nil).isOverdue(), "Rechnungen: überfällig nur offen und mit Datum")
        let soon = Deadlines.format(Date().addingTimeInterval(3 * 86400))
        check(invoice("s", due: soon).isDue(within: 7) && !invoice("t", due: soon).isDue(within: 1), "Rechnungen: bald fällig")

        // CSV
        let csv = InvoiceCSV.make([invoice("1", amount: 1234.5, vat: 197.11), invoice("2", vendor: "=SUMME(A1)", amount: -12, vat: nil, paid: true), invoice("3", vendor: "A;B \"C\"")])
        let lines = csv.components(separatedBy: "\r\n")
        check(csv.hasPrefix("\u{FEFF}Rechnungsdatum;Fälligkeit;Aussteller") && lines.count == 5 && lines.last == "", "CSV: BOM, Kopfzeile, CRLF, 3 Zeilen")
        check(lines[1].hasPrefix("15.10.2026;15.11.2026;Muster GmbH;RE-1;1234,50;197,11;EUR;offen;"), "CSV: deutsches Datum, Dezimalkomma, Status")
        check(lines[2].contains(";'=SUMME(A1);") && lines[2].contains(";-12,00;;EUR;bezahlt;"), "CSV: Formel-Einschleusung entschärft, Gutschrift bleibt Zahl")
        check(lines[3].contains("\"A;B \"\"C\"\"\""), "CSV: Semikolon und Anführungszeichen maskiert")

        // PDF-Text
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mp-feat-\(UUID())", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let textPDF = tmp.appendingPathComponent("text.pdf")
        makeTextPDF(at: textPDF, text: "Rechnung Nr. 4711\nGesamtbetrag 1.234,50 EUR\nZahlbar bis 15.11.2026")
        let extracted = PDFText.extract(textPDF)
        check(extracted.contains("4711") && extracted.contains("1.234,50"), "PDF: eingebetteter Text wird gelesen")
        let scanPDF = tmp.appendingPathComponent("scan.pdf")
        makeScanPDF(at: scanPDF, text: "Rechnung 4711 Betrag 99,00 EUR")
        let ocr = PDFText.extract(scanPDF)
        check(ocr.contains("4711"), "PDF: gescanntes PDF per Texterkennung gelesen (\(ocr.prefix(40).replacingOccurrences(of: "\n", with: " ")))")

        // Speicher
        do {
            let db = tmp.appendingPathComponent("t.sqlite")
            let store = try Store(path: db)
            var t = thread("s1", draft: "Entwurf", snoozed: Date().addingTimeInterval(7200), due: "2026-12-24")
            t.draftKind = "followup"
            try store.upsert(t)
            let back = try store.thread("s1")
            check(back?.isSnoozed == true && back?.draftKind == "followup" && back?.dueDate == "2026-12-24", "Speicher: Zurückstellung, Entwurfsart und Frist überleben Speichern")
            var past = t; past.snoozedUntil = Date().addingTimeInterval(-60)
            try store.upsert(past)
            check(try store.thread("s1")?.isSnoozed == false, "Speicher: abgelaufene Zurückstellung zählt nicht")
            var cleared = t; cleared.snoozedUntil = nil
            try store.upsert(cleared)
            check(try store.thread("s1")?.snoozedUntil == nil, "Speicher: Zurückstellung aufgehoben")

            try store.addExport("s1", due: "2026-12-24", kind: "reminder", extId: "x")
            try store.addExport("s1", due: "2026-12-24", kind: "reminder", extId: "y")
            check(store.hasExport("s1", due: "2026-12-24", kind: "reminder") && !store.hasExport("s1", due: "2026-12-24", kind: "calendar")
                  && !store.hasExport("s1", due: "2026-12-25", kind: "reminder"), "Speicher: Fristen werden nur einmal je Art und Datum eingetragen")

            let raw = RawMessage(id: 1, messageId: "r1", account: "iCloud", mailbox: "INBOX", subject: "Rechnung", sender: "A <a@b.de>", date: Date().isoString,
                                 read: false, inReplyTo: nil, references: [], to: [], cc: [], content: "x", isSent: false)
            try store.insert(raw, myAddresses: [])
            try store.saveAnalysis(of: "r1", threadKey: "r1", category: "Rechnungen", priority: .normal, summary: "s")
            check(try store.invoiceQueue(category: "Rechnungen", accounts: ["iCloud"], limit: 5).map(\.messageId) == ["r1"]
                  && store.invoiceQueueCount(category: "Rechnungen", accounts: ["iCloud"]) == 1
                  && store.invoiceQueueCount(category: "Rechnungen", accounts: ["Google"]) == 0, "Speicher: Warteschlange der Rechnungs-Mails")
            try store.saveInvoice(invoice("r1", amount: nil, vat: nil))
            let inv = try store.invoice(id: "r1")
            check(inv?.amount == nil && inv?.vat == nil && inv?.vendor == "Muster GmbH" && inv?.dueDate == "2026-11-15", "Speicher: fehlender Betrag bleibt leer (nicht 0)")
            check(try store.invoiceQueue(category: "Rechnungen", accounts: ["iCloud"], limit: 5).isEmpty, "Speicher: ausgelesene Mail verlässt die Warteschlange")
            try store.saveInvoice(invoice("r2", amount: 0))
            check(try store.invoice(id: "r2")?.amount == 0, "Speicher: Betrag 0 bleibt 0")
            try store.setInvoicePaid("r1", paid: true)
            check(try store.invoice(id: "r1")?.paid == true, "Speicher: als bezahlt markieren")
            check(try store.invoices(accounts: ["iCloud"]).count == 2 && (try store.invoices(accounts: ["Google"]).isEmpty), "Speicher: Rechnungen je Konto")
            try store.deleteInvoice("r1")
            check(try store.invoice(id: "r1") == nil, "Speicher: Eintrag entfernen")
        } catch {
            check(false, "Speicher-Tests liefen ohne Fehler: \(error)")
        }

        // Einstellungen
        if let s = try? JSONDecoder().decode(AppSettings.self, from: Data(#"{"pollMinutes": 9}"#.utf8)) {
            check(s.deadlineTarget == .off && s.extractInvoices && s.invoiceCategory == "Rechnungen" && s.autoFollowUpDrafts && s.reminderList == "MailPilot",
                  "Einstellungen: neue Felder haben Standardwerte")
        } else { check(false, "Einstellungen: alte Datei lesbar") }

        print(failures == 0 ? "\nAlle Tests bestanden." : "\n\(failures) Test(s) fehlgeschlagen.")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: Test-PDFs

    static func makeTextPDF(at url: URL, text: String) {
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
        ctx.beginPDFPage(nil)
        let attr = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 14)])
        let frame = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(attr), CFRangeMake(0, 0),
                                             CGPath(rect: CGRect(x: 40, y: 600, width: 500, height: 200), transform: nil), nil)
        CTFrameDraw(frame, ctx)
        ctx.endPDFPage()
        ctx.closePDF()
    }

    /// PDF aus einem Bild ohne Text – wie ein Scan.
    static func makeScanPDF(at url: URL, text: String) {
        let size = NSSize(width: 1400, height: 500)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        (text as NSString).draw(at: NSPoint(x: 40, y: 200), withAttributes: [.font: NSFont.systemFont(ofSize: 64), .foregroundColor: NSColor.black])
        image.unlockFocus()
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        var box = CGRect(x: 0, y: 0, width: 595, height: 210)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
        ctx.beginPDFPage(nil)
        ctx.draw(cg, in: box)
        ctx.endPDFPage()
        ctx.closePDF()
    }

    // MARK: Live

    static func runLive(_ args: [String]) {
        let sema = DispatchSemaphore(value: 0)
        Task.detached {
            let settings = AppSettings.load(from: Paths.settings)
            let bridge = MailBridge()
            if args.contains("--claude"), let path = ClaudeClient.locate(preferred: settings.claudePath) {
                let client = ClaudeClient(executable: path, model: settings.model)
                do {
                    var m = RulesSelfTest.msg("inv", from: "buchhaltung@muster-it.example", subject: "Rechnung RE-2026-0815",
                                              body: "Guten Tag, anbei Ihre Rechnung für die Wartung im Oktober. Bitte überweisen Sie bis zum 15.11.2026.")
                    m.sender = "Muster IT GmbH <buchhaltung@muster-it.example>"
                    let x = try await client.extractInvoice(message: m, pdfs: [("RE-2026-0815.pdf", """
                        Muster IT GmbH · Hauptstraße 1 · 54290 Trier
                        RECHNUNG Nr. RE-2026-0815 vom 28.10.2026
                        Wartung Oktober 2026   Netto 1.037,82 EUR
                        zzgl. 19 % USt 197,18 EUR
                        Gesamtbetrag brutto 1.235,00 EUR
                        Zahlbar bis 15.11.2026 ohne Abzug.
                        """)])
                    print("Claude Rechnung: \(x.is_invoice) | \(x.vendor ?? "-") | Nr. \(x.invoice_number ?? "-") | \(x.amount_gross.map { String($0) } ?? "-") \(x.currency ?? "") | USt \(x.vat_amount.map { String($0) } ?? "-") | Datum \(x.issue_date ?? "-") | fällig \(x.due_date ?? "-") | bezahlt \(x.already_paid ?? false)")
                    check(x.is_invoice && (x.vendor ?? "").contains("Muster") && x.amount_gross == 1235 && x.due_date == "2026-11-15" && x.issue_date == "2026-10-28" && x.currency == "EUR",
                          "Claude liest Rechnung korrekt aus")
                    let notInvoice = RulesSelfTest.msg("nl", from: "news@shop.example", subject: "Unsere Herbst-Angebote", body: "Bis zu 30 % Rabatt auf alles! Jetzt stöbern.")
                    let y = try await client.extractInvoice(message: notInvoice, pdfs: [])
                    check(!y.is_invoice, "Claude erkennt Werbung als Nicht-Rechnung")
                    var t = thread("fu", daysAgo: 6)
                    t.summary = "Ich habe am 22.10. ein Angebot für die Server-Migration geschickt und um Rückmeldung bis Ende der Woche gebeten."
                    var out = RulesSelfTest.msg("o1", from: "ich@example.org", subject: "Angebot Server-Migration",
                                                body: "Hallo Herr Weber,\n\nanbei das Angebot für die Server-Migration. Können Sie mir bis Freitag Bescheid geben, ob wir starten sollen?\n\nBeste Grüße\nThorsten", mine: true)
                    out.date = Date().addingTimeInterval(-6 * 86400)
                    let draft = try await client.redraft(thread: t, messages: [out], hint: "", settings: settings, followUp: true)
                    print("Claude Nachfass-Entwurf:\n---\n\(draft)\n---")
                    check(draft.count > 60 && draft.count < 1200 && !draft.hasPrefix("Betreff"), "Claude schreibt einen Nachfass-Entwurf in sinnvoller Länge")
                    // Antwortstil: aus synthetischen Proben lernen und im Entwurf verwenden
                    let bodies = [
                        "Hallo Herr Weber,\n\nanbei das Angebot für die Server-Migration. Bei Fragen melden Sie sich gern.\n\nMit freundlichen Grüßen\nThorsten Schleicher\nCTW Computer",
                        "Hallo Frau Becker,\n\nvielen Dank für Ihre Nachricht. Den Termin am Dienstag bestätige ich gern.\n\nMit freundlichen Grüßen\nThorsten Schleicher\nCTW Computer",
                        "Hi Karl-Heinz,\n\nkurz zur Info: Akku ist bestellt, kommt Donnerstag. Sag Bescheid, falls es eilt.\n\nGruß\nThorsten",
                        "Hi Karl-Heinz,\n\nlink zum Produkt hab ich dir geschickt, schau mal drüber.\n\nGruß\nThorsten",
                    ]
                    let samples = (0..<12).map { StyleLearner.Sample(recipient: "kontakt\($0 % 4)@example.org", body: bodies[$0 % bodies.count]) }
                    let guide = try await client.learnStyle(samples: samples)
                    print("Claude Stilleitfaden (\(guide.count) Zeichen):\n---\n\(guide)\n---")
                    check(guide.count > 120 && guide.count < 2500 && (guide.contains("Du") || guide.contains("du")) && guide.contains("Sie"), "Claude leitet einen Stilleitfaden ab (Du und Sie erkannt)")
                    let styled = try await client.redraft(thread: t, messages: [out], hint: "", settings: settings, followUp: true, styleGuide: guide, examples: [bodies[0]])
                    print("Claude Entwurf im Stil:\n---\n\(styled)\n---")
                    check(styled.contains("Thorsten") && styled.count > 60, "Entwurf im gelernten Stil enthält Grußformel und Signatur")
                    // Wochenbericht
                    var stats = WeeklyStats(from: Date().addingTimeInterval(-7 * 86400), to: Date())
                    stats.received = 42; stats.receivedPrevious = 30; stats.sent = 12; stats.sentPrevious = 15
                    stats.categories = [CategoryDelta(name: "Newsletter", now: 20, previous: 8), CategoryDelta(name: "Rechnungen", now: 4, previous: 6)]
                    stats.lateReplies = [ThreadAge(threadKey: "a", subject: "Angebot Server-Migration", counterpart: "Weber", days: 5)]
                    stats.overdueWaiting = [ThreadAge(threadKey: "b", subject: "Rückruf API-Leasing", counterpart: "Hartmann", days: 6)]
                    stats.medianReplyHours = 7.5; stats.replySamples = 9; stats.openNeedsReply = 3; stats.openWaiting = 5
                    let report = try await client.weeklyReport(stats: stats, settings: settings)
                    print("Claude Wochenbericht:\n---\n\(report)\n---")
                    check(report.contains("##") && report.contains("Server-Migration") && report.contains("Hartmann"), "Claude schreibt den Wochenbericht mit den genannten Gesprächen")
                    // Abo-Auslastung aus der CLI-Ausgabe
                    let limits = UsageMonitor.shared.currentLimits
                    print("Abo-Auslastung: 5 Std. \(limits?.fiveHour?.percent.description ?? "–") %, 7 Tage \(limits?.sevenDay?.percent.description ?? "–") %")
                    check(limits?.fiveHour != nil && limits?.sevenDay != nil, "Abo-Auslastung wird aus den Claude-Aufrufen gelesen")
                } catch {
                    check(false, "Claude-Tests liefen ohne Fehler: \(error.localizedDescription)")
                }
            }
            if args.contains("--newsletter") {
                do {
                    let store = try Store()
                    let msgs = try store.newsletterMessages(category: "Newsletter", accounts: ["iCloud", "thorin.eifel@icloud.com"], since: Date().addingTimeInterval(-90 * 86400))
                    let groups = Dictionary(grouping: msgs.filter { $0.mailbox != "(entfernt)" }, by: { MailBridge.FolderRef(account: $0.account, path: $0.mailbox) })
                    let states = try await bridge.readStates(Array(groups.keys.prefix(4)))
                    let total = states.values.reduce(0) { $0 + $1.count }
                    let unread = states.values.reduce(0) { $0 + $1.values.filter { !$0 }.count }
                    print("Lesestatus: \(states.count) Ordner, \(total) Mails, davon \(unread) ungelesen")
                    check(!states.isEmpty && total > 0, "Newsletter: Lesestatus aus Apple Mail gelesen")
                    var withHeader = 0, methods: [String: Int] = [:]
                    for m in msgs.prefix(8) {
                        guard let info = try? await bridge.unsubscribeHeader(account: m.account, mailbox: m.mailbox, id: m.mailId, messageId: m.messageId) else { continue }
                        if info.unsub != nil { withHeader += 1 }
                        methods[UnsubOption.parse(header: info.unsub, post: info.post).method.rawValue, default: 0] += 1
                    }
                    print("Abmelde-Header: \(withHeader) von \(min(8, msgs.count)) Mails, Methoden: \(methods)")
                    check(withHeader > 0, "Newsletter: List-Unsubscribe-Header aus Mails gelesen")
                } catch {
                    check(false, "Newsletter-Test: \(error.localizedDescription)")
                }
            }
            if args.contains("--flagrestore") {
                do {
                    let item = MailBridge.BatchItem(messageId: "gibt-es-nicht@example.invalid", location: .init(account: "iCloud", mailbox: "INBOX", mailId: 1),
                                                    target: nil, flag: nil, restoreFlag: (false, -1))
                    let r = try await bridge.batch([item])
                    check(r.count == 1 && !r[0].ok, "Flaggen: Zurücksetzen einer nicht vorhandenen Mail schlägt sauber fehl (nichts verändert)")
                } catch {
                    check(false, "Flaggen-Test: \(error.localizedDescription)")
                }
            }
            if args.contains("--compose") {
                do {
                    let r = try await bridge.compose(sender: nil, to: ["test@example.invalid"], subject: "MailPilot-Test", content: "Testtext", visible: false)
                    print("Mail-Fenster (unsichtbar): Betreff \(r.subject), Empfänger \(r.to), verworfen: \(r.discarded)")
                    check(r.subject == "MailPilot-Test" && r.to == ["test@example.invalid"], "Mail: Nachricht mit Empfänger und Betreff angelegt")
                } catch {
                    check(false, "Mail-Fenster anlegen: \(error.localizedDescription)")
                }
            }
            if args.contains("--export") {
                do {
                    let t = try await bridge.exportTargets()
                    print("Erinnerungslisten: \(t.reminderLists.joined(separator: ", ")) | beschreibbare Kalender: \(t.calendars.filter(\.writable).count)")
                    check(!t.reminderLists.isEmpty && t.calendars.contains { $0.writable }, "Erinnerungen und Kalender sind lesbar")
                    if let list = t.reminderLists.first(where: { $0 == "Erinnerungen" }) ?? t.reminderLists.first, let cal = t.calendars.first(where: \.writable) {
                        let due = Deadlines.format(Date().addingTimeInterval(30 * 86400))
                        let r = try await bridge.testExport(list: list, calendarID: cal.id, due: due)
                        print("Export-Test (sofort wieder gelöscht): Erinnerung \(r.reminderCreated)/\(r.reminderDeleted), Termin \(r.eventCreated)/\(r.eventDeleted) \(r.errors)")
                        check(r.reminderCreated && r.reminderDeleted, "Erinnerung angelegt und wieder gelöscht")
                        check(r.eventCreated && r.eventDeleted, "Kalendereintrag angelegt und wieder gelöscht")
                    }
                } catch {
                    check(false, "Export-Test: \(error.localizedDescription)")
                }
            }
            if args.contains("--attach") {
                do {
                    let store = try Store()
                    let queue = try store.db.query("""
                        SELECT * FROM messages WHERE account IN ('iCloud','thorin.eifel@icloud.com') AND category = 'Rechnungen' AND mailbox LIKE 'Claude/%'
                        ORDER BY date DESC LIMIT 12
                        """).map(store.message)
                    var tried = 0, withPDF = 0
                    for m in queue where tried < 6 {
                        tried += 1
                        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mp-att-\(UUID())", isDirectory: true)
                        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                        defer { try? FileManager.default.removeItem(at: dir) }
                        guard let infos = try? await bridge.attachments(account: m.account, mailbox: m.mailbox, id: m.mailId, messageId: m.messageId, saveTo: dir) else {
                            print("  Mail \(tried): nicht lesbar"); continue
                        }
                        let saved = infos.compactMap(\.saved)
                        let errors = infos.compactMap(\.error).count
                        var chars = 0
                        for p in saved { chars += PDFText.extract(URL(fileURLWithPath: p)).count }
                        print("  Mail \(tried): \(infos.count) Anhänge, \(saved.count) PDF gespeichert, \(errors) Fehler, \(chars) Zeichen Text")
                        if !saved.isEmpty { withPDF += 1 }
                    }
                    check(tried > 0, "Anhänge: Rechnungs-Mails gefunden")
                    check(withPDF > 0, "Anhänge: mindestens ein PDF gespeichert und gelesen (\(withPDF) von \(tried))")
                } catch {
                    check(false, "Anhang-Test: \(error.localizedDescription)")
                }
            }
            print(failures == 0 ? "\nLive-Tests bestanden." : "\n\(failures) Live-Test(s) fehlgeschlagen.")
            sema.signal()
        }
        sema.wait()
        exit(failures == 0 ? 0 : 1)
    }
}

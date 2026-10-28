import Foundation
import SwiftUI
import UserNotifications

/// Steuert den Abruf, die Analyse durch Claude und die automatischen Aktionen in Mail.
///
/// Ablauf: Beim ersten Start wird der komplette Posteingang katalogisiert und einsortiert (Erstscan).
/// Erst wenn der durch ist, übernimmt der Scheduler mit regelmäßigen Durchläufen.
@MainActor
final class Engine: ObservableObject {
    static let shared = Engine()

    struct InitialProgress {
        var total: Int
        var analyzed: Int
        var moved: Int
        var fraction: Double { total > 0 ? min(1, Double(analyzed) / Double(total)) : 0 }
    }

    @Published var settings: AppSettings {
        didSet {
            if persistSettings { settings.save(to: Paths.settings) }
            UsageMonitor.shared.update(settings.usageGuard)
            if oldValue.pollMinutes != settings.pollMinutes { schedule() }
            if oldValue.clientAccounts != settings.clientAccounts || oldValue.useAppleMail != settings.useAppleMail { Task { await refreshAccounts(); reload() } }
            // Probelauf beendet: Was er nur durchgespielt hat, wird beim nächsten Durchlauf wirklich ausgeführt.
            if oldValue.dryRun, !settings.dryRun, store.releaseDryRun() > 0 { store.setValue("1", for: "catchUp") }
            if oldValue.enabledAccounts != settings.enabledAccounts { accountsChanged() }
        }
    }
    /// Alle aktiven Konten in Apple Mail.
    @Published private(set) var accounts: [MailAccountInfo] = []
    @Published private(set) var threads: [MailThread] = []
    @Published private(set) var activity: [ActivityEntry] = []
    /// Je Konto: "ok" (Zielordner zurücklesbar) oder "blocked" (nur markieren). Fehlt = noch ungeprüft.
    @Published var moveStatus: [String: String] = [:]
    /// Verfügbare Erinnerungslisten und Kalender (für die Auswahl der Fristen-Ziele).
    @Published var reminderLists: [String] = []
    @Published var calendars: [CalendarInfo] = []
    @Published private(set) var invites: [Invite] = []
    @Published private(set) var weeklyReport: WeeklyReport?
    @Published var weeklyBusy = false
    @Published private(set) var invoices: [Invoice] = []
    /// Noch nicht ausgelesene Mails der Rechnungs-Kategorie.
    @Published private(set) var invoiceQueue = 0
    @Published var invoiceBusy = false
    /// Navigation von außen (Tastenkürzel, Mitteilungen): Abschnitt der Seitenleiste bzw. Gespräch, das gezeigt werden soll.
    @Published var requestedSidebar: SidebarItem?
    @Published var focusThread: String?
    /// Gespräch, das gerade geöffnet ist (für Tastenkürzel).
    @Published var selectedThreadKey: String?
    /// Öffnet das Dashboard-Fenster (wird von der Menüleiste gesetzt).
    var openDashboard: (() -> Void)?
    @Published var styleBusy = false
    @Published private(set) var planLimits: PlanLimits?
    @Published private(set) var usageToday = UsageSummary()
    @Published private(set) var usageBlock: String?
    @Published private(set) var suggestions: [RuleSuggestion] = []
    @Published private(set) var corrections: [Correction] = []
    @Published private(set) var briefing: Briefing?
    @Published var isRunning = false
    @Published private(set) var isBriefing = false
    @Published var status = "Bereit"
    @Published private(set) var lastRun: Date?
    @Published var lastError: String?
    @Published private(set) var initialProgress: InitialProgress?
    @Published var paused = false { didSet { schedule() } }

    let store: Store
    let bridge = MailBridge()
    /// Für die Bildvorschau aus: Beispieldaten dürfen die echte settings.json nicht überschreiben.
    var persistSettings = true
    private var loop: Task<Void, Never>?
    var myAddresses: [String]
    /// Abbruchgrund innerhalb paralleler Analysen (z. B. Claude nicht angemeldet oder Limit erreicht).
    private var abortError: Error?

    /// Konten, deren Posteingang bereits vollständig katalogisiert wurde.
    private var scannedAccounts: Set<String> {
        didSet { store.setValue(scannedAccounts.sorted().joined(separator: "\n"), for: "scannedAccounts") }
    }

    /// Mails jünger als diese Grenze werden einzeln mit Verlauf und Entwurf analysiert, ältere im Paket.
    private let detailedDays = 14.0

    private init() {
        do { store = try Store() } catch { fatalError("Datenbank: \(error)") }
        settings = AppSettings.load(from: Paths.settings)
        scannedAccounts = Set((store.value("scannedAccounts") ?? "").split(separator: "\n").map(String.init))
        myAddresses = (store.value("myAddresses") ?? "").split(separator: ",").map(String.init)
        UsageMonitor.shared.configure(store: store)
        UsageMonitor.shared.update(settings.usageGuard)
        UsageMonitor.shared.onChange = { Task { @MainActor in Engine.shared.refreshUsage() } }
        if store.releaseLegacyDryRun() > 0 { store.setValue("1", for: "catchUp") }
        reload()
    }

    var claude: ClaudeClient? {
        ClaudeClient.locate(preferred: settings.claudePath).map { ClaudeClient(executable: $0, model: settings.model) }
    }

    /// Günstigeres Modell für die Massenanalyse älterer Mails.
    var claudeBulk: ClaudeClient? {
        ClaudeClient.locate(preferred: settings.claudePath).map { ClaudeClient(executable: $0, model: settings.modelBulk.isEmpty ? settings.model : settings.modelBulk) }
    }

    /// Für Aufrufe, die der Nutzer per Knopfdruck auslöst: läuft auch bei erreichter Pause-Grenze.
    var claudeInteractive: ClaudeClient? {
        claude.map { var c = $0; c.interactive = true; return c }
    }

    // MARK: Abgeleitete Werte

    /// Konten, auf denen MailPilot laufen darf (gemäß Auswahl in den Einstellungen).
    var enabledAccountNames: [String] { accounts.map(\.name).filter(settings.isEnabled) }

    /// Freigegebene Konten, für die der Erstscan noch aussteht.
    var pendingScanAccounts: [String] { enabledAccountNames.filter { !scannedAccounts.contains($0) } }

    var initialComplete: Bool { !accounts.isEmpty && pendingScanAccounts.isEmpty }

    func isScanned(_ account: String) -> Bool { scannedAccounts.contains(account) }

    func setAccount(_ name: String, enabled: Bool) {
        var list = settings.enabledAccounts ?? accounts.map(\.name)
        list.removeAll { $0 == name }
        if enabled { list.append(name) }
        settings.enabledAccounts = list
    }

    func refreshAccounts() async {
        accounts = await listAllAccounts()
    }

    private func accountsChanged() {
        reload()
        guard started else { return }
        if !pendingScanAccounts.isEmpty {
            Task { await runInitialScan() }
        } else if enabledAccountNames.isEmpty {
            loop?.cancel()
            status = "Kein Konto ausgewählt"
        }
    }

    /// Zurückgestellte Gespräche erscheinen weder in den Listen noch in den Zählern, bis die Zeit abgelaufen ist.
    var needsReply: [MailThread] { threads.filter { $0.status == .needsReply && !$0.isSnoozed } }
    var waiting: [MailThread] { threads.filter { $0.status == .waiting && !$0.isSnoozed } }
    var overdue: [MailThread] { waiting.filter { $0.isOverdue(followUpDays: settings.followUpDays) } }
    var snoozed: [MailThread] { threads.filter(\.isSnoozed).sorted { ($0.snoozedUntil ?? .distantFuture) < ($1.snoozedUntil ?? .distantFuture) } }

    func messages(in thread: MailThread) -> [StoredMessage] {
        (try? store.messages(inThread: thread.threadKey)) ?? []
    }

    func refreshUsage() {
        planLimits = UsageMonitor.shared.currentLimits
        usageToday = store.usageSummary(since: Calendar.current.startOfDay(for: Date()))
        usageBlock = UsageMonitor.shared.blockReason()
    }

    func reload() {
        refreshUsage()
        threads = (try? store.threads(accounts: enabledAccountNames)) ?? []
        activity = (try? store.activity()) ?? []
        suggestions = (try? store.openSuggestions()) ?? []
        weeklyReport = store.latestReport()
        invites = (try? store.invites(accounts: enabledAccountNames)) ?? []
        invoices = (try? store.invoices(accounts: enabledAccountNames)) ?? []
        invoiceQueue = settings.extractInvoices ? store.invoiceQueueCount(category: settings.invoiceCategory, accounts: enabledAccountNames) : 0
        moveStatus = Dictionary(uniqueKeysWithValues: accounts.compactMap { a in
            store.value("moveCheck.\(a.name)").map { (a.name, $0) }
        })
        // Eigene IMAP-Konten: Ordner lassen sich zuverlässig verschieben und zurücklesen.
        for a in settings.clientAccounts { moveStatus[a.engineName] = "ok" }
        corrections = (try? store.corrections(limit: 40)) ?? []
        briefing = try? store.latestBriefing()
    }

    /// Beispieldaten für die Bildvorschau (`--render`); wird nie gespeichert.
    func loadPreviewSamples() {
        persistSettings = false
        var r1 = UserRule()
        r1.name = "PayPal-Belege"
        r1.conditions = [RuleCondition(field: .domain, value: "paypal.com")]
        r1.category = "Rechnungen"
        r1.priority = .normal
        var r2 = UserRule()
        r2.name = "Angebote im Posteingang lassen"
        r2.matchAll = false
        r2.conditions = [RuleCondition(field: .sender, value: "angebote@"), RuleCondition(field: .subject, value: "Sonderangebot")]
        r2.keepInInbox = true
        r2.learned = true
        settings.rules = [r1, r2]
        settings.vips = [VIPEntry(name: "Geschäftsführung", match: "chef@firma.example"), VIPEntry(name: "Kunde Beispiel AG", match: "beispiel-ag.example")]
        suggestions = [
            RuleSuggestion(id: 1, kind: "sender", value: "news@shop.example", category: "Rechnungen", keepInInbox: false, count: 2),
            RuleSuggestion(id: 2, kind: "domain", value: "lieferant.example", category: "Bestellungen", keepInInbox: false, count: 4),
        ]
        invoices = [
            Invoice(messageId: "p1", threadKey: nil, account: "iCloud", sender: "Muster IT <buchhaltung@muster-it.example>", senderEmail: "buchhaltung@muster-it.example",
                    subject: "Rechnung RE-2026-0815", mailDate: Date().addingTimeInterval(-5 * 86400), vendor: "Muster IT GmbH", number: "RE-2026-0815",
                    amount: 1235, vat: 197.18, currency: "EUR", issueDate: Deadlines.format(Date().addingTimeInterval(-5 * 86400)),
                    dueDate: Deadlines.format(Date().addingTimeInterval(-2 * 86400)), description: "Wartung Oktober 2026", source: "pdf", fileName: "re.pdf",
                    paid: false, status: "ok", error: nil),
            Invoice(messageId: "p2", threadKey: nil, account: "iCloud", sender: "Telekom <rechnung@telekom.example>", senderEmail: "rechnung@telekom.example",
                    subject: "Ihre Rechnung", mailDate: Date().addingTimeInterval(-3 * 86400), vendor: "Telekom Deutschland GmbH", number: "7788-2210",
                    amount: 64.95, vat: 10.37, currency: "EUR", issueDate: Deadlines.format(Date().addingTimeInterval(-3 * 86400)),
                    dueDate: Deadlines.format(Date().addingTimeInterval(4 * 86400)), description: "Mobilfunk Oktober", source: "pdf", fileName: "t.pdf",
                    paid: false, status: "ok", error: nil),
            Invoice(messageId: "p3", threadKey: nil, account: "iCloud", sender: "Hetzner <billing@hetzner.example>", senderEmail: "billing@hetzner.example",
                    subject: "Invoice", mailDate: Date().addingTimeInterval(-9 * 86400), vendor: "Hetzner Online GmbH", number: "H-4411",
                    amount: 31.5, vat: nil, currency: "EUR", issueDate: Deadlines.format(Date().addingTimeInterval(-9 * 86400)),
                    dueDate: Deadlines.format(Date().addingTimeInterval(12 * 86400)), description: "Cloud-Server", source: "mail", fileName: nil,
                    paid: false, status: "ok", error: nil),
            Invoice(messageId: "p4", threadKey: nil, account: "iCloud", sender: "Shop <a@shop.example>", senderEmail: "a@shop.example",
                    subject: "Bestellung", mailDate: Date().addingTimeInterval(-12 * 86400), vendor: "Beispiel-Shop", number: nil,
                    amount: 89, vat: 14.21, currency: "EUR", issueDate: nil, dueDate: nil, description: "Bestellung 123", source: "mail", fileName: nil,
                    paid: true, status: "ok", error: nil),
        ]
        invoiceQueue = 7
        let nextTue = Calendar.current.nextDate(after: Date(), matching: DateComponents(hour: 10, minute: 0, weekday: 3), matchingPolicy: .nextTime) ?? Date()
        invites = [
            Invite(messageId: "x1", event: InviteEvent(uid: "u1", summary: "Projekt-Kickoff Server-Migration", start: nextTue, end: nextTue.addingTimeInterval(5400), allDay: false,
                                                       location: "Besprechungsraum 2, Trier", organizer: "Anna Weber", method: "REQUEST", cancelled: false, recurring: false, notes: ""),
                   account: "iCloud", subject: "Einladung: Projekt-Kickoff", status: "new", mailDate: Date()),
            Invite(messageId: "x2", event: InviteEvent(uid: "u2", summary: "Wöchentliches Team-Meeting", start: nextTue.addingTimeInterval(86400), end: nextTue.addingTimeInterval(86400 + 1800),
                                                       allDay: false, location: "Teams", organizer: "Karl-Heinz Hartmann", method: "REQUEST", cancelled: false, recurring: true, notes: ""),
                   account: "iCloud", subject: "Einladung: Team-Meeting", status: "new", mailDate: Date()),
            Invite(messageId: "x3", event: InviteEvent(uid: "u3", summary: "Webinar Informationssicherheit", start: nextTue.addingTimeInterval(3 * 86400), end: nextTue.addingTimeInterval(3 * 86400 + 3600),
                                                       allDay: false, location: "", organizer: "Reisdorf", method: "CANCEL", cancelled: true, recurring: false, notes: ""),
                   account: "iCloud", subject: "Abgesagt: Webinar", status: "new", mailDate: Date()),
        ]
        planLimits = PlanLimits(fiveHour: PlanWindow(utilization: 0.72, resetsAt: Date().addingTimeInterval(2 * 3600), status: "allowed"),
                                sevenDay: PlanWindow(utilization: 0.69, resetsAt: Date().addingTimeInterval(3 * 86400), status: "allowed"), updatedAt: Date())
        usageToday = UsageSummary(calls: 38, failures: 1, inputTokens: 61_400, outputTokens: 9_800, cacheReadTokens: 120_000, costUSD: 1.42, avgSeconds: 6.3)
        var st = WeeklyStats(from: Date().addingTimeInterval(-7 * 86400), to: Date())
        st.received = 142; st.receivedPrevious = 118; st.sent = 31; st.sentPrevious = 36
        st.categories = [CategoryDelta(name: "Newsletter", now: 48, previous: 29), CategoryDelta(name: "Benachrichtigungen", now: 40, previous: 38),
                         CategoryDelta(name: "Rechnungen", now: 7, previous: 11), CategoryDelta(name: "Handlung nötig", now: 12, previous: 9)]
        st.medianReplyHours = 5.4; st.replySamples = 17; st.openNeedsReply = 3; st.openWaiting = 14
        st.lateReplies = [ThreadAge(threadKey: "a", subject: "Contract Opportunity – Luxembourg", counterpart: "Portia Hotchkiss", days: 2)]
        st.overdueWaiting = [ThreadAge(threadKey: "b", subject: "Fragenkatalog Informationssicherheit", counterpart: "alain.kremer@reisdorf.lu", days: 6),
                             ThreadAge(threadKey: "c", subject: "Akku", counterpart: "Karl-Heinz Hartmann", days: 8)]
        st.invoicesNew = 3; st.invoicesNewTotal = ["EUR": 1330.45]; st.invoicesOverdue = 1; st.invoicesOverdueTotal = ["EUR": 1235]
        weeklyReport = WeeklyReport(date: Date(), text: "## Überblick\nDiese Woche kamen 142 Mails (+24). Der Zuwachs liegt fast allein bei Newslettern.\n\n## Hier bist du säumig\n- **Contract Opportunity – Luxembourg** (Portia Hotchkiss): seit 2 Tagen offen.\n\n## Empfehlung\n- Newsletter-Absender prüfen, die du nie öffnest.\n- Fragenkatalog nachfassen.", stats: st)
        corrections = [
            Correction(id: 1, date: Date().addingTimeInterval(-1800), messageId: "a", subject: "Ihre Rechnung Oktober", senderEmail: "news@shop.example",
                       fromCategory: "Newsletter", toCategory: "Rechnungen", toInbox: false, source: "mail"),
            Correction(id: 2, date: Date().addingTimeInterval(-86400), messageId: "b", subject: "Angebot für Ihr Projekt", senderEmail: "angebote@partner.example",
                       fromCategory: "Werbung", toCategory: nil, toInbox: true, source: "mail"),
            Correction(id: 3, date: Date().addingTimeInterval(-172800), messageId: "c", subject: "Lieferung unterwegs", senderEmail: "a@lieferant.example",
                       fromCategory: "Benachrichtigungen", toCategory: "Bestellungen", toInbox: false, source: "app"),
        ]
    }

    // MARK: Start & Zeitplan

    private var started = false

    func start() {
        guard !started else { return }
        started = true
        requestNotificationPermission()
        Task {
            await refreshAccounts()
            reload()
            // Nur Oberfläche anzeigen – kein Scan, keine Änderungen an Mail.
            if CommandLine.arguments.contains("--ui-preview") {
                status = "Vorschau – Automatik aus"
                return
            }
            // Verschiebe-Schutz früh auswerten (nur lesend), damit die Konten sofort ihren Status zeigen.
            for account in enabledAccountNames { _ = await moveGate(account) }
            await syncContacts()
            reload()
            if initialComplete { schedule() } else { await runInitialScan() }
        }
    }

    private func schedule() {
        loop?.cancel()
        guard initialComplete else { return }
        guard !paused else { status = "Pausiert"; return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.runCycle()
                let minutes = self?.settings.pollMinutes ?? 5
                try? await Task.sleep(for: .seconds(max(1, minutes) * 60))
            }
        }
    }

    // MARK: Erstscan

    /// Katalogisiert die kompletten Posteingänge aller freigegebenen, noch nicht gescannten Konten und sortiert sie ein.
    /// Wird bei Abbruch beim nächsten Start fortgesetzt; kommen währenddessen Konten hinzu, folgt ein weiterer Scan.
    func runInitialScan() async {
        guard !isRunning else { return }
        let targets = pendingScanAccounts
        guard !targets.isEmpty else { schedule(); return }
        loop?.cancel()
        isRunning = true

        while true {
            do {
                guard let claude else { throw ClaudeError.notFound }
                lastError = nil
                try await initialPass(claude: claude, accounts: targets)
                status = "Erstscan: erstelle Briefing …"
                try? await generateBriefing(claude: claude)
                scannedAccounts.formUnion(targets)
                initialProgress = nil
                status = "Erstscan abgeschlossen"
                let c = store.progressCounts(accounts: targets)
                notify(title: "MailPilot: Erstscan abgeschlossen",
                       body: "\(c.analyzed) Mails katalogisiert, \(c.moved) einsortiert.", id: "initial")
                break
            } catch {
                if case ClaudeError.blocked(let reason) = error {
                    lastError = nil
                    status = "Erstscan pausiert: \(reason) – nächster Versuch in 5 Minuten"
                } else {
                    lastError = error.localizedDescription
                    status = "Erstscan unterbrochen – neuer Versuch in 5 Minuten"
                }
                try? await Task.sleep(for: .seconds(300))
            }
        }

        isRunning = false
        lastRun = Date()
        reload()
        if pendingScanAccounts.isEmpty { schedule() } else { await runInitialScan() }
    }

    private func initialPass(claude: ClaudeClient, accounts: [String]) async throws {
        progressAccounts = accounts
        status = "Erstscan: gleiche Postfächer ab …"
        await syncClientAccounts(accounts)
        var next: FetchResult? = try await fetchInitial(accounts: accounts)
        var emptyRounds = 0
        while let result = next {
            if result.messages.isEmpty {
                emptyRounds += 1
                if result.remaining == 0 || emptyRounds > 3 { break }
            } else {
                emptyRounds = 0
            }
            try ingest(result)
            updateProgress(remaining: result.remaining)

            // Nächsten Block schon lesen, während Claude den aktuellen analysiert.
            let prefetch: Task<FetchResult, Error>? = result.remaining > 0 ? Task { try await self.fetchInitial(accounts: accounts) } : nil
            try await analyzePending(claude: claude)
            next = try await prefetch?.value
            try await applyPendingActions(initial: true)
            updateProgress(remaining: next?.remaining ?? 0)
        }
        // Reste (z. B. fehlgeschlagene Analysen aus früheren Versuchen) abarbeiten.
        try await analyzePending(claude: claude)
        try await applyPendingActions(initial: true)
    }

    private func fetchInitial(accounts: [String]) async throws -> FetchResult {
        let known = try store.knownMessageIds(since: .distantPast)
        let sentSince = Date().addingTimeInterval(-Double(max(settings.lookbackDays, 30)) * 86400)
        // Neueste zuerst, und auf Wunsch nur die letzten X Tage: spart Claude-Aufrufe, das Wichtige kommt zuerst dran.
        let minDate = settings.initialScanDays > 0 ? Date().addingTimeInterval(-Double(settings.initialScanDays) * 86400) : nil
        return try await fetchMail(since: Date(timeIntervalSince1970: 0), sentSince: sentSince, accounts: accounts,
                                   known: known, maxNew: 150, includeSent: settings.includeSent, contentLimit: 3000,
                                   newestFirst: true, minDate: minDate)
    }

    /// Konten, auf die sich die Fortschrittsanzeige des laufenden Erstscans bezieht.
    private var progressAccounts: [String] = []

    private func updateProgress(remaining: Int) {
        let c = store.progressCounts(accounts: progressAccounts)
        initialProgress = InitialProgress(total: c.total + remaining, analyzed: c.analyzed, moved: c.moved)
        status = "Erstscan: \(c.analyzed) von \(c.total + remaining) analysiert, \(c.moved) einsortiert"
    }

    // MARK: Regulärer Durchlauf

    func runCycle() async {
        guard initialComplete else { return }
        guard !isRunning else { return }
        guard let claude else { lastError = ClaudeError.notFound.localizedDescription; return }
        isRunning = true
        lastError = nil
        defer { isRunning = false; lastRun = Date(); reload() }

        do {
            await wakeSnoozedThreads()
            status = "Lese Postfächer …"
            await syncClientAccounts(enabledAccountNames)
            let since = Date().addingTimeInterval(-Double(settings.lookbackDays) * 86400)
            let known = try store.knownMessageIds(since: since.addingTimeInterval(-86400))
            let result = try await fetchMail(since: since, accounts: enabledAccountNames, known: known, maxNew: settings.maxPerCycle,
                                             includeSent: settings.includeSent)
            try ingest(result)
            // Auch bei Pause oder Claude-Fehler wird angewendet, was lokal entschieden wurde; der Fehler folgt danach.
            let catchUp = store.value("catchUp") != nil || queueAgedForArchive() > 0
            try await CyclePipeline.run(analyze: { try await self.analyzePending(claude: claude) }, apply: {
                try await self.applyPendingActions(initial: false, catchUp: catchUp)
                if catchUp { self.store.setValue(nil, for: "catchUp") }
            })
            status = "Prüfe Korrekturen …"
            await syncCorrections()
            checkFollowUps()
            await generateFollowUps()
            await syncDeadlines()
            await extractInvoices(limit: 6)
            await scanInvites(limit: 5)
            await learnStyleIfNeeded()
            await weeklyReportIfDue()
            await syncReadStateIfDue()
            backupIfDue()
            try await briefingIfDue(claude: claude)
            status = result.remaining > 0 ? "\(result.remaining) weitere Mails im nächsten Durchlauf" : "Aktuell"
        } catch {
            if case ClaudeError.blocked(let reason) = error {
                // Bewusste Pause (Abo-Limit): kein Fehler, nur Hinweis.
                lastError = nil
                status = "Pausiert: \(reason)"
            } else {
                lastError = error.localizedDescription
                status = "Fehler"
            }
        }
    }

    private func ingest(_ result: FetchResult) throws {
        if !result.myAddresses.isEmpty {
            myAddresses = Array(Set(result.myAddresses)).sorted()
            store.setValue(myAddresses.joined(separator: ","), for: "myAddresses")
        }
        let mine = Set(myAddresses)
        for raw in result.messages { try store.insert(raw, myAddresses: mine) }
    }

    // MARK: Analyse

    /// Analysiert alle noch offenen Nachrichten: neuere einzeln (mit Verlauf und Entwurf), ältere in Paketen.
    private func analyzePending(claude: ClaudeClient) async throws {
        let pending = try store.unprocessedMessages(limit: 100_000, accounts: enabledAccountNames)
        guard !pending.isEmpty else { return }
        abortError = nil

        // Gesprächszuordnung nacheinander, damit Antworten im selben Block ihr Gespräch finden.
        var keyed: [(StoredMessage, String)] = []
        for m in pending {
            let key = try store.resolveThreadKey(for: m)
            try store.setThreadKey(key, for: m.messageId)
            if routeIfPrivate(m, key: key) { continue }
            if let v = localVerdict(m, key: key) {
                // Ohne Claude einsortiert: Header-Vorfilter oder Absender-Gedächtnis.
                try? record(m, key: key, analysis: Prefilter.analysis(for: m, v), source: v.source)
                continue
            }
            keyed.append((m, key))
        }

        let cutoff = Date().addingTimeInterval(-detailedDays * 86400)
        let old = keyed.filter { $0.0.date < cutoff }
        let recent = keyed.filter { $0.0.date >= cutoff }

        let size = max(1, settings.batchSize)
        let chunks = stride(from: 0, to: old.count, by: size).map { Array(old[$0..<min($0 + size, old.count)]) }
        // Ältere Mails im Paket mit dem günstigeren Modell.
        let bulk = claudeBulk ?? claude
        await runConcurrently(chunks, limit: 3) { chunk in
            await self.analyzeChunk(chunk, claude: bulk)
        }
        if let abortError { throw abortError }

        // Pro Gespräch nacheinander, verschiedene Gespräche parallel.
        var groups: [String: [(StoredMessage, String)]] = [:]
        var order: [String] = []
        for item in recent {
            if groups[item.1] == nil { order.append(item.1) }
            groups[item.1, default: []].append(item)
        }
        await runConcurrently(order.map { groups[$0]! }, limit: 3) { group in
            for (m, key) in group where self.abortError == nil {
                await self.analyzeSingle(m, key: key, claude: claude)
            }
        }
        if let abortError { throw abortError }
    }

    private func analyzeChunk(_ chunk: [(StoredMessage, String)], claude: ClaudeClient) async {
        guard abortError == nil else { return }
        do {
            let results = try await claude.classifyBatch(chunk.map(\.0), settings: settings, myAddresses: myAddresses,
                                                      hints: chunk.map { Learner.hints(for: $0.0, store: store, settings: settings) })
            for (i, (m, key)) in chunk.enumerated() {
                if let a = results[i] {
                    try record(m, key: key, analysis: a)
                } else {
                    try store.markFailed(m.messageId, error: "Keine Analyse erhalten", giveUp: true)
                }
            }
        } catch {
            handle(error, for: chunk.map(\.0))
        }
        if initialProgress != nil { updateProgress(remaining: initialProgress.map { $0.total - store.progressCounts(accounts: progressAccounts).total } ?? 0) }
    }

    private func analyzeSingle(_ m: StoredMessage, key: String, claude: ClaudeClient) async {
        guard abortError == nil else { return }
        do {
            let existing = try store.thread(key)
            let history = try store.messages(inThread: key, limit: 6)
            let a = try await claude.analyze(message: m, thread: existing, history: history,
                                             settings: settings, myAddresses: myAddresses,
                                             hints: Learner.hints(for: m, store: store, settings: settings),
                                             styleGuide: settings.useStyleProfile ? styleProfile : "",
                                             freeSlots: freeSlotTexts(for: history + [m], force: false))
            try record(m, key: key, analysis: a)
        } catch {
            handle(error, for: [m])
        }
        if initialProgress != nil { updateProgress(remaining: initialProgress.map { $0.total - store.progressCounts(accounts: progressAccounts).total } ?? 0) }
        threads = (try? store.threads(accounts: enabledAccountNames)) ?? threads
    }

    private func handle(_ error: Error, for messages: [StoredMessage]) {
        if let e = error as? ClaudeError, e.isBlocking {
            // Login-, Limit- oder CLI-Probleme betreffen alle Nachrichten – später erneut versuchen.
            for m in messages { try? store.markFailed(m.messageId, error: error.localizedDescription, giveUp: false) }
            abortError = abortError ?? error
        } else {
            for m in messages { try? store.markFailed(m.messageId, error: error.localizedDescription, giveUp: true) }
        }
    }

    /// Speichert das Analyse-Ergebnis an der Nachricht und aktualisiert das Gespräch.
    private func record(_ m: StoredMessage, key: String, analysis claude: MessageAnalysis, source: String = "Claude") throws {
        // Eigene Regeln und VIP-Liste haben Vorrang vor Claudes Einschätzung.
        let effect = RuleEngine.evaluate(m, settings: settings)
        var a = claude
        if let c = effect.category { a.category = c }
        if let p = effect.priority { a.priority = p }
        try store.saveAnalysis(of: m.messageId, threadKey: key, category: m.isFromMe ? nil : a.category,
                               priority: a.priority, summary: a.summary, decidedBy: m.isFromMe ? nil : (effect.decidedBy ?? source))

        let existing = try store.thread(key)
        let isLatest = existing.map { m.date >= $0.lastDate } ?? true
        let counterpart = m.isFromMe ? (m.recipients.first.map { contactName($0) } ?? "") : displayName(m)
        var t = existing ?? MailThread(
            threadKey: key, subject: m.subject, normSubject: MailAddress.normalizeSubject(m.subject),
            counterpart: counterpart, lastDate: m.date, lastFromMe: m.isFromMe, messageCount: 0,
            status: a.thread_status, summary: "", nextStep: "", dueDate: nil, priority: a.priority,
            category: nil, draft: nil, draftFor: nil, followupNotified: false)
        t.messageCount += 1
        if isLatest || t.summary.isEmpty { t.summary = a.thread_summary }
        if isLatest {
            t.subject = m.subject
            t.lastDate = m.date
            t.lastFromMe = m.isFromMe
            if !counterpart.isEmpty { t.counterpart = counterpart }
            t.status = a.thread_status
            t.nextStep = a.next_step
            t.priority = a.priority
            t.followupNotified = false
            if m.isFromMe {
                t.draft = nil
                t.draftFor = nil
                t.draftKind = nil
            } else {
                // Eine neue Nachricht holt zurückgestellte Gespräche zurück und macht Nachfass-Entwürfe hinfällig.
                t.snoozedUntil = nil
                if t.draftKind == "followup" { t.draft = nil; t.draftFor = nil; t.draftKind = nil }
                if let draft = a.reply_draft, !draft.isEmpty, a.needs_reply, settings.autoDrafts {
                    t.draft = draft
                    t.draftFor = m.messageId
                    t.draftKind = "reply"
                }
            }
        }
        if let due = a.due_date, !due.isEmpty { t.dueDate = due }
        if !m.isFromMe { t.category = a.category }
        try store.upsert(t)

        let fresh = m.date > Date().addingTimeInterval(-Double(settings.lookbackDays) * 86400)
        if initialComplete, fresh, !m.isFromMe {
            if effect.vip, settings.vipNotify {
                notify(title: "VIP: \(m.senderName)", body: "\(m.subject)\n\(a.summary)", id: m.messageId, thread: key)
            } else if a.priority == .high, a.needs_reply {
                notify(title: "Wichtig: \(m.senderName)", body: "\(m.subject)\n\(a.summary)", id: m.messageId, thread: key)
            }
        }
    }

    // MARK: Aktionen in Mail

    /// Wendet Ordner und Flaggen auf alle analysierten, noch nicht bearbeiteten Mails an – stapelweise.
    /// `catchUp`: nachgeholte Aktionen (Ende des Probelaufs, Archivierung) – Flaggen nur für aktuelle Mails, wie im Erstscan.
    func applyPendingActions(initial: Bool, retro: Bool = false, catchUp: Bool = false) async throws {
        let flagCutoff = Date().addingTimeInterval(-detailedDays * 86400)
        let archiveCutoff = Date().addingTimeInterval(-Double(settings.archiveAfterDays) * 86400)

        while true {
            let pending = try store.pendingActions(limit: 50, accounts: enabledAccountNames)
            if pending.isEmpty { return }
            var items: [MailBridge.BatchItem] = []
            var byId: [String: StoredMessage] = [:]
            // Pro Konto: darf verschoben werden? (Zielordner zurücklesbar, Probe-Mail oder nur markieren)
            var gates: [String: MoveGate] = [:]
            for account in Set(pending.map(\.account)) { gates[account] = await moveGate(account) }
            var canaryUsed = Set<String>()

            for m in pending {
                let rule = settings.category(named: m.category)
                let effect = RuleEngine.evaluate(m, settings: settings)
                // Gmail meldet Posteingangsmails im Ordner „Alle Nachrichten“; Verschieben würde dort nur Labels ändern.
                let isGmailAllMail = ["alle nachrichten", "all mail", "[gmail]/alle nachrichten", "[gmail]/all mail"].contains(m.mailbox.lowercased())

                var target: String?
                if settings.autoMove, !isGmailAllMail, !m.account.isEmpty {
                    if effect.keepInInbox {
                        // Nicht sortieren; lag die Mail schon in einem Claude-Ordner, zurück in den Posteingang.
                        if !settings.folderPrefix.isEmpty, m.mailbox.hasPrefix(settings.folderPrefix) { target = MailBridge.inboxToken }
                    } else if let f = effect.folder {
                        target = settings.folderPrefix + f
                    } else if let rule, let folder = settings.folderPath(for: rule) {
                        target = folder
                    } else if settings.archiveAfterDays > 0, m.date < archiveCutoff, !settings.archiveFolder.isEmpty,
                              let key = m.threadKey, let t = try store.thread(key), t.status == .info || t.status == .done {
                        target = settings.folderPrefix + settings.archiveFolder
                    }
                    if target == m.mailbox { target = nil }
                }

                // Beim Erstscan nur aktuelle Mails markieren, sonst würden hunderte alte Flaggen entstehen.
                if target != nil {
                    switch gates[m.account] ?? .canary {
                    case .allowed:
                        break
                    case .blocked:
                        target = nil
                    case .canary:
                        if settings.dryRun { break }
                        // Erst eine Probe-Mail verschieben und verifizieren; der Rest folgt im nächsten Durchgang.
                        if canaryUsed.contains(m.account) { continue }
                        canaryUsed.insert(m.account)
                    }
                }

                var flag: FlagColor?
                if settings.autoFlag {
                    if let f = effect.flag {
                        flag = f
                    } else if !(initial || retro || catchUp) || m.date >= flagCutoff {
                        flag = m.priority == .high ? .red : rule?.flag
                    }
                }
                let targetLabel = target == MailBridge.inboxToken ? "Posteingang" : target

                if target == nil && flag == nil {
                    try store.markActioned(m.messageId)
                    continue
                }
                if settings.dryRun {
                    if let flag { store.log(m, kind: "flag", detail: "Würde \(flag.label) markieren (\(m.category ?? ""))", dryRun: true) }
                    if let target, let targetLabel {
                        store.log(m, kind: "move", detail: "Würde nach „\(targetLabel)“ verschieben", from: m.mailbox,
                                  to: target == MailBridge.inboxToken ? nil : target, dryRun: true)
                    }
                    // Nur durchgespielt: Nach dem Probelauf werden diese Mails noch einsortiert.
                    try store.markDryRun(m.messageId)
                    continue
                }
                items.append(.init(messageId: m.messageId,
                                   location: .init(account: m.account, mailbox: m.mailbox, mailId: m.mailId),
                                   target: target, flag: flag))
                byId[m.messageId] = m
            }

            guard !items.isEmpty else { continue }
            if initial || retro || catchUp { status = "\(retro ? "Regeln anwenden" : (catchUp ? "Nachholen" : "Erstscan")): sortiere \(items.count) Mails ein …" }
            let results = try await runBatch(items)
            var moveStats: [String: (moved: Int, lost: Int)] = [:]
            for (item, r) in zip(items, results) {
                guard let m = byId[item.messageId] else { continue }
                if r.ok {
                    if let flag = item.flag {
                        let extra = r.prevFlagged.map { ActivityEntry.flagExtra(flagged: $0, index: r.prevFlagIndex ?? -1) }
                        store.log(m, kind: "flag", detail: "\(flag.label) markiert (\(m.category ?? ""))", dryRun: false, extra: extra)
                    }
                    if let target = item.target {
                        let found = r.verified ?? true
                        moveStats[m.account, default: (0, 0)].moved += 1
                        if !found {
                            moveStats[m.account, default: (0, 0)].lost += 1
                            store.log(m, kind: "error",
                                      detail: "Verschoben, aber im Zielordner „\(target == MailBridge.inboxToken ? "Posteingang" : target)“ nicht wiederzufinden – bitte in Mail prüfen",
                                      dryRun: false)
                        }
                        if target == MailBridge.inboxToken {
                            try store.updateLocation(m.messageId, mailbox: r.mailbox ?? "Posteingang", mailId: r.newId ?? 0)
                            store.log(m, kind: "move", detail: "Zurück in den Posteingang gelegt", from: m.mailbox, to: nil, dryRun: false)
                        } else {
                            try store.updateLocation(m.messageId, mailbox: r.mailbox ?? target, mailId: r.newId ?? 0)
                            store.log(m, kind: "move", detail: "Nach „\(target)“ verschoben", from: m.mailbox, to: target, dryRun: false)
                        }
                    }
                } else {
                    store.log(m, kind: "error", detail: "Fehlgeschlagen: \(r.error ?? "unbekannt")", dryRun: false)
                }
                try store.markActioned(m.messageId)
            }
            // Ergebnis der Verifikation: Probe bestanden → Konto freigeben; Mails nicht auffindbar → Konto sperren.
            for (account, s) in moveStats {
                let probe = gates[account] == .canary
                if s.lost > 0 && (probe || s.lost * 2 >= s.moved) {
                    setMoveStatus(account, "blocked", detail: "\(s.lost) von \(s.moved) verschobenen Mails waren im Zielordner nicht zurücklesbar")
                } else if probe && s.moved > 0 && s.lost == 0 {
                    setMoveStatus(account, "ok", detail: nil)
                }
            }
            activity = (try? store.activity()) ?? activity
        }
    }

    private func runConcurrently<T>(_ items: [T], limit: Int, _ body: @escaping @MainActor (T) async -> Void) async {
        await withTaskGroup(of: Void.self) { group in
            var it = items.makeIterator()
            for _ in 0..<limit {
                guard let x = it.next() else { break }
                group.addTask { await body(x) }
            }
            while await group.next() != nil {
                if let x = it.next() { group.addTask { await body(x) } }
            }
        }
    }

    // MARK: Benutzeraktionen

    func setStatus(_ status: ThreadStatus, for thread: MailThread) {
        var t = thread
        t.status = status
        try? store.upsert(t)
        reload()
    }

    func saveDraft(_ text: String, for thread: MailThread) {
        var t = thread
        t.draft = text
        try? store.upsert(t)
        reload()
    }

    /// Öffnet in Mail ein Antwortfenster mit dem Entwurf. Gesendet wird ausschließlich vom Nutzer.
    /// Öffnet ein Antwortfenster in Mail – oder legt die Antwort mit `save` still als Entwurf ab.
    func openReply(for thread: MailThread, text: String, save: Bool = false) async {
        if thread.draftKind == "followup" || thread.isFollowUpCase {
            await openFollowUp(for: thread, text: text, save: save)
            return
        }
        let msgs = messages(in: thread)
        guard let target = msgs.last(where: { $0.messageId == thread.draftFor }) ?? msgs.last(where: { !$0.isFromMe }) else {
            lastError = "Keine eingegangene Nachricht in diesem Gespräch gefunden."
            return
        }
        if let account = clientAccount(named: target.account) {
            await clientReply(to: target, account: account, text: text, replyAll: target.recipients.count > 1, save: save)
            return
        }
        do {
            let loc = MailBridge.Location(account: target.account, mailbox: target.mailbox, mailId: target.mailId)
            try await bridge.openReply(messageId: target.messageId, at: loc, text: text, replyAll: target.recipients.count > 1, save: save)
            if save { status = "Antwort als Entwurf in Mail abgelegt – dort noch prüfen und senden." }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func redraft(_ thread: MailThread, hint: String, interactive: Bool = true, forceSlots: Bool = false) async -> String? {
        if thread.isPrivate {
            lastError = "Dieses Gespräch ist vom Datenschutz ausgenommen – Claude erhält keinen Inhalt."
            return nil
        }
        guard let claude = (interactive ? claudeInteractive : self.claude) else { lastError = ClaudeError.notFound.localizedDescription; return nil }
        do {
            let msgs = messages(in: thread)
            let followUp = thread.isFollowUpCase
            let style = styleContext(for: thread, messages: msgs, examples: true)
            let slots = followUp ? [] : freeSlotTexts(for: msgs, force: forceSlots)
            let text = try await claude.redraft(thread: thread, messages: msgs, hint: hint, settings: settings, followUp: followUp,
                                                styleGuide: style.guide, examples: style.examples, freeSlots: slots)
            var t = thread
            t.draft = text
            if followUp {
                t.draftKind = "followup"
                t.draftFor = msgs.last(where: { $0.isFromMe })?.messageId
            } else {
                t.draftKind = "reply"
                if t.draftFor == nil { t.draftFor = msgs.last(where: { !$0.isFromMe })?.messageId }
            }
            try store.upsert(t)
            reload()
            return text
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    func undo(_ entry: ActivityEntry) async {
        if entry.canUndoFlag { await undoFlags([entry]); return }
        guard entry.canUndoMove, let from = entry.fromMailbox, let to = entry.toMailbox,
              let m = try? store.message(id: entry.messageId) else { return }
        do {
            let back = try await moveMessage(m, from: to, to: from)
            try store.updateLocation(m.messageId, mailbox: back.mailbox, mailId: back.mailId)
            try store.markUndone(entry.id)
            store.log(m, kind: "undo", detail: "Zurück nach „\(from)“ verschoben", from: to, to: from, dryRun: false)
            reload()
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: Briefing & Follow-ups

    private func briefingIfDue(claude: ClaudeClient) async throws {
        let cal = Calendar.current
        guard cal.component(.hour, from: Date()) >= settings.briefingHour else { return }
        if let b = briefing, cal.isDateInToday(b.date) { return }
        try await generateBriefing(claude: claude)
        notify(title: "Dein Mail-Briefing ist da", body: "\(needsReply.count) brauchen eine Antwort, \(overdue.count) Follow-ups überfällig.", id: "briefing")
    }

    func generateBriefing() async {
        guard let claude = claudeInteractive else { lastError = ClaudeError.notFound.localizedDescription; return }
        do { try await generateBriefing(claude: claude) } catch { lastError = error.localizedDescription }
    }

    private func generateBriefing(claude: ClaudeClient) async throws {
        isBriefing = true
        defer { isBriefing = false }
        // Vertrauliche Gespräche (auch Betreff und Absender) gehören nie in die Anfrage an Claude.
        let open = threads.filter { !$0.isPrivate && !$0.isSnoozed && ($0.status == .needsReply || $0.status == .waiting || $0.dueDate != nil && $0.status != .done) }
        let newCount = store.countMessages(since: Date().addingTimeInterval(-86400))
        let text = try await claude.briefing(threads: Array(open.prefix(60)), newCount: newCount, settings: settings,
                                          invoices: invoices.filter { $0.isOverdue() || $0.isDue(within: 14) })
        try store.saveBriefing(text)
        reload()
    }

    private func checkFollowUps() {
        for var t in overdue where !t.followupNotified {
            notify(title: "Keine Antwort seit \(settings.followUpDays)+ Tagen", body: "\(t.subject) – \(t.counterpart)", id: "followup-\(t.threadKey)", thread: t.threadKey)
            t.followupNotified = true
            try? store.upsert(t)
        }
    }

    // MARK: Mitteilungen

    private func requestNotificationPermission() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.setNotificationCategories([NotificationAction.category])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Mitteilung; mit `thread` trägt sie die Knöpfe „Antworten“, „Zurückstellen“ und „Erledigt“.
    func notify(title: String, body: String, id: String, thread: String? = nil) {
        guard settings.notifications, Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let thread {
            content.categoryIdentifier = NotificationAction.categoryID
            content.userInfo = ["threadKey": thread]
        }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    func testClaude() async -> String {
        guard let claude = claudeInteractive else { return ClaudeError.notFound.localizedDescription }
        do {
            let r = try await claude.ping()
            return "Verbindung ok (\(claude.executable)): \(r)"
        } catch {
            return error.localizedDescription
        }
    }
}

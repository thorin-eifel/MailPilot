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
            settings.save(to: Paths.settings)
            if oldValue.pollMinutes != settings.pollMinutes { schedule() }
            if oldValue.enabledAccounts != settings.enabledAccounts { accountsChanged() }
        }
    }
    /// Alle aktiven Konten in Apple Mail.
    @Published private(set) var accounts: [MailAccountInfo] = []
    @Published private(set) var threads: [MailThread] = []
    @Published private(set) var activity: [ActivityEntry] = []
    @Published private(set) var briefing: Briefing?
    @Published private(set) var isRunning = false
    @Published private(set) var isBriefing = false
    @Published private(set) var status = "Bereit"
    @Published private(set) var lastRun: Date?
    @Published private(set) var lastError: String?
    @Published private(set) var initialProgress: InitialProgress?
    @Published var paused = false { didSet { schedule() } }

    let store: Store
    let bridge = MailBridge()
    private var loop: Task<Void, Never>?
    private var myAddresses: [String]
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
        reload()
    }

    var claude: ClaudeClient? {
        ClaudeClient.locate(preferred: settings.claudePath).map { ClaudeClient(executable: $0, model: settings.model) }
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
        do {
            accounts = try await bridge.listAccounts()
        } catch {
            lastError = error.localizedDescription
        }
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

    var needsReply: [MailThread] { threads.filter { $0.status == .needsReply } }
    var waiting: [MailThread] { threads.filter { $0.status == .waiting } }
    var overdue: [MailThread] { waiting.filter { $0.isOverdue(followUpDays: settings.followUpDays) } }

    func messages(in thread: MailThread) -> [StoredMessage] {
        (try? store.messages(inThread: thread.threadKey)) ?? []
    }

    func reload() {
        threads = (try? store.threads(accounts: enabledAccountNames)) ?? []
        activity = (try? store.activity()) ?? []
        briefing = try? store.latestBriefing()
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
                lastError = error.localizedDescription
                status = "Erstscan unterbrochen – neuer Versuch in 5 Minuten"
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
        return try await bridge.fetch(since: Date(timeIntervalSince1970: 0), sentSince: sentSince, accounts: accounts,
                                      known: known, maxNew: 150, includeSent: settings.includeSent, contentLimit: 3000)
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
            status = "Lese Apple Mail …"
            let since = Date().addingTimeInterval(-Double(settings.lookbackDays) * 86400)
            let known = try store.knownMessageIds(since: since.addingTimeInterval(-86400))
            let result = try await bridge.fetch(since: since, accounts: enabledAccountNames, known: known, maxNew: settings.maxPerCycle,
                                                includeSent: settings.includeSent)
            try ingest(result)
            try await analyzePending(claude: claude)
            try await applyPendingActions(initial: false)
            checkFollowUps()
            try await briefingIfDue(claude: claude)
            status = result.remaining > 0 ? "\(result.remaining) weitere Mails im nächsten Durchlauf" : "Aktuell"
        } catch {
            lastError = error.localizedDescription
            status = "Fehler"
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
            keyed.append((m, key))
        }

        let cutoff = Date().addingTimeInterval(-detailedDays * 86400)
        let old = keyed.filter { $0.0.date < cutoff }
        let recent = keyed.filter { $0.0.date >= cutoff }

        let chunks = stride(from: 0, to: old.count, by: 10).map { Array(old[$0..<min($0 + 10, old.count)]) }
        await runConcurrently(chunks, limit: 3) { chunk in
            await self.analyzeChunk(chunk, claude: claude)
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
            let results = try await claude.classifyBatch(chunk.map(\.0), settings: settings, myAddresses: myAddresses)
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
                                             settings: settings, myAddresses: myAddresses)
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
    private func record(_ m: StoredMessage, key: String, analysis a: MessageAnalysis) throws {
        try store.saveAnalysis(of: m.messageId, threadKey: key, category: m.isFromMe ? nil : a.category,
                               priority: a.priority, summary: a.summary)

        let existing = try store.thread(key)
        let isLatest = existing.map { m.date >= $0.lastDate } ?? true
        let counterpart = m.isFromMe ? (m.recipients.first.map { MailAddress.parse($0).name ?? MailAddress.parse($0).email } ?? "") : m.senderName
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
            } else if let draft = a.reply_draft, !draft.isEmpty, a.needs_reply, settings.autoDrafts {
                t.draft = draft
                t.draftFor = m.messageId
            }
        }
        if let due = a.due_date, !due.isEmpty { t.dueDate = due }
        if !m.isFromMe { t.category = a.category }
        try store.upsert(t)

        let fresh = m.date > Date().addingTimeInterval(-Double(settings.lookbackDays) * 86400)
        if initialComplete, fresh, !m.isFromMe, a.priority == .high, a.needs_reply {
            notify(title: "Wichtig: \(m.senderName)", body: "\(m.subject)\n\(a.summary)", id: m.messageId)
        }
    }

    // MARK: Aktionen in Mail

    /// Wendet Ordner und Flaggen auf alle analysierten, noch nicht bearbeiteten Mails an – stapelweise.
    private func applyPendingActions(initial: Bool) async throws {
        let flagCutoff = Date().addingTimeInterval(-detailedDays * 86400)
        let archiveCutoff = Date().addingTimeInterval(-Double(settings.archiveAfterDays) * 86400)

        while true {
            let pending = try store.pendingActions(limit: 50, accounts: enabledAccountNames)
            if pending.isEmpty { return }
            var items: [MailBridge.BatchItem] = []
            var byId: [String: StoredMessage] = [:]

            for m in pending {
                let rule = settings.category(named: m.category)
                // Gmail meldet Posteingangsmails im Ordner „Alle Nachrichten“; Verschieben würde dort nur Labels ändern.
                let isGmailAllMail = ["alle nachrichten", "all mail", "[gmail]/alle nachrichten", "[gmail]/all mail"].contains(m.mailbox.lowercased())

                var target: String?
                if settings.autoMove, !isGmailAllMail, !m.account.isEmpty {
                    if let rule, let folder = settings.folderPath(for: rule) {
                        target = folder
                    } else if settings.archiveAfterDays > 0, m.date < archiveCutoff, !settings.archiveFolder.isEmpty,
                              let key = m.threadKey, let t = try store.thread(key), t.status == .info || t.status == .done {
                        target = settings.folderPrefix + settings.archiveFolder
                    }
                    if target == m.mailbox { target = nil }
                }

                // Beim Erstscan nur aktuelle Mails markieren, sonst würden hunderte alte Flaggen entstehen.
                var flag: FlagColor?
                if settings.autoFlag, !initial || m.date >= flagCutoff {
                    flag = m.priority == .high ? .red : rule?.flag
                }

                if target == nil && flag == nil {
                    try store.markActioned(m.messageId)
                    continue
                }
                if settings.dryRun {
                    if let flag { store.log(m, kind: "flag", detail: "Würde \(flag.label) markieren (\(m.category ?? ""))", dryRun: true) }
                    if let target { store.log(m, kind: "move", detail: "Würde nach „\(target)“ verschieben", from: m.mailbox, to: target, dryRun: true) }
                    try store.markActioned(m.messageId)
                    continue
                }
                items.append(.init(messageId: m.messageId,
                                   location: .init(account: m.account, mailbox: m.mailbox, mailId: m.mailId),
                                   target: target, flag: flag))
                byId[m.messageId] = m
            }

            guard !items.isEmpty else { continue }
            if initial { status = "Erstscan: sortiere \(items.count) Mails ein …" }
            let results = try await bridge.batch(items)
            for (item, r) in zip(items, results) {
                guard let m = byId[item.messageId] else { continue }
                if r.ok {
                    if let flag = item.flag {
                        store.log(m, kind: "flag", detail: "\(flag.label) markiert (\(m.category ?? ""))", dryRun: false)
                    }
                    if let target = item.target {
                        try store.updateLocation(m.messageId, mailbox: target, mailId: 0)
                        store.log(m, kind: "move", detail: "Nach „\(target)“ verschoben", from: m.mailbox, to: target, dryRun: false)
                    }
                } else {
                    store.log(m, kind: "error", detail: "Fehlgeschlagen: \(r.error ?? "unbekannt")", dryRun: false)
                }
                try store.markActioned(m.messageId)
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
    func openReply(for thread: MailThread, text: String) async {
        let msgs = messages(in: thread)
        guard let target = msgs.last(where: { $0.messageId == thread.draftFor }) ?? msgs.last(where: { !$0.isFromMe }) else {
            lastError = "Keine eingegangene Nachricht in diesem Gespräch gefunden."
            return
        }
        do {
            let loc = MailBridge.Location(account: target.account, mailbox: target.mailbox, mailId: target.mailId)
            try await bridge.openReply(messageId: target.messageId, at: loc, text: text, replyAll: target.recipients.count > 1)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func redraft(_ thread: MailThread, hint: String) async -> String? {
        guard let claude else { lastError = ClaudeError.notFound.localizedDescription; return nil }
        do {
            let text = try await claude.redraft(thread: thread, messages: messages(in: thread), hint: hint, settings: settings)
            var t = thread
            t.draft = text
            if t.draftFor == nil { t.draftFor = messages(in: thread).last(where: { !$0.isFromMe })?.messageId }
            try store.upsert(t)
            reload()
            return text
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    func undo(_ entry: ActivityEntry) async {
        guard entry.canUndo, let from = entry.fromMailbox, let to = entry.toMailbox,
              let m = try? store.message(id: entry.messageId) else { return }
        do {
            let loc = MailBridge.Location(account: m.account, mailbox: to, mailId: m.mailId)
            let back = try await bridge.move(messageId: m.messageId, from: loc, to: from)
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
        guard let claude else { lastError = ClaudeError.notFound.localizedDescription; return }
        do { try await generateBriefing(claude: claude) } catch { lastError = error.localizedDescription }
    }

    private func generateBriefing(claude: ClaudeClient) async throws {
        isBriefing = true
        defer { isBriefing = false }
        let open = threads.filter { $0.status == .needsReply || $0.status == .waiting || $0.dueDate != nil && $0.status != .done }
        let newCount = store.countMessages(since: Date().addingTimeInterval(-86400))
        let text = try await claude.briefing(threads: Array(open.prefix(60)), newCount: newCount, settings: settings)
        try store.saveBriefing(text)
        reload()
    }

    private func checkFollowUps() {
        for var t in overdue where !t.followupNotified {
            notify(title: "Keine Antwort seit \(settings.followUpDays)+ Tagen", body: "\(t.subject) – \(t.counterpart)", id: "followup-\(t.threadKey)")
            t.followupNotified = true
            try? store.upsert(t)
        }
    }

    // MARK: Mitteilungen

    private func requestNotificationPermission() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func notify(title: String, body: String, id: String) {
        guard settings.notifications, Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    func testClaude() async -> String {
        guard let claude else { return ClaudeError.notFound.localizedDescription }
        do {
            let r = try await claude.ping()
            return "Verbindung ok (\(claude.executable)): \(r)"
        } catch {
            return error.localizedDescription
        }
    }
}

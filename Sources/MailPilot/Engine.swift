import Foundation
import SwiftUI
import UserNotifications

/// Steuert den Abruf, die Analyse durch Claude und die automatischen Aktionen in Mail.
@MainActor
final class Engine: ObservableObject {
    static let shared = Engine()

    @Published var settings: AppSettings { didSet { settings.save(to: Paths.settings); if oldValue.pollMinutes != settings.pollMinutes { schedule() } } }
    @Published private(set) var threads: [MailThread] = []
    @Published private(set) var activity: [ActivityEntry] = []
    @Published private(set) var briefing: Briefing?
    @Published private(set) var isRunning = false
    @Published private(set) var isBriefing = false
    @Published private(set) var status = "Bereit"
    @Published private(set) var lastRun: Date?
    @Published private(set) var lastError: String?
    @Published var paused = false { didSet { schedule() } }

    let store: Store
    let bridge = MailBridge()
    private var loop: Task<Void, Never>?

    /// Mails, die vor dem ersten Start eingegangen sind, werden analysiert, aber nicht verschoben.
    private(set) var installDate: Date
    private var myAddresses: [String]

    private init() {
        do { store = try Store() } catch { fatalError("Datenbank: \(error)") }
        settings = AppSettings.load(from: Paths.settings)
        if let s = store.value("installDate"), let t = Double(s) {
            installDate = Date(timeIntervalSince1970: t)
        } else {
            installDate = Date()
            store.setValue(String(installDate.timeIntervalSince1970), for: "installDate")
        }
        myAddresses = (store.value("myAddresses") ?? "").split(separator: ",").map(String.init)
        reload()
    }

    var claude: ClaudeClient? {
        ClaudeClient.locate(preferred: settings.claudePath).map { ClaudeClient(executable: $0, model: settings.model) }
    }

    // MARK: Abgeleitete Werte

    var needsReply: [MailThread] { threads.filter { $0.status == .needsReply } }
    var waiting: [MailThread] { threads.filter { $0.status == .waiting } }
    var overdue: [MailThread] { waiting.filter { $0.isOverdue(followUpDays: settings.followUpDays) } }

    func messages(in thread: MailThread) -> [StoredMessage] {
        (try? store.messages(inThread: thread.threadKey)) ?? []
    }

    func reload() {
        threads = (try? store.threads()) ?? []
        activity = (try? store.activity()) ?? []
        briefing = try? store.latestBriefing()
    }

    // MARK: Zeitplan

    private var started = false

    func start() {
        guard !started else { return }
        started = true
        requestNotificationPermission()
        schedule()
    }

    private func schedule() {
        loop?.cancel()
        guard !paused else { status = "Pausiert"; return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.runCycle()
                let minutes = self?.settings.pollMinutes ?? 5
                try? await Task.sleep(for: .seconds(max(1, minutes) * 60))
            }
        }
    }

    // MARK: Zyklus

    func runCycle() async {
        guard !isRunning else { return }
        guard let claude else { lastError = ClaudeError.notFound.localizedDescription; return }
        isRunning = true
        lastError = nil
        defer { isRunning = false; lastRun = Date(); reload() }

        do {
            status = "Lese Apple Mail …"
            let since = Date().addingTimeInterval(-Double(settings.lookbackDays) * 86400)
            let known = try store.knownMessageIds(since: since.addingTimeInterval(-86400))
            let result = try await bridge.fetch(since: since, known: known, maxNew: settings.maxPerCycle,
                                                includeSent: settings.includeSent)
            if !result.myAddresses.isEmpty {
                myAddresses = Array(Set(result.myAddresses)).sorted()
                store.setValue(myAddresses.joined(separator: ","), for: "myAddresses")
            }
            let mine = Set(myAddresses)
            for raw in result.messages { try store.insert(raw, myAddresses: mine) }

            let pending = try store.unprocessedMessages(limit: settings.maxPerCycle)
            for (i, m) in pending.enumerated() {
                status = "Analysiere \(i + 1)/\(pending.count): \(m.subject.prefix(40))"
                do {
                    try await process(m, claude: claude)
                } catch let e as ClaudeError {
                    // Login- oder CLI-Probleme betreffen alle Nachrichten – Zyklus abbrechen.
                    try? store.markFailed(m.messageId, error: e.localizedDescription, giveUp: false)
                    throw e
                } catch {
                    try? store.markFailed(m.messageId, error: error.localizedDescription, giveUp: true)
                }
                threads = (try? store.threads()) ?? threads
            }

            checkFollowUps()
            try await briefingIfDue(claude: claude)
            status = result.remaining > 0 ? "\(result.remaining) weitere Mails im nächsten Durchlauf" : "Aktuell"
        } catch {
            lastError = error.localizedDescription
            status = "Fehler"
        }
    }

    private func process(_ m: StoredMessage, claude: ClaudeClient) async throws {
        let key = try store.resolveThreadKey(for: m)
        let existing = try store.thread(key)
        let history = try store.messages(inThread: key, limit: 6)
        let a = try await claude.analyze(message: m, thread: existing, history: history,
                                         settings: settings, myAddresses: myAddresses)

        try store.saveAnalysis(of: m.messageId, threadKey: key, category: m.isFromMe ? nil : a.category,
                               priority: a.priority, summary: a.summary)

        let isLatest = existing.map { m.date >= $0.lastDate } ?? true
        let counterpart = m.isFromMe ? (m.recipients.first.map { MailAddress.parse($0).name ?? MailAddress.parse($0).email } ?? "") : m.senderName
        var t = existing ?? MailThread(
            threadKey: key, subject: m.subject, normSubject: MailAddress.normalizeSubject(m.subject),
            counterpart: counterpart, lastDate: m.date, lastFromMe: m.isFromMe, messageCount: 0,
            status: a.thread_status, summary: "", nextStep: "", dueDate: nil, priority: a.priority,
            category: nil, draft: nil, draftFor: nil, followupNotified: false)
        t.messageCount += 1
        t.summary = a.thread_summary
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

        if !m.isFromMe {
            if m.date >= installDate {
                try await applyActions(to: m, analysis: a)
            }
            if a.priority == .high && a.needs_reply && m.date >= installDate {
                notify(title: "Wichtig: \(m.senderName)", body: "\(m.subject)\n\(a.summary)", id: m.messageId)
            }
        }
    }

    private func applyActions(to m: StoredMessage, analysis a: MessageAnalysis) async throws {
        let rule = settings.category(named: a.category)
        var loc = MailBridge.Location(account: m.account, mailbox: m.mailbox, mailId: m.mailId)
        let dry = settings.dryRun

        if settings.autoFlag, let color = a.priority == .high ? FlagColor.red : rule?.flag {
            if dry {
                store.log(m, kind: "flag", detail: "Würde \(color.label) markieren (\(a.category))", dryRun: true)
            } else {
                try await bridge.flag(messageId: m.messageId, at: loc, color: color)
                store.log(m, kind: "flag", detail: "\(color.label) markiert (\(a.category))", dryRun: false)
            }
        }

        // Gmail meldet Posteingangsmails im Ordner „Alle Nachrichten“; Verschieben würde dort nur Labels ändern.
        let isGmailAllMail = ["alle nachrichten", "all mail", "[gmail]/alle nachrichten", "[gmail]/all mail"].contains(m.mailbox.lowercased())
        if settings.autoMove, !isGmailAllMail, !m.account.isEmpty, let rule, let folder = settings.folderPath(for: rule), folder != m.mailbox {
            if dry {
                store.log(m, kind: "move", detail: "Würde nach „\(folder)“ verschieben", from: m.mailbox, to: folder, dryRun: true)
            } else {
                loc = try await bridge.move(messageId: m.messageId, from: loc, to: folder)
                try store.updateLocation(m.messageId, mailbox: loc.mailbox, mailId: loc.mailId)
                store.log(m, kind: "move", detail: "Nach „\(folder)“ verschoben", from: m.mailbox, to: folder, dryRun: false)
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

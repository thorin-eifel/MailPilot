import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct Row {
    fileprivate var values: [String: Any]

    func hasKey(_ k: String) -> Bool { values[k] != nil }
    func string(_ k: String) -> String? { values[k] as? String }
    func int(_ k: String) -> Int { Int(values[k] as? Int64 ?? 0) }
    func int64(_ k: String) -> Int64 { values[k] as? Int64 ?? 0 }
    func double(_ k: String) -> Double { values[k] as? Double ?? Double(values[k] as? Int64 ?? 0) }
    func bool(_ k: String) -> Bool { int(k) != 0 }
    func date(_ k: String) -> Date { Date(timeIntervalSince1970: double(k)) }
}

/// Dünne, thread-sichere SQLite-Hülle.
final class Database: @unchecked Sendable {
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "mailpilot.db")

    init(path: String) throws {
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            throw NSError(domain: "DB", code: 1, userInfo: [NSLocalizedDescriptionKey: "Datenbank konnte nicht geöffnet werden"])
        }
        try exec("PRAGMA journal_mode=WAL")
    }

    deinit { sqlite3_close(db) }

    func exec(_ sql: String, _ params: [Any?] = []) throws {
        _ = try query(sql, params)
    }

    @discardableResult
    func query(_ sql: String, _ params: [Any?] = []) throws -> [Row] {
        try queue.sync {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw lastError() }
            defer { sqlite3_finalize(stmt) }
            for (i, p) in params.enumerated() {
                let idx = Int32(i + 1)
                switch p {
                case nil: sqlite3_bind_null(stmt, idx)
                case let v as Bool: sqlite3_bind_int64(stmt, idx, v ? 1 : 0)
                case let v as Int: sqlite3_bind_int64(stmt, idx, Int64(v))
                case let v as Int64: sqlite3_bind_int64(stmt, idx, v)
                case let v as Double: sqlite3_bind_double(stmt, idx, v)
                case let v as Date: sqlite3_bind_double(stmt, idx, v.timeIntervalSince1970)
                case let v as String: sqlite3_bind_text(stmt, idx, v, -1, SQLITE_TRANSIENT)
                default: sqlite3_bind_text(stmt, idx, "\(p!)", -1, SQLITE_TRANSIENT)
                }
            }
            var rows: [Row] = []
            while true {
                let rc = sqlite3_step(stmt)
                if rc == SQLITE_DONE { break }
                guard rc == SQLITE_ROW else { throw lastError() }
                var values: [String: Any] = [:]
                for c in 0..<sqlite3_column_count(stmt) {
                    let name = String(cString: sqlite3_column_name(stmt, c))
                    switch sqlite3_column_type(stmt, c) {
                    case SQLITE_INTEGER: values[name] = sqlite3_column_int64(stmt, c)
                    case SQLITE_FLOAT: values[name] = sqlite3_column_double(stmt, c)
                    case SQLITE_TEXT: values[name] = String(cString: sqlite3_column_text(stmt, c))
                    default: break
                    }
                }
                rows.append(Row(values: values))
            }
            return rows
        }
    }

    var lastInsertId: Int64 { queue.sync { sqlite3_last_insert_rowid(db) } }

    private func lastError() -> Error {
        NSError(domain: "DB", code: 2, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
    }
}

/// Persistenz für Nachrichten, Gespräche, Aktivitäten und Briefings.
final class Store: @unchecked Sendable {
    let db: Database

    init(path: URL = Paths.database) throws {
        db = try Database(path: path.path)
        try migrate()
        try ensureSearchIndex()
    }

    private func migrate() throws {
        try db.exec("""
        CREATE TABLE IF NOT EXISTS messages (
            message_id TEXT PRIMARY KEY, mail_id INTEGER, account TEXT, mailbox TEXT,
            subject TEXT, sender TEXT, sender_email TEXT, recipients TEXT, date REAL,
            is_from_me INTEGER, in_reply_to TEXT, refs TEXT, content TEXT,
            thread_key TEXT, category TEXT, priority TEXT, summary TEXT,
            processed INTEGER DEFAULT 0, error TEXT)
        """)
        try db.exec("CREATE INDEX IF NOT EXISTS idx_msg_thread ON messages(thread_key)")
        try db.exec("CREATE INDEX IF NOT EXISTS idx_msg_date ON messages(date)")
        // Spalte nachrüsten: 1 = Ordner/Flagge wurden angewendet (oder bewusst übersprungen).
        try? db.exec("ALTER TABLE messages ADD COLUMN actioned INTEGER DEFAULT 0")
        try db.exec("""
        CREATE TABLE IF NOT EXISTS threads (
            thread_key TEXT PRIMARY KEY, subject TEXT, norm_subject TEXT, counterpart TEXT,
            last_date REAL, last_from_me INTEGER, message_count INTEGER, status TEXT,
            summary TEXT, next_step TEXT, due_date TEXT, priority TEXT, category TEXT,
            draft TEXT, draft_for TEXT, followup_notified INTEGER DEFAULT 0)
        """)
        try db.exec("""
        CREATE TABLE IF NOT EXISTS activity (
            id INTEGER PRIMARY KEY AUTOINCREMENT, ts REAL, message_id TEXT, subject TEXT,
            kind TEXT, detail TEXT, account TEXT, from_mailbox TEXT, to_mailbox TEXT,
            dry_run INTEGER, undone INTEGER DEFAULT 0)
        """)
        try db.exec("CREATE TABLE IF NOT EXISTS briefings (id INTEGER PRIMARY KEY AUTOINCREMENT, ts REAL, text TEXT)")
        try db.exec("CREATE TABLE IF NOT EXISTS kv (key TEXT PRIMARY KEY, value TEXT)")
        try? db.exec("ALTER TABLE activity ADD COLUMN extra TEXT")
        try? db.exec("ALTER TABLE messages ADD COLUMN is_read INTEGER")
        try? db.exec("ALTER TABLE messages ADD COLUMN unsub TEXT")
        try? db.exec("ALTER TABLE messages ADD COLUMN unsub_post TEXT")
        try? db.exec("ALTER TABLE threads ADD COLUMN is_private INTEGER DEFAULT 0")
        try? db.exec("ALTER TABLE messages ADD COLUMN is_private INTEGER DEFAULT 0")
        try? db.exec("ALTER TABLE threads ADD COLUMN snoozed_until REAL")
        try? db.exec("ALTER TABLE threads ADD COLUMN draft_kind TEXT")
        try? db.exec("ALTER TABLE messages ADD COLUMN decided_by TEXT")
        try? db.exec("ALTER TABLE messages ADD COLUMN moved_at REAL")
        try db.exec("""
        CREATE TABLE IF NOT EXISTS corrections (
            id INTEGER PRIMARY KEY AUTOINCREMENT, ts REAL, message_id TEXT, subject TEXT, account TEXT,
            sender_email TEXT, domain TEXT, from_category TEXT, to_category TEXT, to_inbox INTEGER DEFAULT 0, source TEXT)
        """)
        try db.exec("""
        CREATE TABLE IF NOT EXISTS exports (
            id INTEGER PRIMARY KEY AUTOINCREMENT, thread_key TEXT, due_date TEXT, kind TEXT, ext_id TEXT, ts REAL,
            UNIQUE(thread_key, due_date, kind))
        """)
        try db.exec("""
        CREATE TABLE IF NOT EXISTS invoices (
            message_id TEXT PRIMARY KEY, thread_key TEXT, account TEXT, sender TEXT, sender_email TEXT, subject TEXT, mail_date REAL,
            vendor TEXT, number TEXT, amount REAL, vat REAL, currency TEXT, issue_date TEXT, due_date TEXT, description TEXT,
            source TEXT, file_name TEXT, paid INTEGER DEFAULT 0, status TEXT, error TEXT, ts REAL)
        """)
        try db.exec("""
        CREATE TABLE IF NOT EXISTS usage (
            id INTEGER PRIMARY KEY AUTOINCREMENT, ts REAL, purpose TEXT, model TEXT, input_tokens INTEGER, output_tokens INTEGER,
            cache_read_tokens INTEGER, cost_usd REAL, duration_ms INTEGER, ok INTEGER, interactive INTEGER)
        """)
        try db.exec("CREATE INDEX IF NOT EXISTS idx_usage_ts ON usage(ts)")
        try db.exec("""
        CREATE TABLE IF NOT EXISTS unsub (
            sender_email TEXT PRIMARY KEY, name TEXT, status TEXT DEFAULT 'open', method TEXT, target TEXT, one_click INTEGER DEFAULT 0,
            checked REAL, done REAL)
        """)
        try db.exec("CREATE TABLE IF NOT EXISTS reports (id INTEGER PRIMARY KEY AUTOINCREMENT, ts REAL, kind TEXT, text TEXT, stats TEXT)")
        try db.exec("""
        CREATE TABLE IF NOT EXISTS suggestions (
            id INTEGER PRIMARY KEY AUTOINCREMENT, key TEXT UNIQUE, kind TEXT, value TEXT, category TEXT,
            keep_inbox INTEGER DEFAULT 0, count INTEGER, status TEXT DEFAULT 'open', ts REAL)
        """)
    }

    // MARK: Key-Value

    func value(_ key: String) -> String? {
        (try? db.query("SELECT value FROM kv WHERE key = ?", [key]))?.first?.string("value")
    }

    func setValue(_ value: String?, for key: String) {
        try? db.exec("INSERT OR REPLACE INTO kv (key, value) VALUES (?, ?)", [key, value])
    }

    // MARK: Nachrichten

    func knownMessageIds(since: Date) throws -> [String] {
        try db.query("SELECT message_id FROM messages WHERE date >= ?", [since]).compactMap { $0.string("message_id") }
    }

    func insert(_ raw: RawMessage, myAddresses: Set<String>) throws {
        let senderEmail = MailAddress.parse(raw.sender).email
        let isFromMe = raw.isSent || myAddresses.contains(senderEmail)
        let date = Date.fromISO(raw.date) ?? Date()
        try db.exec("""
        INSERT OR IGNORE INTO messages (message_id, mail_id, account, mailbox, subject, sender, sender_email,
            recipients, date, is_from_me, in_reply_to, refs, content, is_read, unsub, unsub_post)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, [raw.messageId, raw.id, raw.account, raw.mailbox, raw.subject, raw.sender, senderEmail,
              (raw.to + raw.cc).joined(separator: ","), date, isFromMe, raw.inReplyTo,
              raw.references.joined(separator: " "), raw.content, raw.read.map { $0 ? 1 : 0 }, raw.unsubscribe, raw.unsubscribePost])
        try? indexMessage(raw.messageId)
    }

    /// `IN (?, ?, …)`-Klausel für eine Kontenliste.
    func inList(_ accounts: [String]) -> String {
        accounts.isEmpty ? "('')" : "(" + accounts.map { _ in "?" }.joined(separator: ",") + ")"
    }

    func unprocessedMessages(limit: Int, accounts: [String]) throws -> [StoredMessage] {
        try db.query("SELECT * FROM messages WHERE processed = 0 AND account IN \(inList(accounts)) ORDER BY date ASC LIMIT ?",
                     accounts + [limit]).map(message)
    }

    func messages(inThread key: String, limit: Int = 50) throws -> [StoredMessage] {
        try db.query("SELECT * FROM messages WHERE thread_key = ? ORDER BY date DESC LIMIT ?", [key, limit]).map(message).reversed()
    }

    func message(id: String) throws -> StoredMessage? {
        try db.query("SELECT * FROM messages WHERE message_id = ?", [id]).first.map(message)
    }

    func saveAnalysis(of messageId: String, threadKey: String, category: String?, priority: Priority?, summary: String?,
                      decidedBy: String? = nil) throws {
        try db.exec("UPDATE messages SET thread_key = ?, category = ?, priority = ?, summary = ?, decided_by = ?, processed = 1, error = NULL WHERE message_id = ?",
                    [threadKey, category, priority?.rawValue, summary, decidedBy, messageId])
        try? indexMessage(messageId)
    }

    func setThreadKey(_ key: String, for messageId: String) throws {
        try db.exec("UPDATE messages SET thread_key = ? WHERE message_id = ?", [key, messageId])
    }

    /// Analysierte eingegangene Mails, auf die noch keine Aktion angewendet wurde.
    func pendingActions(limit: Int, accounts: [String]) throws -> [StoredMessage] {
        try db.query("""
            SELECT * FROM messages WHERE processed = 1 AND actioned = 0 AND is_from_me = 0 AND category IS NOT NULL
            AND account IN \(inList(accounts)) ORDER BY date ASC LIMIT ?
            """, accounts + [limit]).map(message)
    }

    func markActioned(_ messageId: String) throws {
        try db.exec("UPDATE messages SET actioned = 1 WHERE message_id = ?", [messageId])
    }

    func progressCounts(accounts: [String]) -> (total: Int, analyzed: Int, moved: Int) {
        let r = (try? db.query("SELECT COUNT(*) AS t, SUM(processed != 0) AS a FROM messages WHERE account IN \(inList(accounts))", accounts))?.first
        let moved = (try? db.query("SELECT COUNT(*) AS n FROM activity WHERE kind = 'move' AND dry_run = 0 AND undone = 0 AND account IN \(inList(accounts))", accounts))?.first?.int("n") ?? 0
        return (r?.int("t") ?? 0, r?.int("a") ?? 0, moved)
    }

    func markFailed(_ messageId: String, error: String, giveUp: Bool) throws {
        try db.exec("UPDATE messages SET error = ?, processed = ? WHERE message_id = ?", [error, giveUp ? 2 : 0, messageId])
    }

    func updateLocation(_ messageId: String, mailbox: String, mailId: Int) throws {
        try db.exec("UPDATE messages SET mailbox = ?, mail_id = ?, moved_at = ? WHERE message_id = ?", [mailbox, mailId, Date(), messageId])
    }

    func countMessages(since: Date) -> Int {
        (try? db.query("SELECT COUNT(*) AS n FROM messages WHERE date >= ? AND is_from_me = 0", [since]))?.first?.int("n") ?? 0
    }

    func message(_ r: Row) -> StoredMessage {
        StoredMessage(
            messageId: r.string("message_id") ?? "",
            mailId: r.int("mail_id"),
            account: r.string("account") ?? "",
            mailbox: r.string("mailbox") ?? "",
            subject: r.string("subject") ?? "",
            sender: r.string("sender") ?? "",
            senderEmail: r.string("sender_email") ?? "",
            recipients: (r.string("recipients") ?? "").split(separator: ",").map(String.init),
            date: r.date("date"),
            isFromMe: r.bool("is_from_me"),
            inReplyTo: r.string("in_reply_to"),
            references: (r.string("refs") ?? "").split(separator: " ").map(String.init),
            content: r.string("content") ?? "",
            threadKey: r.string("thread_key"),
            category: r.string("category"),
            priority: r.string("priority").flatMap(Priority.init(rawValue:)),
            summary: r.string("summary"),
            processed: r.int("processed") == 1,
            error: r.string("error"),
            decidedBy: r.string("decided_by"),
            isPrivate: r.bool("is_private")
        )
    }

    // MARK: Gespräche

    /// Ordnet eine Nachricht einem Gespräch zu: zuerst über References/In-Reply-To,
    /// dann über gleichen Betreff mit derselben Gegenseite in den letzten 30 Tagen.
    func resolveThreadKey(for m: StoredMessage) throws -> String {
        let candidates = m.references + [m.inReplyTo].compactMap { $0 }
        for c in candidates.reversed() {
            if let k = try db.query("SELECT thread_key FROM messages WHERE message_id = ? AND thread_key IS NOT NULL", [c]).first?.string("thread_key") {
                return k
            }
            if try !db.query("SELECT 1 FROM threads WHERE thread_key = ?", [c]).isEmpty { return c }
        }
        if let root = m.references.first ?? m.inReplyTo { return root }

        let norm = MailAddress.normalizeSubject(m.subject)
        if !norm.isEmpty {
            let party = m.isFromMe ? (m.recipients.first.map { MailAddress.parse($0).email } ?? "") : m.senderEmail
            if let k = try db.query("""
                SELECT thread_key FROM threads WHERE norm_subject = ? AND counterpart = ? AND last_date >= ?
                ORDER BY last_date DESC LIMIT 1
                """, [norm, party, m.date.addingTimeInterval(-30 * 86400)]).first?.string("thread_key") {
                return k
            }
        }
        return m.messageId
    }

    func thread(_ key: String) throws -> MailThread? {
        try db.query("SELECT * FROM threads WHERE thread_key = ?", [key]).first.map(thread)
    }

    /// Gespräche, an denen mindestens eine Nachricht aus einem der Konten beteiligt ist.
    func threads(accounts: [String], limit: Int = 500) throws -> [MailThread] {
        try db.query("""
            SELECT * FROM threads WHERE thread_key IN
                (SELECT thread_key FROM messages WHERE account IN \(inList(accounts)))
            ORDER BY last_date DESC LIMIT ?
            """, accounts + [limit]).map(thread)
    }

    func upsert(_ t: MailThread) throws {
        // UPSERT statt REPLACE: Die Zeile behält ihre rowid, an der der Suchindex hängt.
        try db.exec("""
        INSERT INTO threads (thread_key, subject, norm_subject, counterpart, last_date, last_from_me, message_count, status, summary, next_step, due_date, priority, category, draft, draft_for, followup_notified, draft_kind, snoozed_until, is_private) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(thread_key) DO UPDATE SET subject = excluded.subject, norm_subject = excluded.norm_subject, counterpart = excluded.counterpart, last_date = excluded.last_date, last_from_me = excluded.last_from_me, message_count = excluded.message_count, status = excluded.status, summary = excluded.summary, next_step = excluded.next_step, due_date = excluded.due_date, priority = excluded.priority, category = excluded.category, draft = excluded.draft, draft_for = excluded.draft_for, followup_notified = excluded.followup_notified, draft_kind = excluded.draft_kind, snoozed_until = excluded.snoozed_until, is_private = excluded.is_private
        """, [t.threadKey, t.subject, t.normSubject, t.counterpart, t.lastDate, t.lastFromMe, t.messageCount,
              t.status.rawValue, t.summary, t.nextStep, t.dueDate, t.priority.rawValue, t.category,
              t.draft, t.draftFor, t.followupNotified, t.draftKind, t.snoozedUntil, t.isPrivate])
        try? indexThread(t.threadKey)
    }

    private func thread(_ r: Row) -> MailThread {
        MailThread(
            threadKey: r.string("thread_key") ?? "",
            subject: r.string("subject") ?? "",
            normSubject: r.string("norm_subject") ?? "",
            counterpart: r.string("counterpart") ?? "",
            lastDate: r.date("last_date"),
            lastFromMe: r.bool("last_from_me"),
            messageCount: r.int("message_count"),
            status: ThreadStatus(rawValue: r.string("status") ?? "") ?? .info,
            summary: r.string("summary") ?? "",
            nextStep: r.string("next_step") ?? "",
            dueDate: r.string("due_date"),
            priority: Priority(rawValue: r.string("priority") ?? "") ?? .normal,
            category: r.string("category"),
            draft: r.string("draft"),
            draftFor: r.string("draft_for"),
            followupNotified: r.bool("followup_notified"),
            draftKind: r.string("draft_kind"),
            snoozedUntil: r.double("snoozed_until") > 0 ? r.date("snoozed_until") : nil,
            isPrivate: r.bool("is_private")
        )
    }

    // MARK: Aktivität

    @discardableResult
    func log(_ m: StoredMessage, kind: String, detail: String, from: String? = nil, to: String? = nil, dryRun: Bool, extra: String? = nil) -> Int64 {
        try? db.exec("""
        INSERT INTO activity (ts, message_id, subject, kind, detail, account, from_mailbox, to_mailbox, dry_run, extra)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, [Date(), m.messageId, m.subject, kind, detail, m.account, from, to, dryRun, extra])
        return db.lastInsertId
    }

    func activity(limit: Int = 300) throws -> [ActivityEntry] {
        try db.query("SELECT * FROM activity ORDER BY ts DESC LIMIT ?", [limit]).map { r in
            ActivityEntry(id: r.int64("id"), date: r.date("ts"), messageId: r.string("message_id") ?? "",
                          subject: r.string("subject") ?? "", kind: r.string("kind") ?? "",
                          detail: r.string("detail") ?? "", account: r.string("account") ?? "",
                          fromMailbox: r.string("from_mailbox"), toMailbox: r.string("to_mailbox"),
                          dryRun: r.bool("dry_run"), undone: r.bool("undone"), extra: r.string("extra"))
        }
    }

    func markUndone(_ id: Int64) throws {
        try db.exec("UPDATE activity SET undone = 1 WHERE id = ?", [id])
    }

    // MARK: Briefings

    func saveBriefing(_ text: String) throws {
        try db.exec("INSERT INTO briefings (ts, text) VALUES (?, ?)", [Date(), text])
    }

    func latestBriefing() throws -> Briefing? {
        try db.query("SELECT * FROM briefings ORDER BY ts DESC LIMIT 1").first.map {
            Briefing(date: $0.date("ts"), text: $0.string("text") ?? "")
        }
    }
}

import Foundation

struct CorrectionGroup {
    var value: String
    var category: String?
    var toInbox: Bool
    var count: Int
}

/// Speicher für Regel-Auswertung, Korrekturen und Regelvorschläge.
extension Store {
    func updateCategory(_ messageId: String, category: String?, decidedBy: String?) throws {
        try db.exec("UPDATE messages SET category = ?, decided_by = ? WHERE message_id = ?", [category, decidedBy, messageId])
    }

    func updatePriority(_ messageId: String, priority: Priority?) throws {
        try db.exec("UPDATE messages SET priority = ? WHERE message_id = ?", [priority?.rawValue, messageId])
    }

    /// Setzt „Aktion angewendet“ zurück, damit die Engine Ordner und Flaggen erneut auswertet.
    func resetActioned(_ ids: [String]) throws {
        for chunk in stride(from: 0, to: ids.count, by: 400).map({ Array(ids[$0..<min($0 + 400, ids.count)]) }) {
            try db.exec("UPDATE messages SET actioned = 0 WHERE message_id IN (\(chunk.map { _ in "?" }.joined(separator: ",")))", chunk)
        }
    }

    func incomingMessages(accounts: [String], limit: Int) throws -> [StoredMessage] {
        try db.query("""
            SELECT * FROM messages WHERE processed = 1 AND is_from_me = 0 AND account IN \(inList(accounts))
            ORDER BY date DESC LIMIT ?
            """, accounts + [limit]).map(message)
    }

    /// Mails, die MailPilot in einen Ordner unter `prefix` gelegt hat und die dort seit `movedBefore` liegen sollten.
    func trackedMessages(accounts: [String], prefix: String, since: Date, movedBefore: Date, limit: Int) throws -> [StoredMessage] {
        try db.query("""
            SELECT * FROM messages WHERE processed = 1 AND is_from_me = 0 AND category IS NOT NULL
            AND account IN \(inList(accounts)) AND mailbox LIKE ? AND COALESCE(moved_at, date) >= ? AND (moved_at IS NULL OR moved_at < ?)
            ORDER BY COALESCE(moved_at, date) DESC LIMIT ?
            """, accounts + [prefix + "%", since, movedBefore, limit]).map(message)
    }

    /// Stichprobe von Mails, die MailPilot in einen der Ordner gelegt hat – zum Prüfen, ob sich der Zielordner zurücklesen lässt.
    func movedSample(account: String, mailboxes: [String], movedBefore: Date, limit: Int) throws -> [StoredMessage] {
        guard !mailboxes.isEmpty else { return [] }
        return try db.query("""
            SELECT * FROM messages WHERE account = ? AND mailbox IN \(inList(mailboxes)) AND (moved_at IS NULL OR moved_at < ?)
            ORDER BY COALESCE(moved_at, date) DESC LIMIT ?
            """, [account] + mailboxes + [movedBefore, limit]).map(message)
    }

    // MARK: Korrekturen

    func addCorrection(_ m: StoredMessage, from: String?, to: String?, toInbox: Bool, source: String) throws {
        try db.exec("""
            INSERT INTO corrections (ts, message_id, subject, account, sender_email, domain, from_category, to_category, to_inbox, source)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [Date(), m.messageId, m.subject, m.account, m.senderEmail, RuleEngine.domain(of: m.senderEmail),
                  from, to, toInbox, source])
    }

    private func correction(_ r: Row) -> Correction {
        Correction(id: r.int64("id"), date: r.date("ts"), messageId: r.string("message_id") ?? "",
                   subject: r.string("subject") ?? "", senderEmail: r.string("sender_email") ?? "",
                   fromCategory: r.string("from_category"), toCategory: r.string("to_category"),
                   toInbox: r.bool("to_inbox"), source: r.string("source") ?? "")
    }

    func corrections(limit: Int) throws -> [Correction] {
        try db.query("SELECT * FROM corrections ORDER BY ts DESC LIMIT ?", [limit]).map(correction)
    }

    func corrections(senderEmail: String, domain: String, limit: Int) throws -> [Correction] {
        try db.query("SELECT * FROM corrections WHERE sender_email = ? OR (domain = ? AND ? != '') ORDER BY ts DESC LIMIT ?",
                     [senderEmail, domain, domain, limit]).map(correction)
    }

    func senderCorrectionGroups(minCount: Int) throws -> [CorrectionGroup] {
        try db.query("""
            SELECT sender_email AS value, to_category, to_inbox, COUNT(*) AS n FROM corrections
            WHERE sender_email != '' AND (to_inbox = 1 OR to_category IS NOT NULL)
            GROUP BY sender_email, to_category, to_inbox HAVING n >= ?
            """, [minCount]).map {
            CorrectionGroup(value: $0.string("value") ?? "", category: $0.string("to_category"), toInbox: $0.bool("to_inbox"), count: $0.int("n"))
        }
    }

    func domainCorrectionGroups(minSenders: Int) throws -> [CorrectionGroup] {
        try db.query("""
            SELECT domain AS value, to_category, to_inbox, COUNT(*) AS n, COUNT(DISTINCT sender_email) AS s FROM corrections
            WHERE domain != '' AND (to_inbox = 1 OR to_category IS NOT NULL)
            GROUP BY domain, to_category, to_inbox HAVING s >= ?
            """, [minSenders]).map {
            CorrectionGroup(value: $0.string("value") ?? "", category: $0.string("to_category"), toInbox: $0.bool("to_inbox"), count: $0.int("n"))
        }
    }

    // MARK: Vorschläge

    func upsertSuggestion(kind: String, value: String, category: String?, keepInInbox: Bool, count: Int) throws {
        let key = "\(kind)|\(value.lowercased())|\(category ?? "")|\(keepInInbox)"
        try db.exec("""
            INSERT INTO suggestions (key, kind, value, category, keep_inbox, count, status, ts) VALUES (?, ?, ?, ?, ?, ?, 'open', ?)
            ON CONFLICT(key) DO UPDATE SET count = excluded.count WHERE suggestions.status = 'open'
            """, [key, kind, value, category, keepInInbox, count, Date()])
    }

    func openSuggestions() throws -> [RuleSuggestion] {
        try db.query("SELECT * FROM suggestions WHERE status = 'open' ORDER BY count DESC, ts DESC").map {
            RuleSuggestion(id: $0.int64("id"), kind: $0.string("kind") ?? "sender", value: $0.string("value") ?? "",
                           category: $0.string("category"), keepInInbox: $0.bool("keep_inbox"), count: $0.int("count"))
        }
    }

    func setSuggestionStatus(_ id: Int64, _ status: String) throws {
        try db.exec("UPDATE suggestions SET status = ? WHERE id = ?", [status, id])
    }
}

/// Bereits in Erinnerungen/Kalender übernommene Fristen (verhindert Doppeleinträge).
extension Store {
    func hasExport(_ threadKey: String, due: String, kind: String) -> Bool {
        ((try? db.query("SELECT 1 AS x FROM exports WHERE thread_key = ? AND due_date = ? AND kind = ?", [threadKey, due, kind])) ?? []).isEmpty == false
    }

    func addExport(_ threadKey: String, due: String, kind: String, extId: String?) throws {
        try db.exec("INSERT OR IGNORE INTO exports (thread_key, due_date, kind, ext_id, ts) VALUES (?, ?, ?, ?, ?)",
                    [threadKey, due, kind, extId, Date()])
    }
}

/// Datenschutz: Mails und Gespräche, deren Inhalt nie an Claude geht.
extension Store {
    /// Markiert die Nachricht als vertraulich: kein Mailtext (außer `keepBody`), keine Zusammenfassung, nicht zur Analyse vorgemerkt.
    func markPrivate(_ messageId: String, threadKey: String, keepBody: Bool, category: String?, priority: Priority?, decidedBy: String?) throws {
        try db.exec("""
            UPDATE messages SET is_private = 1, processed = 1, thread_key = ?, category = ?, priority = ?, decided_by = ?, error = NULL,
                summary = 'Vertraulich – Inhalt nicht an Claude gesendet', content = CASE WHEN ? THEN content ELSE '' END
            WHERE message_id = ?
            """, [threadKey, category, priority?.rawValue, decidedBy, keepBody, messageId])
        try? indexMessage(messageId)
    }

    /// Alle gespeicherten Mails der Konten (für die nachträgliche Prüfung neuer Datenschutz-Regeln).
    func allMessages(accounts: [String], limit: Int = 50_000) throws -> [StoredMessage] {
        try db.query("SELECT * FROM messages WHERE account IN \(inList(accounts)) ORDER BY date DESC LIMIT ?", accounts + [limit]).map(message)
    }

    func markThreadPrivate(_ key: String) throws {
        try db.exec("""
            UPDATE threads SET is_private = 1, summary = 'Vertraulich – Inhalt wird nicht an Claude gesendet.', next_step = '',
                due_date = NULL, draft = NULL, draft_for = NULL, draft_kind = NULL WHERE thread_key = ?
            """, [key])
        try? indexThread(key)
    }

    func isThreadPrivate(_ key: String) -> Bool {
        ((try? db.query("SELECT is_private FROM threads WHERE thread_key = ?", [key]))?.first?.bool("is_private")) ?? false
    }
}

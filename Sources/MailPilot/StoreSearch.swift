import Foundation

struct SearchHit: Identifiable, Hashable {
    /// Gesprächsschlüssel (bei Mails ohne Gespräch die Message-ID)
    var key: String
    var messageId: String?
    var subject: String
    var party: String
    var account: String?
    var date: Date?
    var snippet: String
    /// Anzahl der Treffer in diesem Gespräch
    var matches: Int
    var hasThread: Bool

    var id: String { key }
}

enum FTSQuery {
    /// Macht aus Nutzereingabe eine FTS5-Abfrage: alle Wörter müssen vorkommen, das letzte als Wortanfang; "in Anführungszeichen" = Phrase.
    static func make(_ raw: String) -> String? {
        var tokens: [(text: String, phrase: Bool)] = []
        var current = ""
        var inQuote = false
        func flush(_ phrase: Bool) {
            let cleaned = clean(current)
            if !cleaned.isEmpty { tokens.append((cleaned, phrase)) }
            current = ""
        }
        for ch in raw {
            if ch == "\"" { flush(inQuote); inQuote.toggle() }
            else if ch.isWhitespace && !inQuote { flush(false) }
            else { current.append(ch) }
        }
        flush(inQuote)
        guard !tokens.isEmpty else { return nil }
        return tokens.enumerated().map { i, t in
            let q = "\"\(t.text)\""
            return (i == tokens.count - 1 && !t.phrase) ? q + "*" : q
        }.joined(separator: " ")
    }

    /// Entfernt Zeichen, die FTS5 als Syntax liest.
    private static func clean(_ s: String) -> String {
        s.unicodeScalars.filter { !"\"()*:^{}+~".unicodeScalars.contains($0) }.map(String.init).joined()
            .trimmingCharacters(in: .whitespaces)
    }
}

/// Volltextindex (SQLite FTS5) über Mails und Gespräche – auch für bereits verschobene Mails.
extension Store {
    func ensureSearchIndex() throws {
        try db.exec("""
            CREATE VIRTUAL TABLE IF NOT EXISTS search_idx USING fts5(subject, party, summary, body, tokenize = 'unicode61 remove_diacritics 2')
            """)
        if value("searchIndexV1") == nil {
            try rebuildSearchIndex()
            setValue("1", for: "searchIndexV1")
        }
    }

    /// Baut den Index aus Mails (positive rowid) und Gesprächen (negative rowid) neu auf.
    func rebuildSearchIndex() throws {
        try db.exec("DELETE FROM search_idx")
        try db.exec("""
            INSERT INTO search_idx (rowid, subject, party, summary, body)
            SELECT rowid, COALESCE(subject,''), COALESCE(sender,''), COALESCE(summary,''), COALESCE(content,'') FROM messages
            """)
        try db.exec("""
            INSERT INTO search_idx (rowid, subject, party, summary, body)
            SELECT -rowid, COALESCE(subject,''), COALESCE(counterpart,''), COALESCE(summary,'') || ' ' || COALESCE(next_step,''), '' FROM threads
            """)
    }

    func indexMessage(_ messageId: String) throws {
        guard let r = try db.query("SELECT rowid AS rid, subject, sender, summary, content FROM messages WHERE message_id = ?", [messageId]).first else { return }
        try db.exec("DELETE FROM search_idx WHERE rowid = ?", [r.int64("rid")])
        try db.exec("INSERT INTO search_idx (rowid, subject, party, summary, body) VALUES (?, ?, ?, ?, ?)",
                    [r.int64("rid"), r.string("subject") ?? "", r.string("sender") ?? "", r.string("summary") ?? "", r.string("content") ?? ""])
    }

    func indexThread(_ key: String) throws {
        guard let r = try db.query("SELECT rowid AS rid, subject, counterpart, summary, next_step FROM threads WHERE thread_key = ?", [key]).first else { return }
        try db.exec("DELETE FROM search_idx WHERE rowid = ?", [-r.int64("rid")])
        try db.exec("INSERT INTO search_idx (rowid, subject, party, summary, body) VALUES (?, ?, ?, ?, '')",
                    [-r.int64("rid"), r.string("subject") ?? "", r.string("counterpart") ?? "", (r.string("summary") ?? "") + " " + (r.string("next_step") ?? "")])
    }

    func searchIndexCount() -> Int {
        ((try? db.query("SELECT COUNT(*) AS n FROM search_idx"))?.first?.int("n")) ?? 0
    }

    /// Sucht in Betreff, Absender, Zusammenfassungen und Mailtexten; Treffer werden je Gespräch zusammengefasst.
    func search(_ raw: String, limit: Int = 400) throws -> [SearchHit] {
        guard let q = FTSQuery.make(raw) else { return [] }
        let rows = try db.query("""
            SELECT search_idx.rowid AS rid, snippet(search_idx, -1, '«', '»', '…', 16) AS snip,
                   bm25(search_idx, 6.0, 3.0, 4.0, 1.0) AS score,
                   m.message_id AS mid, m.thread_key AS mthread, m.account AS macct, m.date AS mdate, m.subject AS msubj, m.sender AS msender,
                   t.thread_key AS tkey, t.subject AS tsubj, t.counterpart AS tparty, t.last_date AS tdate
            FROM search_idx
            LEFT JOIN messages m ON search_idx.rowid = m.rowid
            LEFT JOIN threads t ON -search_idx.rowid = t.rowid
            WHERE search_idx MATCH ? ORDER BY score LIMIT ?
            """, [q, limit])
        var order: [String] = []
        var hits: [String: SearchHit] = [:]
        for r in rows {
            let isMessage = r.string("mid") != nil
            guard isMessage || r.string("tkey") != nil else { continue }   // verwaiste Indexzeile
            let key = r.string("mthread") ?? r.string("tkey") ?? r.string("mid") ?? ""
            if var h = hits[key] { h.matches += 1; hits[key] = h; continue }
            hits[key] = SearchHit(
                key: key, messageId: r.string("mid"),
                subject: r.string(isMessage ? "msubj" : "tsubj") ?? "", party: r.string(isMessage ? "msender" : "tparty") ?? "",
                account: r.string("macct"), date: isMessage ? r.date("mdate") : r.date("tdate"),
                snippet: r.string("snip") ?? "", matches: 1,
                hasThread: r.string("mthread") != nil || r.string("tkey") != nil)
            order.append(key)
        }
        return order.compactMap { hits[$0] }
    }
}

import Foundation

/// Nachholen von Aktionen in Mail: Probelauf beenden, gealterte Mails archivieren.
///
/// `actioned`: 0 = offen, 1 = erledigt oder bewusst übersprungen, 2 = nur im Probelauf durchgespielt.
extension Store {
    /// Im Probelauf durchgespielt: bleibt liegen, bis der Probelauf endet (dann `releaseDryRun`).
    func markDryRun(_ messageId: String) throws {
        try db.exec("UPDATE messages SET actioned = 2 WHERE message_id = ?", [messageId])
    }

    /// Gibt die im Probelauf durchgespielten Mails wieder frei, damit ihre Aktionen nachgeholt werden. Rückgabe: Anzahl.
    @discardableResult
    func releaseDryRun() -> Int {
        let n = ((try? db.query("SELECT COUNT(*) AS n FROM messages WHERE actioned = 2"))?.first?.int("n")) ?? 0
        if n > 0 { try? db.exec("UPDATE messages SET actioned = 0 WHERE actioned = 2") }
        return n
    }

    /// Einmalig: Frühere Versionen haben Mails im Probelauf als erledigt markiert, obwohl nichts passiert war.
    /// Betroffen sind Mails mit Probelauf-Einträgen im Protokoll, aber ohne echte Verschiebung oder Flagge.
    func releaseLegacyDryRun() -> Int {
        guard value("legacyDryRunReleased") == nil else { return 0 }
        setValue("1", for: "legacyDryRunReleased")
        let where_ = """
            actioned = 1 AND is_from_me = 0
            AND message_id IN (SELECT message_id FROM activity WHERE dry_run = 1)
            AND message_id NOT IN (SELECT message_id FROM activity WHERE dry_run = 0 AND kind IN ('move', 'flag'))
            """
        let n = ((try? db.query("SELECT COUNT(*) AS n FROM messages WHERE \(where_)"))?.first?.int("n")) ?? 0
        if n > 0 { try? db.exec("UPDATE messages SET actioned = 0 WHERE \(where_)") }
        return n
    }

    // MARK: Archivierung gealterter Mails

    /// Eingegangene, schon bearbeitete Mails, die älter als `before` sind, außerhalb von Archiv und Kategorie-Ordnern liegen
    /// und zu einem Gespräch mit Status „Info“ oder „Erledigt“ gehören. Jede Mail wird nur einmal vorgeschlagen.
    func archiveCandidates(accounts: [String], archivePath: String, prefix: String, before: Date, limit: Int) throws -> [StoredMessage] {
        let prefixClause = prefix.isEmpty ? "" : "AND m.mailbox NOT LIKE ?"
        let params: [Any?] = [before, archivePath] + (prefix.isEmpty ? [] : [prefix + "%"]) + accounts + [limit]
        return try db.query("""
            SELECT m.* FROM messages m JOIN threads t ON t.thread_key = m.thread_key
            WHERE m.processed = 1 AND m.actioned = 1 AND m.is_from_me = 0 AND m.is_private = 0 AND m.category IS NOT NULL
            AND COALESCE(m.archive_tried, 0) = 0 AND m.date < ? AND m.mailbox != '(entfernt)' AND m.mailbox != ? \(prefixClause)
            AND t.status IN ('info', 'erledigt') AND m.account IN \(inList(accounts))
            ORDER BY m.date ASC LIMIT ?
            """, params).map(message)
    }

    func markArchiveTried(_ ids: [String]) {
        for chunk in stride(from: 0, to: ids.count, by: 400).map({ Array(ids[$0..<min($0 + 400, ids.count)]) }) {
            try? db.exec("UPDATE messages SET archive_tried = 1 WHERE message_id IN (\(chunk.map { _ in "?" }.joined(separator: ",")))", chunk)
        }
    }
}

/// Reihenfolge eines Durchlaufs: Was lokal entschieden wurde, wird auch dann angewendet, wenn die Analyse durch Claude
/// scheitert (z. B. Pause wegen Abo-Limit). Der Analysefehler wird danach weitergereicht.
enum CyclePipeline {
    static func run(analyze: () async throws -> Void, apply: () async throws -> Void) async throws {
        var failure: Error?
        do { try await analyze() } catch { failure = error }
        try await apply()
        if let failure { throw failure }
    }
}

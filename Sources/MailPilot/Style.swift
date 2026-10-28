import Foundation

/// Antwortstil lernen: aus den eigenen gesendeten Mails (ohne zitierte Verläufe) ein Stilprofil bilden.
enum StyleLearner {
    private static let replyHeaders: [String] = [
        #"^\s*Am .{3,120}(schrieb|hat|schreibt).*$"#,
        #"^\s*On .{3,120}wrote:?\s*$"#,
        #"^\s*-{2,}\s*(Original|Ursprüngliche|Urspr|Weitergeleitete|Forwarded|Reply)"#,
        #"^\s*_{10,}\s*$"#,
        #"^\s*(Von|From):\s.+"#,
        #"^\s*Gesendet von meinem"#,
        #"^\s*Sent from my"#,
    ]

    /// Schneidet zitierte Verläufe, Weiterleitungsköpfe und „>“-Zeilen ab.
    static func cleanBody(_ text: String) -> String {
        var out: [String] = []
        for line in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            if replyHeaders.contains(where: { line.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }) { break }
            if line.trimmingCharacters(in: .whitespaces).hasPrefix(">") { continue }
            out.append(line)
        }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let autoReplyMarkers = ["automatische antwort", "abwesenheitsnotiz", "out of office", "autoreply", "auto-reply", "nicht im büro", "undeliverable", "zustellung fehlgeschlagen"]

    /// Eignet sich die bereinigte Mail als Stilprobe? (nicht zu kurz/lang, keine Automatik, nicht überwiegend Links)
    static func isUsable(_ body: String, subject: String = "") -> Bool {
        guard (40...1500).contains(body.count) else { return false }
        let lower = (subject + " " + body).lowercased()
        if autoReplyMarkers.contains(where: lower.contains) { return false }
        let words = body.split(whereSeparator: \.isWhitespace)
        let links = words.filter { $0.hasPrefix("http") || $0.contains("://") }.count
        return !words.isEmpty && Double(links) / Double(words.count) < 0.3
    }

    struct Sample {
        var recipient: String
        var body: String
    }

    /// Wählt bis zu `limit` Proben aus gesendeten Mails (neueste zuerst, höchstens 3 je Empfänger für Vielfalt).
    static func samples(from sent: [StoredMessage], limit: Int = 40) -> [Sample] {
        var perRecipient: [String: Int] = [:]
        var out: [Sample] = []
        for m in sent where m.isFromMe && !m.isPrivate {
            let body = cleanBody(m.content)
            guard isUsable(body, subject: m.subject) else { continue }
            let to = m.recipients.first.map { MailAddress.parse($0).email } ?? ""
            if perRecipient[to, default: 0] >= 3 { continue }
            perRecipient[to, default: 0] += 1
            out.append(Sample(recipient: to, body: body))
            if out.count >= limit { break }
        }
        return out
    }

    static let minSamples = 10
}

extension Store {
    /// Gesendete, nicht vertrauliche Mails (neueste zuerst) als Rohmaterial für die Stilprobe.
    func sentMessages(accounts: [String], limit: Int = 400) throws -> [StoredMessage] {
        try db.query("""
            SELECT * FROM messages WHERE is_from_me = 1 AND is_private = 0 AND account IN \(inList(accounts)) ORDER BY date DESC LIMIT ?
            """, accounts + [limit]).map(message)
    }

    func hasMessage(_ id: String) -> Bool {
        ((try? db.query("SELECT 1 AS x FROM messages WHERE message_id = ?", [id])) ?? []).isEmpty == false
    }

    /// Nur für den Stil archiviert: kein Gespräch, keine Analyse.
    func insertStyleOnly(_ raw: RawMessage, myAddresses: Set<String>) throws {
        guard !hasMessage(raw.messageId) else { return }
        try insert(raw, myAddresses: myAddresses)
        try db.exec("UPDATE messages SET processed = 2, error = 'Stilarchiv' WHERE message_id = ?", [raw.messageId])
    }

    /// Frühere Mails von mir an diese Adresse (für Beispiele im Stil).
    func sentExamples(toEmail: String, limit: Int = 2) -> [String] {
        guard !toEmail.isEmpty else { return [] }
        let rows = (try? db.query("""
            SELECT * FROM messages WHERE is_from_me = 1 AND is_private = 0 AND recipients LIKE ? ORDER BY date DESC LIMIT 25
            """, ["%" + toEmail + "%"]).map(message)) ?? []
        var out: [String] = []
        for m in rows {
            let body = StyleLearner.cleanBody(m.content)
            if StyleLearner.isUsable(body, subject: m.subject), body.count <= 700 { out.append(body) }
            if out.count >= limit { break }
        }
        return out
    }
}

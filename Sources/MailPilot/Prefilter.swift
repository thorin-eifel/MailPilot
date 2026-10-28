import Foundation

/// Spart Claude-Aufrufe: Offensichtlich automatische Mails werden ohne Claude einsortiert –
/// anhand der Mail-Header und des bisherigen Verhaltens desselben Absenders.
enum Prefilter {
    struct Verdict: Equatable {
        var category: String
        var reason: String
        /// Wird als „Entschieden von“ gespeichert.
        var source: String
    }

    /// Betreffs, bei denen immer Claude (und nicht der Vorfilter) entscheidet: Rechnungen, Bestellungen, Termine, Sicherheit.
    static let keepWords = ["rechnung", "invoice", "beleg", "quittung", "receipt", "zahlung", "payment", "mahnung", "überfällig", "bestellung", "order",
                            "versand", "shipping", "lieferung", "delivery", "sendung", "termin", "einladung", "invitation", "meeting", "kündigung", "vertrag",
                            "frist", "dringend", "urgent", "wichtig", "action required", "handlung erforderlich"]

    /// Kategorien, die bei wiederkehrenden Absendern ohne Claude vergeben werden dürfen (niedriger Einsatz).
    static let memoryCategories: Set<String> = ["Newsletter", "Werbung", "Benachrichtigungen"]

    static let systemLocalParts: Set<String> = ["noreply", "no-reply", "donotreply", "do-not-reply", "mailer-daemon", "postmaster", "no_reply"]

    static let newsletterName = "Newsletter"
    static let notificationName = "Benachrichtigungen"

    static func hasKeepWord(_ subject: String) -> Bool {
        let s = subject.lowercased()
        return keepWords.contains { s.contains($0) }
    }

    /// - Parameters:
    ///   - history: bisherige, von Claude oder dem Nutzer vergebene Kategorien dieses Absenders (Anzahl je Kategorie)
    ///   - hasCorrections: Der Nutzer hat Mails dieses Absenders schon einmal umsortiert → nie automatisch entscheiden.
    static func verdict(for m: StoredMessage, settings: AppSettings, history: [(category: String, n: Int)], hasCorrections: Bool, isVIP: Bool) -> Verdict? {
        guard settings.prefilterEnabled, !m.isFromMe, !isVIP, !hasCorrections, !m.isPrivate, !hasKeepWord(m.subject) else { return nil }
        func has(_ name: String) -> Bool { settings.category(named: name) != nil }
        let flags = Set(m.hdrFlags.split(separator: " ").map(String.init))
        let local = m.senderEmail.split(separator: "@").first.map { String($0).lowercased() } ?? ""

        if flags.contains("auto"), has(notificationName) {
            return Verdict(category: notificationName, reason: "Header „Auto-Submitted“", source: "Vorfilter")
        }
        if m.unsub != nil, flags.contains("bulk") || flags.contains("list"), has(newsletterName) {
            return Verdict(category: newsletterName, reason: "Massenmail mit Abmelde-Link", source: "Vorfilter")
        }
        if m.unsub != nil, has(newsletterName) {
            return Verdict(category: newsletterName, reason: "Abmelde-Link im Header", source: "Vorfilter")
        }
        if systemLocalParts.contains(local), has(notificationName) {
            return Verdict(category: notificationName, reason: "Absender „\(local)“", source: "Vorfilter")
        }

        // Absender-Gedächtnis: mindestens 3 frühere Mails, 90 % davon in derselben Kategorie
        let total = history.reduce(0) { $0 + $1.n }
        if total >= 3, let top = history.max(by: { $0.n < $1.n }), Double(top.n) / Double(total) >= 0.9,
           memoryCategories.contains(top.category), has(top.category) {
            return Verdict(category: top.category, reason: "wie \(top.n) frühere Mails dieses Absenders", source: "Absender-Gedächtnis")
        }
        return nil
    }

    static func analysis(for m: StoredMessage, _ v: Verdict) -> MessageAnalysis {
        MessageAnalysis(category: v.category, priority: .low, needs_reply: false, summary: String(m.subject.prefix(120)),
                        thread_summary: "Automatisch einsortiert (\(v.reason)).", thread_status: .info, next_step: "", due_date: nil, reply_draft: nil)
    }
}

extension Store {
    /// Bisherige Kategorien eines Absenders – nur Entscheidungen von Claude oder vom Nutzer, nie der Vorfilter selbst.
    func senderHistory(email: String, excluding messageId: String) -> [(category: String, n: Int)] {
        ((try? db.query("""
            SELECT category, COUNT(*) AS n FROM messages WHERE sender_email = ? AND is_from_me = 0 AND processed = 1 AND is_private = 0
            AND decided_by IN ('Claude', 'Korrektur') AND category IS NOT NULL AND message_id != ? GROUP BY category
            """, [email, messageId])) ?? []).compactMap { r in r.string("category").map { ($0, r.int("n")) } }
    }

    /// Mails, die ohne Claude einsortiert wurden.
    func locallyClassifiedCount(since: Date) -> Int {
        ((try? db.query("SELECT COUNT(*) AS n FROM messages WHERE decided_by IN ('Vorfilter', 'Absender-Gedächtnis') AND date >= ?", [since]))?.first?.int("n")) ?? 0
    }

    func classifiedCount(since: Date) -> Int {
        ((try? db.query("SELECT COUNT(*) AS n FROM messages WHERE processed = 1 AND is_from_me = 0 AND date >= ?", [since]))?.first?.int("n")) ?? 0
    }
}

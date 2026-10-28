import Foundation

/// Abmelde-Möglichkeit aus dem Header `List-Unsubscribe` (RFC 2369) und `List-Unsubscribe-Post` (RFC 8058).
struct UnsubOption: Hashable {
    enum Method: String { case oneClick, link, mailto, none }
    var method: Method
    /// https-Adresse oder mailto-Adresse
    var target: String

    static let none = UnsubOption(method: .none, target: "")

    /// Bevorzugt Ein-Klick (POST), dann Link, dann E-Mail. Unsichere Ziele (http, interne Hosts) werden verworfen.
    static func parse(header: String?, post: String?) -> UnsubOption {
        guard let header, !header.isEmpty else { return .none }
        var https: String?
        var mailto: String?
        for part in header.components(separatedBy: ",") {
            let t = part.trimmingCharacters(in: CharacterSet(charactersIn: " <>\t"))
            if t.lowercased().hasPrefix("https://"), https == nil, let u = URL(string: t), isSafe(u) { https = t }
            else if t.lowercased().hasPrefix("mailto:"), mailto == nil { mailto = t }
        }
        let oneClick = (post ?? "").lowercased().contains("list-unsubscribe=one-click")
        if let https { return UnsubOption(method: oneClick ? .oneClick : .link, target: https) }
        if let mailto { return UnsubOption(method: .mailto, target: mailto) }
        return .none
    }

    /// Nur https, keine Zugangsdaten in der Adresse, kein lokaler oder privater Host (Schutz vor Anfragen ins eigene Netz).
    static func isSafe(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil, let host = url.host?.lowercased(), host.contains(".") else { return false }
        if host.hasSuffix(".local") || host.hasSuffix(".internal") || host.hasSuffix(".lan") || host.hasSuffix(".localhost") || host == "localhost" { return false }
        // IP-Adressen (v4/v6) nie ansteuern
        if host.contains(":") || host.allSatisfy({ $0.isNumber || $0 == "." }) { return false }
        return true
    }

    struct Mailto {
        var address: String
        var subject: String
        var body: String
    }

    static func parseMailto(_ s: String) -> Mailto? {
        guard let c = URLComponents(string: s), c.scheme?.lowercased() == "mailto" else { return nil }
        let address = c.path.removingPercentEncoding ?? c.path
        guard address.contains("@") else { return nil }
        func item(_ n: String) -> String? { c.queryItems?.first { $0.name.lowercased() == n }?.value }
        return Mailto(address: address, subject: item("subject") ?? "unsubscribe", body: item("body") ?? "unsubscribe")
    }
}

struct NewsletterCandidate: Identifiable, Hashable {
    var email: String
    var name: String
    var total: Int
    var read: Int
    var known: Int
    var lastDate: Date
    var firstDate: Date
    var option: UnsubOption?
    var status: String
    var doneDate: Date?
    /// Mails, die nach dem Abbestellen noch kamen.
    var afterDone = 0

    var id: String { email }

    var perMonth: Double {
        let span = max(7, lastDate.timeIntervalSince(firstDate) / 86400)
        return Double(total) / span * 30
    }
}

enum Newsletter {
    static let windowDays = 90
    static let minMails = 4

    /// Vorschlag, wenn in 90 Tagen mindestens 4 Mails mit bekanntem Lesestatus kamen und höchstens jede zehnte gelesen wurde.
    static func isCandidate(total: Int, known: Int, read: Int) -> Bool {
        total >= minMails && known >= minMails && read * 10 <= known
    }
}

extension Store {
    /// Newsletter-Absender mit Zahl der Mails und gelesenen Mails im Zeitraum.
    func newsletterStats(category: String, accounts: [String], since: Date) throws -> [NewsletterCandidate] {
        try db.query("""
            SELECT sender_email, MAX(sender) AS sender, COUNT(*) AS total, SUM(is_read = 1) AS readn, SUM(is_read IS NOT NULL) AS known,
                   MAX(date) AS last, MIN(date) AS first
            FROM messages WHERE category = ? AND is_from_me = 0 AND is_private = 0 AND sender_email != '' AND date >= ? AND account IN \(inList(accounts))
            GROUP BY sender_email
            """, [category, since] + accounts).map { r in
            let email = r.string("sender_email") ?? ""
            return NewsletterCandidate(email: email, name: MailAddress.parse(r.string("sender") ?? "").name ?? email, total: r.int("total"), read: r.int("readn"),
                                       known: r.int("known"), lastDate: r.date("last"), firstDate: r.date("first"), option: nil, status: "open")
        }
    }

    func newsletterMessages(category: String, accounts: [String], since: Date) throws -> [StoredMessage] {
        try db.query("""
            SELECT * FROM messages WHERE category = ? AND is_from_me = 0 AND is_private = 0 AND date >= ? AND account IN \(inList(accounts))
            """, [category, since] + accounts).map(message)
    }

    func setRead(_ read: Bool, messageId: String) throws {
        try db.exec("UPDATE messages SET is_read = ? WHERE message_id = ?", [read ? 1 : 0, messageId])
    }

    /// Neueste Abmelde-Angabe aus den Mail-Headern eines Absenders.
    func latestUnsubHeader(email: String) -> (header: String, post: String?)? {
        guard let r = (try? db.query("SELECT unsub, unsub_post FROM messages WHERE sender_email = ? AND unsub IS NOT NULL ORDER BY date DESC LIMIT 1", [email]))?.first,
              let h = r.string("unsub") else { return nil }
        return (h, r.string("unsub_post"))
    }

    func latestMessage(from email: String) -> StoredMessage? {
        (try? db.query("SELECT * FROM messages WHERE sender_email = ? AND is_from_me = 0 ORDER BY date DESC LIMIT 1", [email]).map(message))?.first
    }

    func iEverWroteTo(_ email: String) -> Bool {
        ((try? db.query("SELECT 1 AS x FROM messages WHERE is_from_me = 1 AND recipients LIKE ? LIMIT 1", ["%" + email + "%"])) ?? []).isEmpty == false
    }

    func messagesSince(from email: String, since: Date) -> Int {
        ((try? db.query("SELECT COUNT(*) AS n FROM messages WHERE sender_email = ? AND is_from_me = 0 AND date > ?", [email, since]))?.first?.int("n")) ?? 0
    }

    // Abmelde-Status je Absender
    func unsubRecord(_ email: String) -> (status: String, option: UnsubOption?, done: Date?)? {
        guard let r = (try? db.query("SELECT * FROM unsub WHERE sender_email = ?", [email]))?.first else { return nil }
        let method = r.string("method").flatMap(UnsubOption.Method.init(rawValue:))
        return (r.string("status") ?? "open", method.map { UnsubOption(method: $0, target: r.string("target") ?? "") }, r.double("done") > 0 ? r.date("done") : nil)
    }

    func saveUnsub(_ email: String, name: String, status: String? = nil, option: UnsubOption? = nil, done: Date? = nil) throws {
        let existing = unsubRecord(email)
        try db.exec("""
            INSERT OR REPLACE INTO unsub (sender_email, name, status, method, target, one_click, checked, done) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """, [email, name, status ?? existing?.status ?? "open", (option ?? existing?.option)?.method.rawValue, (option ?? existing?.option)?.target,
                  (option ?? existing?.option)?.method == .oneClick, Date(), done ?? existing?.done])
    }

    func unsubEmails(status: String) -> [String] {
        ((try? db.query("SELECT sender_email FROM unsub WHERE status = ? ORDER BY COALESCE(done, checked) DESC", [status])) ?? []).compactMap { $0.string("sender_email") }
    }
}

import Foundation

/// Lokaler Speicher des eigenen Mail-Clients: Ordner und Nachrichten je Konto.
struct ClientMessage: Identifiable, Hashable {
    var account: String
    var folder: String
    var uid: UInt32
    var messageId: String
    var inReplyTo: String
    var references: [String]
    var subject: String
    var senderName: String
    var senderEmail: String
    var recipients: [String]
    var date: Date
    var flags: [String]
    var size: Int
    var preview: String
    var hasBody: Bool
    var unsub: String? = nil
    var unsubPost: String? = nil
    var hdrFlags = ""

    var id: String { "\(account)|\(folder)|\(uid)" }
    var isRead: Bool { flags.contains { $0.caseInsensitiveCompare("\\Seen") == .orderedSame } }
    var isFlagged: Bool { flags.contains { $0.caseInsensitiveCompare("\\Flagged") == .orderedSame } }
    var senderDisplay: String { senderName.isEmpty ? senderEmail : senderName }
}

struct ClientFolder: Identifiable, Hashable {
    var account: String
    var path: String
    var name: String
    var special: String?
    var delimiter: String
    var selectable: Bool
    var uidValidity: UInt32
    var unread: Int = 0

    var id: String { "\(account)|\(path)" }

    var sortRank: Int {
        switch special {
        case "inbox": 0
        case "drafts": 1
        case "sent": 2
        case "archive": 3
        case "junk": 4
        case "trash": 5
        default: 10
        }
    }

    var symbol: String {
        switch special {
        case "inbox": "tray.fill"
        case "drafts": "doc.fill"
        case "sent": "paperplane.fill"
        case "archive": "archivebox.fill"
        case "junk": "xmark.bin.fill"
        case "trash": "trash.fill"
        default: "folder.fill"
        }
    }
}

extension Store {
    func clientFolders(account: String) -> [ClientFolder] {
        let unread = Dictionary(uniqueKeysWithValues: ((try? db.query("""
            SELECT folder, COUNT(*) AS n FROM c_message WHERE account = ? AND flags NOT LIKE '%\\Seen%' GROUP BY folder
            """, [account])) ?? []).map { ($0.string("folder") ?? "", $0.int("n")) })
        return ((try? db.query("SELECT * FROM c_folder WHERE account = ?", [account])) ?? []).map { r in
            let path = r.string("path") ?? ""
            return ClientFolder(account: account, path: path, name: r.string("name") ?? path, special: r.string("special"),
                                delimiter: r.string("delimiter") ?? "/", selectable: r.bool("selectable"),
                                uidValidity: UInt32(truncatingIfNeeded: r.int("uidvalidity")), unread: unread[path] ?? 0)
        }.sorted { ($0.sortRank, $0.path.lowercased()) < ($1.sortRank, $1.path.lowercased()) }
    }

    func saveClientFolders(account: String, folders: [IMAPFolderInfo]) throws {
        let keep = folders.map(\.path)
        for f in folders {
            try db.exec("""
                INSERT INTO c_folder (account, path, name, special, delimiter, selectable) VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(account, path) DO UPDATE SET name = excluded.name, special = excluded.special, delimiter = excluded.delimiter, selectable = excluded.selectable
                """, [account, f.path, f.name, f.special, f.delimiter, f.selectable])
        }
        // Auf dem Server verschwundene Ordner samt Nachrichten entfernen.
        for r in try db.query("SELECT path FROM c_folder WHERE account = ?", [account]) {
            guard let p = r.string("path"), !keep.contains(p) else { continue }
            try db.exec("DELETE FROM c_message WHERE account = ? AND folder = ?", [account, p])
            try db.exec("DELETE FROM c_folder WHERE account = ? AND path = ?", [account, p])
        }
    }

    func clientUIDValidity(account: String, folder: String) -> UInt32 {
        UInt32(truncatingIfNeeded: ((try? db.query("SELECT uidvalidity FROM c_folder WHERE account = ? AND path = ?", [account, folder]))?.first?.int("uidvalidity")) ?? 0)
    }

    func setClientFolderState(account: String, folder: String, uidValidity: UInt32, uidNext: UInt32) throws {
        try db.exec("UPDATE c_folder SET uidvalidity = ?, uidnext = ?, synced = ? WHERE account = ? AND path = ?",
                    [Int(uidValidity), Int(uidNext), Date(), account, folder])
    }

    func clearClientFolder(account: String, folder: String) throws {
        try db.exec("DELETE FROM c_message WHERE account = ? AND folder = ?", [account, folder])
    }

    func clientUIDs(account: String, folder: String) -> [UInt32] {
        ((try? db.query("SELECT uid FROM c_message WHERE account = ? AND folder = ?", [account, folder])) ?? []).map { UInt32(truncatingIfNeeded: $0.int("uid")) }
    }

    func deleteClientMessages(account: String, folder: String, uids: [UInt32]) throws {
        for chunk in stride(from: 0, to: uids.count, by: 400).map({ Array(uids[$0..<min($0 + 400, uids.count)]) }) {
            try db.exec("DELETE FROM c_message WHERE account = ? AND folder = ? AND uid IN (\(chunk.map { _ in "?" }.joined(separator: ",")))",
                        [account, folder] + chunk.map { Int($0) })
        }
    }

    func saveClientHeader(account: String, folder: String, fetched f: IMAPFetched) throws {
        let head = f.header ?? []
        let info = MIME.headerInfo(head)
        let headers = MIME.parseHeaders(head)
        func h(_ n: String) -> String? { headers.first { $0.name.caseInsensitiveCompare(n) == .orderedSame }?.value }
        // Ohne Message-ID bekommt die Nachricht eine stabile eigene Kennung.
        let id = info.messageId.isEmpty ? "imap-\(account)-\(folder)-\(f.uid)@mailpilot.local" : info.messageId
        try db.exec("""
            INSERT INTO c_message (account, folder, uid, message_id, in_reply_to, refs, subject, sender_name, sender_email, recipients, date, flags, size,
                                   unsub, unsub_post, hdr_flags)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(account, folder, uid) DO UPDATE SET flags = excluded.flags
            """, [account, folder, Int(f.uid), id, info.inReplyTo, info.references.joined(separator: " "), info.subject, info.fromName,
                  info.fromEmail, (info.to + info.cc).joined(separator: "\n"), info.date ?? f.internalDate ?? Date(), f.flags.joined(separator: " "), f.size,
                  h("List-Unsubscribe"), h("List-Unsubscribe-Post"), MIME.automationFlags(headers)])
    }

    func setClientFlags(account: String, folder: String, uid: UInt32, flags: [String]) throws {
        try db.exec("UPDATE c_message SET flags = ? WHERE account = ? AND folder = ? AND uid = ?", [flags.joined(separator: " "), account, folder, Int(uid)])
    }

    func clientFlags(account: String, folder: String, uid: UInt32) -> [String] {
        ((try? db.query("SELECT flags FROM c_message WHERE account = ? AND folder = ? AND uid = ?", [account, folder, Int(uid)]))?.first?.string("flags") ?? "")
            .split(separator: " ").map(String.init)
    }

    func saveClientBody(account: String, folder: String, uid: UInt32, raw: Data, preview: String) throws {
        try db.exec("UPDATE c_message SET raw = ?, preview = ? WHERE account = ? AND folder = ? AND uid = ?", [raw, preview, account, folder, Int(uid)])
    }

    func clientBody(account: String, folder: String, uid: UInt32) -> Data? {
        let d = (try? db.query("SELECT raw FROM c_message WHERE account = ? AND folder = ? AND uid = ?", [account, folder, Int(uid)]))?.first?.data("raw")
        return (d?.isEmpty ?? true) ? nil : d
    }

    func clientMessages(account: String, folder: String, limit: Int = 500) -> [ClientMessage] {
        ((try? db.query("""
            SELECT account, folder, uid, message_id, in_reply_to, refs, subject, sender_name, sender_email, recipients, date, flags, size, preview,
                   unsub, unsub_post, hdr_flags, (raw IS NOT NULL) AS has_body
            FROM c_message WHERE account = ? AND folder = ? ORDER BY date DESC LIMIT ?
            """, [account, folder, limit])) ?? []).map(clientMessage)
    }

    func clientMessage(_ r: Row) -> ClientMessage {
        ClientMessage(account: r.string("account") ?? "", folder: r.string("folder") ?? "", uid: UInt32(truncatingIfNeeded: r.int("uid")),
                      messageId: r.string("message_id") ?? "", inReplyTo: r.string("in_reply_to") ?? "",
                      references: (r.string("refs") ?? "").split(separator: " ").map(String.init),
                      subject: r.string("subject") ?? "", senderName: r.string("sender_name") ?? "", senderEmail: r.string("sender_email") ?? "",
                      recipients: (r.string("recipients") ?? "").components(separatedBy: "\n").filter { !$0.isEmpty },
                      date: r.date("date"), flags: (r.string("flags") ?? "").split(separator: " ").map(String.init), size: r.int("size"),
                      preview: r.string("preview") ?? "", hasBody: r.bool("has_body"),
                      unsub: r.string("unsub"), unsubPost: r.string("unsub_post"), hdrFlags: r.string("hdr_flags") ?? "")
    }

    private static let clientColumns = """
        account, folder, uid, message_id, in_reply_to, refs, subject, sender_name, sender_email, recipients, date, flags, size, preview,
        unsub, unsub_post, hdr_flags, (raw IS NOT NULL) AS has_body
        """

    /// Nachrichten, die noch nicht in die Analyse-Tabelle übernommen wurden.
    func clientCandidates(account: String, folder: String, since: Date, newestFirst: Bool, limit: Int) -> [ClientMessage] {
        ((try? db.query("""
            SELECT \(Self.clientColumns) FROM c_message WHERE account = ? AND folder = ? AND date >= ?
            AND message_id NOT IN (SELECT message_id FROM messages) ORDER BY date \(newestFirst ? "DESC" : "ASC") LIMIT ?
            """, [account, folder, since, limit])) ?? []).map(clientMessage)
    }

    func clientCandidateCount(account: String, folder: String, since: Date) -> Int {
        ((try? db.query("""
            SELECT COUNT(*) AS n FROM c_message WHERE account = ? AND folder = ? AND date >= ? AND message_id NOT IN (SELECT message_id FROM messages)
            """, [account, folder, since]))?.first?.int("n")) ?? 0
    }

    func clientMessage(account: String, folder: String, uid: UInt32) -> ClientMessage? {
        (try? db.query("SELECT \(Self.clientColumns) FROM c_message WHERE account = ? AND folder = ? AND uid = ?", [account, folder, Int(uid)]))?.first.map(clientMessage)
    }

    /// Wo liegt die Nachricht gerade (nach dem letzten Abgleich)?
    func clientLocate(account: String, messageId: String) -> (folder: String, uid: UInt32)? {
        (try? db.query("SELECT folder, uid FROM c_message WHERE account = ? AND message_id = ? LIMIT 1", [account, messageId]))?.first.map {
            ($0.string("folder") ?? "", UInt32(truncatingIfNeeded: $0.int("uid")))
        }
    }

    /// Message-IDs und Lesestatus eines Ordners.
    func clientReadStates(account: String, folder: String) -> [String: Bool] {
        var out: [String: Bool] = [:]
        for r in (try? db.query("SELECT message_id, flags FROM c_message WHERE account = ? AND folder = ?", [account, folder])) ?? [] {
            out[r.string("message_id") ?? ""] = (r.string("flags") ?? "").lowercased().contains("\\seen")
        }
        return out
    }

    func clientFolderSynced(account: String, folder: String) -> Bool {
        ((try? db.query("SELECT synced FROM c_folder WHERE account = ? AND path = ?", [account, folder]))?.first?.double("synced") ?? 0) > 0
    }

    func removeClientAccount(_ account: String) {
        try? db.exec("DELETE FROM c_message WHERE account = ?", [account])
        try? db.exec("DELETE FROM c_folder WHERE account = ?", [account])
    }
}

import Foundation

/// Verbindung zwischen der Analyse-Engine und dem eigenen IMAP-Client: Mails einlesen, Aktionen ausführen,
/// Anhänge lesen, Korrekturen und Lesestatus erkennen. Das Gegenstück zu `MailBridge` für Apple Mail.
enum ClientBackend {
    // MARK: Flaggen (Apple-Mail-Farben als IMAP-Schlüsselwörter)

    /// Apple Mail kodiert die Farbe einer Flagge in `$MailFlagBit0…2` (Wert = Farbindex 0–6, Rot = 0).
    static func flagKeywords(_ index: Int) -> (add: [String], remove: [String]) {
        var add = ["\\Flagged"]
        var remove: [String] = []
        for bit in 0..<3 {
            let keyword = "$MailFlagBit\(bit)"
            if index >= 0, (index >> bit) & 1 == 1 { add.append(keyword) } else { remove.append(keyword) }
        }
        return (add, remove)
    }

    static func flagState(_ flags: [String]) -> (flagged: Bool, index: Int) {
        func has(_ f: String) -> Bool { flags.contains { $0.caseInsensitiveCompare(f) == .orderedSame } }
        guard has("\\Flagged") else { return (false, -1) }
        var index = 0
        for bit in 0..<3 where has("$MailFlagBit\(bit)") { index |= 1 << bit }
        return (true, index)
    }

    /// Pfad mit dem Trennzeichen des Servers („Claude/Rechnungen“ → „Claude.Rechnungen“).
    static func mapPath(_ path: String, delimiter: String) -> String {
        delimiter.isEmpty || delimiter == "/" ? path : path.replacingOccurrences(of: "/", with: delimiter)
    }

    // MARK: Abgleich

    /// Gleicht Ordnerliste, Posteingang, Gesendet und alle Ordner unter dem Präfix (Kategorien, Archiv) mit dem Server ab.
    static func sync(store: Store, client: IMAPClient, account: ClientAccount, prefix: String, includeSent: Bool,
                     inboxLimit: Int, otherLimit: Int = 300) async throws {
        let key = account.id.uuidString
        try await ClientSync.syncFolders(store: store, client: client, account: key)
        for f in store.clientFolders(account: key) where f.selectable {
            let wanted = f.special == "inbox" || (includeSent && f.special == "sent") || (!prefix.isEmpty && f.path.hasPrefix(prefix))
            guard wanted else { continue }
            try await ClientSync.syncFolder(store: store, client: client, account: key, path: f.path, initialLimit: f.special == "inbox" ? inboxLimit : otherLimit)
        }
    }

    // MARK: Einlesen

    struct IngestParams {
        var since: Date
        var sentSince: Date
        var maxNew: Int
        var includeSent: Bool
        var contentLimit: Int
        var inbox = true
        var newestFirst = false
        var minDate: Date?
    }

    /// Neue, noch nicht analysierte Nachrichten als `RawMessage` – wie `MailBridge.fetch` für Apple Mail.
    static func rawMessages(store: Store, client: IMAPClient?, account: ClientAccount, params p: IngestParams) async -> (messages: [RawMessage], remaining: Int) {
        let key = account.id.uuidString
        let folders = store.clientFolders(account: key)
        var specs: [(path: String, isSent: Bool, since: Date)] = []
        if p.inbox, let f = folders.first(where: { $0.special == "inbox" }) { specs.append((f.path, false, max(p.since, p.minDate ?? p.since))) }
        if p.includeSent, let f = folders.first(where: { $0.special == "sent" }) { specs.append((f.path, true, p.sentSince)) }

        var out: [RawMessage] = []
        var remaining = 0
        for spec in specs {
            let total = store.clientCandidateCount(account: key, folder: spec.path, since: spec.since)
            let room = p.maxNew - out.count
            guard room > 0 else { remaining += total; continue }
            let rows = store.clientCandidates(account: key, folder: spec.path, since: spec.since, newestFirst: p.newestFirst, limit: room)
            remaining += max(0, total - rows.count)
            for m in rows {
                guard let data = try? await ClientSync.loadBody(store: store, client: client, account: key, path: spec.path, uid: m.uid) else { continue }
                let parsed = MIME.extract(MIME.parse(Array(data)))
                let sender = m.senderName.isEmpty ? m.senderEmail : "\(m.senderName) <\(m.senderEmail)>"
                out.append(RawMessage(id: Int(m.uid), messageId: m.messageId, account: account.engineName, mailbox: spec.path, subject: m.subject, sender: sender,
                                      date: m.date.isoString, read: m.isRead, inReplyTo: m.inReplyTo.isEmpty ? nil : m.inReplyTo, references: m.references,
                                      to: m.recipients, cc: [], content: String(parsed.plainText.prefix(p.contentLimit)), isSent: spec.isSent,
                                      unsubscribe: m.unsub, unsubscribePost: m.unsubPost, headerFlags: m.hdrFlags))
            }
        }
        return (out, remaining)
    }

    // MARK: Aktionen

    /// UID einer Nachricht: aus dem Speicher, sonst per Suche nach der Message-ID auf dem Server.
    static func locate(store: Store, client: IMAPClient, key: String, mailbox: String, uid: Int, messageId: String) async throws -> (folder: String, uid: UInt32)? {
        if uid > 0, let m = store.clientMessage(account: key, folder: mailbox, uid: UInt32(uid)), m.messageId == messageId { return (mailbox, UInt32(uid)) }
        if let u = try? await client.searchMessageID(mailbox, messageId: messageId) { return (mailbox, u) }
        return store.clientLocate(account: key, messageId: messageId).map { ($0.folder, $0.uid) }
    }

    /// Verschieben und Markieren – wie `MailBridge.batch`. Jede Nachricht wird einzeln behandelt, Fehler betreffen nur sie.
    static func batch(store: Store, client: IMAPClient, account: ClientAccount, items: [MailBridge.BatchItem]) async -> [MailBridge.BatchResult] {
        let key = account.id.uuidString
        var results: [MailBridge.BatchResult] = []
        for it in items {
            var r = MailBridge.BatchResult(messageId: it.messageId, ok: true)
            do {
                guard let loc = try await locate(store: store, client: client, key: key, mailbox: it.location.mailbox, uid: it.location.mailId, messageId: it.messageId) else {
                    throw IMAPError.command("Nachricht nicht gefunden")
                }
                var folder = loc.folder
                var uid = loc.uid
                let current = store.clientMessage(account: key, folder: folder, uid: uid)?.flags ?? []
                if let restore = it.restoreFlag {
                    if restore.flagged {
                        let k = flagKeywords(restore.index)
                        try await client.setFlags(folder, uid: uid, add: k.add, remove: k.remove)
                    } else {
                        try await client.setFlags(folder, uid: uid, remove: ["\\Flagged"] + (0..<3).map { "$MailFlagBit\($0)" })
                    }
                }
                if let flag = it.flag {
                    let prev = flagState(current)
                    r.prevFlagged = prev.flagged
                    r.prevFlagIndex = prev.index
                    let k = flagKeywords(flag.rawValue)
                    try await client.setFlags(folder, uid: uid, add: k.add, remove: k.remove)
                    var flags = current.filter { f in !(k.add + k.remove).contains { $0.caseInsensitiveCompare(f) == .orderedSame } }
                    flags += k.add
                    try? store.setClientFlags(account: key, folder: folder, uid: uid, flags: flags)
                }
                if let target = it.target {
                    let delimiter = store.clientFolders(account: key).first?.delimiter ?? "/"
                    let dest = target == MailBridge.inboxToken ? (store.clientFolders(account: key).first { $0.special == "inbox" }?.path ?? "INBOX")
                                                              : mapPath(target, delimiter: delimiter)
                    if dest != folder {
                        if !store.clientFolders(account: key).contains(where: { $0.path == dest }) {
                            try await client.createFolder(dest)
                            try await ClientSync.syncFolders(store: store, client: client, account: key)
                        }
                        var newUID = try await client.move(folder, uid: uid, to: dest)
                        if newUID == nil { newUID = try? await client.searchMessageID(dest, messageId: it.messageId) }
                        try? store.deleteClientMessages(account: key, folder: folder, uids: [uid])
                        r.verified = newUID != nil
                        r.newId = newUID.map { Int($0) }
                        r.mailbox = dest
                        folder = dest
                        uid = newUID ?? 0
                    }
                }
            } catch {
                r.ok = false
                r.error = error.localizedDescription
            }
            results.append(r)
        }
        return results
    }

    // MARK: Anhänge

    /// PDFs (bis 12 MB) und Kalenderdateien (bis 2 MB) einer Nachricht in `dir` ablegen – wie `MailBridge.attachments`.
    static func attachments(store: Store, client: IMAPClient?, account: ClientAccount, mailbox: String, uid: Int, messageId: String, dir: URL, ics: Bool) async throws -> [MailBridge.AttachmentInfo] {
        let key = account.id.uuidString
        var u = UInt32(max(uid, 0))
        if u == 0 || store.clientMessage(account: key, folder: mailbox, uid: u) == nil {
            if let l = store.clientLocate(account: key, messageId: messageId) { u = l.uid } else { throw IMAPError.command("Nachricht nicht gefunden") }
        }
        let folder = store.clientMessage(account: key, folder: mailbox, uid: u) != nil ? mailbox : (store.clientLocate(account: key, messageId: messageId)?.folder ?? mailbox)
        let raw = try await ClientSync.loadBody(store: store, client: client, account: key, path: folder, uid: u)
        let parsed = MIME.extract(MIME.parse(Array(raw)))
        var out: [MailBridge.AttachmentInfo] = []
        for (i, a) in parsed.attachments.enumerated() {
            var info = MailBridge.AttachmentInfo(name: a.name, mimeType: a.mime, size: a.data.count, downloaded: true, saved: nil, error: nil)
            let isPDF = a.mime.contains("pdf") || a.name.lowercased().hasSuffix(".pdf")
            let isICS = ics && (a.mime.contains("calendar") || a.name.lowercased().hasSuffix(".ics"))
            if (isPDF && a.data.count < 12_000_000) || (isICS && a.data.count < 2_000_000) {
                let safe = a.name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
                let url = dir.appendingPathComponent("\(i)-\(safe)")
                do { try a.data.write(to: url); info.saved = url.path } catch { info.error = error.localizedDescription }
            }
            out.append(info)
        }
        return out
    }

    // MARK: Korrekturen und Lesestatus (aus dem lokalen Abgleich)

    /// Message-IDs je Ordner; nicht abgeglichene Ordner fehlen im Ergebnis.
    static func listing(store: Store, account: ClientAccount, paths: [String]) -> [String: Set<String>] {
        let key = account.id.uuidString
        var out: [String: Set<String>] = [:]
        for p in paths where store.clientFolderSynced(account: key, folder: p) { out[p] = Set(store.clientReadStates(account: key, folder: p).keys) }
        return out
    }

    static func inboxMembership(store: Store, account: ClientAccount, ids: [String]) -> (inbox: String, found: Set<String>)? {
        let key = account.id.uuidString
        guard let inbox = store.clientFolders(account: key).first(where: { $0.special == "inbox" }) else { return nil }
        let here = Set(store.clientReadStates(account: key, folder: inbox.path).keys)
        return (inbox.path, Set(ids).intersection(here))
    }

    static func readStates(store: Store, account: ClientAccount, folder: String) -> [String: Bool] {
        store.clientReadStates(account: account.id.uuidString, folder: folder)
    }
}

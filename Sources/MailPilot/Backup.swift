import Foundation

/// Sicherung und Export der lokalen Daten.
enum Backups {
    static var folder: URL { folder(in: Paths.appSupport) }

    static func folder(in support: URL) -> URL {
        let dir = support.appendingPathComponent("backups", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return dir
    }

    static func pendingRestore(in support: URL = Paths.appSupport) -> URL { support.appendingPathComponent("restore-pending.sqlite") }

    struct Entry: Identifiable, Hashable {
        var url: URL
        var date: Date
        var size: Int64
        var id: URL { url }
    }

    /// Vorhandene Sicherungen, neueste zuerst.
    static func list(in support: URL = Paths.appSupport) -> [Entry] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder(in: support), includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])) ?? []
        return files.filter { $0.lastPathComponent.hasPrefix("mailpilot-") && $0.pathExtension == "sqlite" }.compactMap { u in
            let v = try? u.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            return Entry(url: u, date: v?.contentModificationDate ?? .distantPast, size: Int64(v?.fileSize ?? 0))
        }.sorted { $0.date > $1.date }
    }

    static func fileName(for date: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmm"
        f.locale = Locale(identifier: "en_US_POSIX")
        return "mailpilot-\(f.string(from: date)).sqlite"
    }

    /// Konsistenter Schnappschuss der laufenden Datenbank (`VACUUM INTO`), nur für den Besitzer lesbar.
    @discardableResult
    static func create(store: Store, at url: URL) throws -> URL {
        try? FileManager.default.removeItem(at: url)
        try store.db.exec("VACUUM INTO '\(url.path.replacingOccurrences(of: "'", with: "''"))'")
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }

    /// Älteste automatische Sicherungen löschen, die jüngsten `keep` bleiben.
    static func prune(keep: Int, in support: URL = Paths.appSupport) {
        for e in list(in: support).dropFirst(max(1, keep)) { try? FileManager.default.removeItem(at: e.url) }
    }

    /// Prüft eine Sicherungsdatei, ohne sie zu verändern (arbeitet an einer Kopie).
    static func validate(_ url: URL) -> String? {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mp-validate-\(UUID()).sqlite")
        defer { for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: tmp.path + s) } }
        do {
            try FileManager.default.copyItem(at: url, to: tmp)
            let db = try Database(path: tmp.path)
            guard (try db.query("PRAGMA integrity_check").first?.string("integrity_check")) == "ok" else { return "Die Datei ist beschädigt." }
            let tables = Set(try db.query("SELECT name FROM sqlite_master WHERE type = 'table'").compactMap { $0.string("name") })
            guard tables.isSuperset(of: ["messages", "threads", "activity"]) else { return "Das ist keine MailPilot-Sicherung." }
            return nil
        } catch {
            return "Die Datei lässt sich nicht öffnen: \(error.localizedDescription)"
        }
    }

    /// Legt die Sicherung für den nächsten Start bereit (die laufende Datenbank bleibt bis dahin unberührt).
    static func stageRestore(from url: URL, in support: URL = Paths.appSupport) throws {
        let pending = pendingRestore(in: support)
        try? FileManager.default.removeItem(at: pending)
        try FileManager.default.copyItem(at: url, to: pending)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pending.path)
    }

    /// Beim Start, bevor die Datenbank geöffnet wird: wartende Wiederherstellung einspielen.
    /// Der bisherige Stand bleibt als „vor-wiederherstellung-…“ im Sicherungsordner erhalten.
    @discardableResult
    static func applyPendingRestore(in support: URL = Paths.appSupport) -> Bool {
        let fm = FileManager.default
        let pending = pendingRestore(in: support)
        let database = support.appendingPathComponent("mailpilot.sqlite")
        guard fm.fileExists(atPath: pending.path) else { return false }
        let stamp = fileName().replacingOccurrences(of: "mailpilot-", with: "vor-wiederherstellung-").replacingOccurrences(of: ".sqlite", with: "")
        for suffix in ["", "-wal", "-shm"] {
            let src = URL(fileURLWithPath: database.path + suffix)
            if fm.fileExists(atPath: src.path) {
                try? fm.moveItem(at: src, to: folder(in: support).appendingPathComponent("\(stamp).sqlite\(suffix)"))
            }
        }
        do {
            try fm.moveItem(at: pending, to: database)
            return true
        } catch {
            return false
        }
    }
}

/// Export der Gespräche und Daten als JSON bzw. CSV.
enum DataExport {
    private static let iso: ISO8601DateFormatter = ISO8601DateFormatter()

    /// JSON mit Gesprächen, Mails, Rechnungen und Einstellungen. Vertrauliche Mails haben nie Text; Mailtexte nur auf Wunsch.
    static func json(store: Store, accounts: [String], settings: AppSettings, includeBodies: Bool) throws -> Data {
        let messages = try store.allMessages(accounts: accounts, limit: 200_000).map { m -> [String: Any] in
            var d: [String: Any] = [
                "messageId": m.messageId, "account": m.account, "mailbox": m.mailbox, "date": iso.string(from: m.date), "from": m.sender,
                "to": m.recipients, "subject": m.subject, "sentByMe": m.isFromMe, "private": m.isPrivate,
            ]
            if let t = m.threadKey { d["threadKey"] = t }
            if let c = m.category { d["category"] = c }
            if let p = m.priority { d["priority"] = p.rawValue }
            if let s = m.summary { d["summary"] = s }
            if includeBodies, !m.isPrivate { d["body"] = m.content }
            return d
        }
        let threads = try store.threads(accounts: accounts, limit: 100_000).map { t -> [String: Any] in
            var d: [String: Any] = [
                "threadKey": t.threadKey, "subject": t.subject, "counterpart": t.counterpart, "status": t.status.rawValue, "priority": t.priority.rawValue,
                "lastMessage": iso.string(from: t.lastDate), "messageCount": t.messageCount, "summary": t.summary, "nextStep": t.nextStep, "private": t.isPrivate,
            ]
            if let c = t.category { d["category"] = c }
            if let due = t.dueDate { d["dueDate"] = due }
            if let s = t.snoozedUntil { d["snoozedUntil"] = iso.string(from: s) }
            return d
        }
        let invoices = try store.invoices(accounts: accounts).map { i -> [String: Any] in
            var d: [String: Any] = ["messageId": i.messageId, "vendor": i.vendor, "currency": i.currency, "paid": i.paid, "status": i.status, "source": i.source, "account": i.account]
            if let a = i.amount { d["amountGross"] = a }
            if let v = i.vat { d["vat"] = v }
            if let n = i.number { d["number"] = n }
            if let x = i.issueDate { d["issueDate"] = x }
            if let x = i.dueDate { d["dueDate"] = x }
            return d
        }
        let settingsJSON = (try? JSONEncoder().encode(settings)).flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? [:]
        let root: [String: Any] = [
            "app": "MailPilot", "exportedAt": iso.string(from: Date()), "includesBodies": includeBodies,
            "threads": threads, "messages": messages, "invoices": invoices, "settings": settingsJSON,
        ]
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    /// Gespräche als CSV (Semikolon, UTF-8 mit BOM) – ohne vertrauliche Gespräche.
    static func threadsCSV(_ threads: [MailThread]) -> String {
        let f = DateFormatter()
        f.dateFormat = "dd.MM.yyyy"
        var lines = ["Betreff;Gegenüber;Status;Priorität;Kategorie;Frist;Letzte Nachricht;Nachrichten;Zusammenfassung;Nächster Schritt"]
        for t in threads where !t.isPrivate {
            let due = Deadlines.parse(t.dueDate).map { f.string(from: $0) } ?? ""
            lines.append([InvoiceCSV.text(t.subject), InvoiceCSV.text(t.counterpart), t.status.label, t.priority.label, InvoiceCSV.text(t.category ?? ""), due,
                          f.string(from: t.lastDate), "\(t.messageCount)", InvoiceCSV.text(t.summary), InvoiceCSV.text(t.nextStep)].joined(separator: ";"))
        }
        return "\u{FEFF}" + lines.joined(separator: "\r\n") + "\r\n"
    }
}

import Foundation

/// Abgleich zwischen IMAP-Server und lokalem Speicher.
enum ClientSync {
    /// Ordnerliste holen und speichern.
    static func syncFolders(store: Store, client: IMAPClient, account: String) async throws {
        let folders = try await client.listFolders()
        try store.saveClientFolders(account: account, folders: folders)
    }

    /// Gleicht einen Ordner ab: neue Nachrichten laden (beim ersten Mal die neuesten `initialLimit`), verschwundene entfernen,
    /// Flags aktualisieren. Ändert sich die UIDVALIDITY, wird der Ordner lokal neu aufgebaut.
    /// Rückgabe: Zahl neu geladener Nachrichten.
    @discardableResult
    static func syncFolder(store: Store, client: IMAPClient, account: String, path: String, initialLimit: Int = 200) async throws -> Int {
        let (status, serverUIDs) = try await client.folderState(path)
        let known = store.clientUIDValidity(account: account, folder: path)
        if known != 0, known != status.uidValidity {
            try store.clearClientFolder(account: account, folder: path)
        }
        let local = Set(store.clientUIDs(account: account, folder: path))
        let server = Set(serverUIDs)

        let gone = Array(local.subtracting(server))
        if !gone.isEmpty { try store.deleteClientMessages(account: account, folder: path, uids: gone) }

        var fresh = server.subtracting(local).sorted()
        if local.isEmpty, fresh.count > initialLimit { fresh = Array(fresh.suffix(initialLimit)) }
        if !fresh.isEmpty {
            for f in try await client.fetchHeaders(path, uids: fresh) where f.header != nil {
                try store.saveClientHeader(account: account, folder: path, fetched: f)
            }
        }

        // Flags der bereits bekannten Nachrichten (gelesen auf einem anderen Gerät, markiert …)
        let kept = Array(local.intersection(server))
        if !kept.isEmpty {
            let recent = Array(kept.sorted().suffix(2000))
            for (uid, flags) in try await client.fetchFlags(path, uids: recent) {
                try store.setClientFlags(account: account, folder: path, uid: uid, flags: flags)
            }
        }
        try store.setClientFolderState(account: account, folder: path, uidValidity: status.uidValidity, uidNext: status.uidNext)
        return fresh.count
    }

    /// Nachricht lesen: aus dem Speicher oder vom Server (und dann zwischenspeichern).
    static func loadBody(store: Store, client: IMAPClient?, account: String, path: String, uid: UInt32) async throws -> Data {
        if let cached = store.clientBody(account: account, folder: path, uid: uid) { return cached }
        guard let client else { throw IMAPError.connection("Nicht verbunden.") }
        let raw = Data(try await client.fetchBody(path, uid: uid))
        let parsed = MIME.extract(MIME.parse(Array(raw)))
        try store.saveClientBody(account: account, folder: path, uid: uid, raw: raw, preview: parsed.preview)
        return raw
    }
}

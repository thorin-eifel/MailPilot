import AppKit
import Foundation

/// Verteilt die Zugriffe der Engine auf Apple Mail (`MailBridge`) und den eigenen IMAP-Client (`ClientBackend`).
extension Engine {
    func clientAccount(named name: String) -> ClientAccount? { settings.clientAccounts.first { $0.engineName == name } }
    func isClientAccount(_ name: String) -> Bool { clientAccount(named: name) != nil }

    /// Konten für Anzeige und Analyse: Apple Mail (falls verwendet) und eigene IMAP-Konten.
    func listAllAccounts() async -> [MailAccountInfo] {
        var apple: [MailAccountInfo] = []
        if settings.useAppleMail {
            do {
                apple = try await bridge.listAccounts()
            } catch {
                lastError = settings.clientAccounts.isEmpty ? error.localizedDescription : "Apple Mail: \(error.localizedDescription)"
            }
        }
        let mine = settings.clientAccounts.map { a -> MailAccountInfo in
            let inbox = store.clientFolders(account: a.id.uuidString).first { $0.special == "inbox" }?.path ?? "INBOX"
            let n = ((try? store.db.query("SELECT COUNT(*) AS n FROM c_message WHERE account = ? AND folder = ?", [a.id.uuidString, inbox]))?.first?.int("n")) ?? 0
            return MailAccountInfo(name: a.engineName, emails: [a.email], inboxCount: n)
        }
        return apple + mine
    }

    // MARK: Abgleich und Einlesen

    /// Gleicht die angegebenen IMAP-Konten mit dem Server ab. Fehler eines Kontos werden gemeldet und stoppen die anderen nicht.
    func syncClientAccounts(_ names: [String]) async {
        for name in names {
            guard let account = clientAccount(named: name) else { continue }
            do {
                let client = try await ClientModel.shared.connectedClient(account)
                try await ClientBackend.sync(store: store, client: client, account: account, prefix: settings.folderPrefix, includeSent: settings.includeSent,
                                             inboxLimit: settings.initialScanDays == 0 ? 20_000 : 3_000)
            } catch {
                lastError = "\(account.name): \(error.localizedDescription)"
                ClientModel.shared.dropClient(account)
            }
        }
    }

    /// Wie `MailBridge.fetch`, aber über beide Quellen. Apple Mail wird nur gefragt, wenn ein Apple-Konto dabei ist.
    func fetchMail(since: Date, sentSince: Date? = nil, accounts names: [String], known: [String], maxNew: Int, includeSent: Bool, contentLimit: Int = 6000,
                   inbox: Bool = true, newestFirst: Bool = false, minDate: Date? = nil) async throws -> FetchResult {
        let appleNames = names.filter { !isClientAccount($0) }
        var result = FetchResult(messages: [], myAddresses: [], remaining: 0)
        if !appleNames.isEmpty, settings.useAppleMail {
            result = try await bridge.fetch(since: since, sentSince: sentSince, accounts: appleNames, known: known, maxNew: maxNew, includeSent: includeSent,
                                            contentLimit: contentLimit, inbox: inbox, newestFirst: newestFirst, minDate: minDate)
        }
        for name in names {
            guard let account = clientAccount(named: name) else { continue }
            let client = try? await ClientModel.shared.connectedClient(account)
            let params = ClientBackend.IngestParams(since: since, sentSince: sentSince ?? since, maxNew: max(0, maxNew - result.messages.count), includeSent: includeSent,
                                                    contentLimit: contentLimit, inbox: inbox, newestFirst: newestFirst, minDate: minDate)
            let r = await ClientBackend.rawMessages(store: store, client: client, account: account, params: params)
            result.messages += r.messages
            result.remaining += r.remaining
            result.myAddresses.append(account.email.lowercased())
        }
        return result
    }

    // MARK: Aktionen

    /// Wie `MailBridge.batch`, verteilt nach Konto; die Reihenfolge der Ergebnisse entspricht der der Aufträge.
    func runBatch(_ items: [MailBridge.BatchItem]) async throws -> [MailBridge.BatchResult] {
        var results = [MailBridge.BatchResult?](repeating: nil, count: items.count)
        var apple: [(index: Int, item: MailBridge.BatchItem)] = []
        var byClient: [String: [(index: Int, item: MailBridge.BatchItem)]] = [:]
        for (i, it) in items.enumerated() {
            if isClientAccount(it.location.account) { byClient[it.location.account, default: []].append((i, it)) } else { apple.append((i, it)) }
        }
        if !apple.isEmpty {
            for (entry, r) in zip(apple, try await bridge.batch(apple.map(\.item))) { results[entry.index] = r }
        }
        for (name, list) in byClient {
            guard let account = clientAccount(named: name) else { continue }
            do {
                let client = try await ClientModel.shared.connectedClient(account)
                for (entry, r) in zip(list, await ClientBackend.batch(store: store, client: client, account: account, items: list.map(\.item))) { results[entry.index] = r }
            } catch {
                ClientModel.shared.dropClient(account)
                for entry in list { results[entry.index] = MailBridge.BatchResult(messageId: entry.item.messageId, ok: false, error: error.localizedDescription) }
            }
        }
        return results.enumerated().map { $0.element ?? MailBridge.BatchResult(messageId: items[$0.offset].messageId, ok: false, error: "Konto nicht verfügbar") }
    }

    /// Verschiebt eine Nachricht (Rückgängig). Rückgabe: neuer Ordner und neue UID bzw. 0.
    func moveMessage(_ m: StoredMessage, from mailbox: String, to folder: String) async throws -> (mailbox: String, mailId: Int) {
        if isClientAccount(m.account) {
            let item = MailBridge.BatchItem(messageId: m.messageId, location: .init(account: m.account, mailbox: mailbox, mailId: m.mailId), target: folder, flag: nil)
            guard let r = try await runBatch([item]).first, r.ok else { throw IMAPError.command("Verschieben fehlgeschlagen") }
            return (r.mailbox ?? folder, r.newId ?? 0)
        }
        let loc = MailBridge.Location(account: m.account, mailbox: mailbox, mailId: m.mailId)
        let back = try await bridge.move(messageId: m.messageId, from: loc, to: folder)
        return (back.mailbox, back.mailId)
    }

    // MARK: Anhänge

    func fetchAttachments(for m: StoredMessage, saveTo dir: URL, ics: Bool = false) async throws -> [MailBridge.AttachmentInfo] {
        if let account = clientAccount(named: m.account) {
            let client = try? await ClientModel.shared.connectedClient(account)
            return try await ClientBackend.attachments(store: store, client: client, account: account, mailbox: m.mailbox, uid: m.mailId, messageId: m.messageId, dir: dir, ics: ics)
        }
        return try await bridge.attachments(account: m.account, mailbox: m.mailbox, id: m.mailId, messageId: m.messageId, saveTo: dir, ics: ics)
    }

    // MARK: Korrekturen und Lesestatus

    func folderListing(_ refs: [MailBridge.FolderRef]) async throws -> [MailBridge.FolderRef: [String]] {
        var out: [MailBridge.FolderRef: [String]] = [:]
        let apple = refs.filter { !isClientAccount($0.account) }
        if !apple.isEmpty { out = try await bridge.folderContents(apple) }
        for (name, group) in Dictionary(grouping: refs.filter { isClientAccount($0.account) }, by: \.account) {
            guard let account = clientAccount(named: name) else { continue }
            for (path, ids) in ClientBackend.listing(store: store, account: account, paths: group.map(\.path)) { out[.init(account: name, path: path)] = Array(ids) }
        }
        return out
    }

    func inboxMembershipAny(account name: String, ids: [String]) async throws -> (inbox: String, found: Set<String>) {
        if let account = clientAccount(named: name) {
            guard let r = ClientBackend.inboxMembership(store: store, account: account, ids: ids) else { throw IMAPError.command("Posteingang unbekannt") }
            return r
        }
        return try await bridge.inboxMembership(account: name, ids: ids)
    }

    func readStatesAny(_ refs: [MailBridge.FolderRef]) async throws -> [MailBridge.FolderRef: [String: Bool]] {
        var out: [MailBridge.FolderRef: [String: Bool]] = [:]
        let apple = refs.filter { !isClientAccount($0.account) }
        if !apple.isEmpty { out = try await bridge.readStates(apple) }
        for ref in refs {
            if let account = clientAccount(named: ref.account) { out[ref] = ClientBackend.readStates(store: store, account: account, folder: ref.path) }
        }
        return out
    }

    // MARK: Nachrichten öffnen und verfassen

    /// Öffnet eine Nachricht: im eigenen Postfach oder in Apple Mail.
    func openMessage(messageId: String) {
        guard let m = try? store.message(id: messageId) else { return }
        if let account = clientAccount(named: m.account) {
            requestedSidebar = .mailbox
            openDashboard?()
            Task { await ClientModel.shared.reveal(accountKey: account.id.uuidString, messageId: m.messageId) }
        } else if let url = m.mailURL {
            NSWorkspace.shared.open(url)
        }
    }

    /// Antwort auf eine Nachricht des eigenen Clients: öffnet das Verfassen-Fenster mit dem Entwurf oder legt ihn still in „Entwürfe“ ab.
    func clientReply(to m: StoredMessage, account: ClientAccount, text: String, replyAll: Bool, save: Bool) async {
        let key = account.id.uuidString
        guard let loc = (store.clientMessage(account: key, folder: m.mailbox, uid: UInt32(max(m.mailId, 0))) != nil ? (m.mailbox, UInt32(m.mailId)) : nil)
                ?? store.clientLocate(account: key, messageId: m.messageId).map({ ($0.folder, $0.uid) }),
              let cm = store.clientMessage(account: key, folder: loc.0, uid: loc.1) else {
            lastError = "Die Nachricht wurde im Postfach nicht gefunden."
            return
        }
        do {
            let client = try? await ClientModel.shared.connectedClient(account)
            let raw = try await ClientSync.loadBody(store: store, client: client, account: key, path: loc.0, uid: loc.1)
            let bytes = Array(raw)
            let parsed = MIME.extract(MIME.parse(bytes))
            let header = MIME.headerInfo(MIME.splitHeadBody(bytes).head)
            var draft = ComposeDraft.reply(to: cm, header: header, parsed: parsed, accountID: account.id, ownEmail: account.email, all: replyAll)
            if !text.isEmpty { draft.body = text + draft.body }
            await deliver(draft, save: save)
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Nachfrage im eigenen Client: neue Nachricht an dieselben Empfänger, mit Zitat der letzten eigenen Mail.
    func clientFollowUp(account: ClientAccount, to: [String], subject: String, body: String, inReplyTo: StoredMessage?, save: Bool) async {
        var draft = ComposeDraft(accountID: account.id)
        draft.to = to.joined(separator: ", ")
        draft.subject = subject
        draft.body = body
        if let m = inReplyTo {
            draft.inReplyTo = m.messageId
            draft.references = m.references + [m.messageId]
        }
        await deliver(draft, save: save)
    }

    /// Entwurf entweder im Verfassen-Fenster zeigen oder still in „Entwürfe“ ablegen.
    func deliver(_ draft: ComposeDraft, save: Bool) async {
        if save {
            var d = draft
            if let e = await ClientModel.shared.saveDraft(&d) { lastError = e } else { status = "Entwurf im Ordner „Entwürfe“ abgelegt – dort noch prüfen und senden." }
        } else {
            ClientModel.shared.pendingCompose = draft
            requestedSidebar = .mailbox
            openDashboard?()
        }
    }
}

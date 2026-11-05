import Foundation
import SwiftUI

/// Zustand des eigenen Mail-Clients für die Oberfläche: Konten, Ordner, Nachrichten, geöffnete Nachricht.
@MainActor
final class ClientModel: ObservableObject {
    static let shared = ClientModel()

    @Published private(set) var folders: [String: [ClientFolder]] = [:]
    @Published var selectedFolder: ClientFolder?
    @Published private(set) var messages: [ClientMessage] = []
    @Published var selectedMessageID: String?
    /// Von der Seitenleiste ausgelöst: Konto-hinzufügen-Blatt und Rückfrage vor dem Einschalten von Claude.
    @Published var addingAccount = false
    @Published var confirmEnable: ClientAccount?
    /// Claudes Ergebnisse zu den Nachrichten der Liste (nach Message-ID); leer, solange das Konto nicht freigegeben ist.
    @Published private(set) var analysis: [String: StoredMessage] = [:]
    @Published private(set) var opened: ParsedMessage?
    @Published private(set) var openedHeader: MailHeaderInfo?
    @Published private(set) var busy = false
    @Published var status = ""
    @Published var error: String?
    /// Von der Analyse vorbereitete Nachricht (Antwortentwurf, Nachfrage), die das Postfach im Verfassen-Fenster zeigt.
    @Published var pendingCompose: ComposeDraft?

    /// Zustand des Abgleichs je Konto (Schlüssel = Konto-ID), für die Anzeige in der Seitenleiste.
    enum AccountState: Equatable {
        case syncing
        case ok(Date)
        case failed(String)
    }
    @Published private(set) var accountState: [String: AccountState] = [:]
    /// „Alle Posteingänge“: die Posteingänge aller Konten in einer Liste (statt eines einzelnen Ordners).
    @Published private(set) var showAllInboxes = false
    /// Suche im Postfach: Text, Bereich und ob gerade Treffer statt eines Ordners gezeigt werden.
    enum SearchScopeKind: String, CaseIterable, Identifiable {
        case folder, account, all
        var id: String { rawValue }
        var label: String { self == .folder ? "Ordner" : (self == .account ? "Konto" : "Alle Konten") }
    }
    @Published var searchText = ""
    @Published var searchScopeKind: SearchScopeKind = .folder
    @Published private(set) var searchActive = false
    /// Aufgeklappte Konten in der Seitenleiste (Konto-IDs); bleibt zwischen Starts erhalten.
    @Published private(set) var expandedAccounts: Set<String> = []

    /// So viele Konten werden gleichzeitig abgeglichen.
    static let parallelSyncs = 4
    private static let expandedKey = "client.expandedAccounts"

    private var clients: [UUID: IMAPClient] = [:]
    private var running = false

    init() {
        if let saved = UserDefaults.standard.array(forKey: Self.expandedKey) as? [String] { expandedAccounts = Set(saved) }
    }

    func isExpanded(_ accountKey: String) -> Bool {
        if UserDefaults.standard.array(forKey: Self.expandedKey) != nil { return expandedAccounts.contains(accountKey) }
        // Noch nie umgeschaltet: bei wenigen Konten alles offen, bei vielen nur das Konto des gewählten Ordners.
        return accounts.count <= 4 || selectedFolder?.account == accountKey
    }

    func setExpanded(_ accountKey: String, _ on: Bool) {
        var set = UserDefaults.standard.array(forKey: Self.expandedKey) != nil ? expandedAccounts : Set(accounts.map { key($0) }.filter { isExpanded($0) })
        if on { set.insert(accountKey) } else { set.remove(accountKey) }
        expandedAccounts = set
        UserDefaults.standard.set(set.sorted(), forKey: Self.expandedKey)
    }

    func unread(account accountKey: String) -> Int {
        folders[accountKey]?.first { $0.special == "inbox" }?.unread ?? 0
    }

    var totalUnread: Int { accounts.reduce(0) { $0 + unread(account: key($1)) } }

    private var engine: Engine { Engine.shared }
    private var store: Store { engine.store }
    var accounts: [ClientAccount] { engine.settings.clientAccounts }

    func reloadAnalysis() {
        analysis = store.analyses(messageIds: messages.map(\.messageId))
    }

    func thread(for messageId: String) -> MailThread? {
        analysis[messageId]?.threadKey.flatMap { try? store.thread($0) }
    }

    private func key(_ a: ClientAccount) -> String { a.id.uuidString }

    // MARK: Konten

    /// Konto prüfen (Verbindung und Anmeldung) und speichern. Rückgabe: Fehlertext oder `nil`.
    func addAccount(_ account: ClientAccount, password: String) async -> String? {
        var account = account
        if let reason = ClientAccount.rejection(adding: account, to: accounts) { return reason }
        account.name = ClientAccount.uniqueName(account.name, among: accounts)
        // Typografische Striche und unsichtbare Zeichen stören nur beim kopierten iCloud-Passwort; andere Passwörter bleiben unverändert.
        let password = account.isICloud ? ClientAccount.normalizedPassword(password) : password.trimmingCharacters(in: .whitespacesAndNewlines)
        let client = IMAPClient(.init(host: account.host, port: account.port))
        var lastError: String?
        for name in account.loginCandidates {
            do {
                try await client.connect()
                try await client.login(user: name, password: password)
                account.username = name
                lastError = nil
                break
            } catch {
                lastError = error.localizedDescription
                await client.close()
            }
        }
        if let lastError { return lastError }
        guard Keychain.setPassword(password, for: account) else { return "Das Passwort konnte nicht im Schlüsselbund gespeichert werden." }
        clients[account.id] = client
        engine.settings.protectNewAccount(knownAccounts: engine.accounts.map(\.name))
        engine.settings.clientAccounts.append(account)
        Task { await refresh() }
        return nil
    }

    func removeAccount(_ account: ClientAccount) {
        if let c = clients.removeValue(forKey: account.id) { Task { await c.logout() } }
        Keychain.deletePassword(for: account)
        store.removeClientAccount(key(account))
        engine.settings.clientAccounts.removeAll { $0.id == account.id }
        folders[key(account)] = nil
        accountState[key(account)] = nil
        if selectedFolder?.account == key(account) { selectedFolder = nil; messages = [] }
        if showAllInboxes { messages = store.clientUnifiedInbox() }
        var set = expandedAccounts
        if set.remove(key(account)) != nil { expandedAccounts = set; UserDefaults.standard.set(set.sorted(), forKey: Self.expandedKey) }
    }

    /// Ändert Server, Anmeldename, Absendername oder Passwort eines Kontos. Der Name bleibt (die Analyse hängt daran).
    /// Wird ein neues Passwort oder ein anderer Server/Anmeldename angegeben, wird die Anmeldung zuerst geprüft. Rückgabe: Fehlertext oder `nil`.
    func updateAccount(_ updated: ClientAccount, newPassword: String?) async -> String? {
        guard let old = accounts.first(where: { $0.id == updated.id }) else { return "Das Konto gibt es nicht mehr." }
        var updated = updated
        updated.name = old.name
        let typed = newPassword.map { updated.isICloud ? ClientAccount.normalizedPassword($0) : $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
        let connectionChanged = updated.host != old.host || updated.port != old.port || updated.username != old.username
        if typed != nil || connectionChanged {
            guard let password = typed ?? Keychain.password(for: old) else { return "Für den neuen Server bitte das Passwort eingeben." }
            let client = IMAPClient(.init(host: updated.host, port: updated.port))
            do {
                try await client.connect()
                try await client.login(user: updated.username, password: password)
            } catch {
                await client.close()
                return error.localizedDescription
            }
            await client.logout()
            guard Keychain.setPassword(password, for: updated) else { return "Das Passwort konnte nicht im Schlüsselbund gespeichert werden." }
        }
        drop(old)
        if let i = engine.settings.clientAccounts.firstIndex(where: { $0.id == updated.id }) { engine.settings.clientAccounts[i] = updated }
        Task { await refresh() }
        return nil
    }

    func connectedClient(_ account: ClientAccount) async throws -> IMAPClient { try await connected(account) }

    private func connected(_ account: ClientAccount) async throws -> IMAPClient {
        if let c = clients[account.id] { return c }
        guard let password = Keychain.password(for: account) else { throw IMAPError.auth("Kein Passwort im Schlüsselbund. Konto bitte neu hinzufügen.") }
        let c = IMAPClient(.init(host: account.host, port: account.port))
        do {
            try await c.connect()
            try await c.login(user: account.username, password: password)
        } catch {
            await c.close()
            throw error
        }
        clients[account.id] = c
        return c
    }

    func dropClient(_ account: ClientAccount) { drop(account) }

    /// Zeigt eine Nachricht im Postfach: Ordner wählen, Nachricht markieren und öffnen.
    func reveal(accountKey: String, messageId: String) async {
        reloadFolders()
        guard let loc = store.clientLocate(account: accountKey, messageId: messageId),
              let folder = folders[accountKey]?.first(where: { $0.path == loc.folder }) else { return }
        showAllInboxes = false
        selectedFolder = folder
        messages = store.clientMessages(account: accountKey, folder: folder.path)
        setExpanded(accountKey, true)
        guard let m = messages.first(where: { $0.uid == loc.uid }) else { return }
        selectedMessageID = m.id
        await open(m)
    }

    private func drop(_ account: ClientAccount) {
        if let c = clients.removeValue(forKey: account.id) { Task { await c.close() } }
    }

    // MARK: Abgleich

    func reloadFolders() {
        for a in accounts { folders[key(a)] = store.clientFolders(account: key(a)) }
        if selectedFolder == nil, !showAllInboxes, let first = accounts.first.flatMap({ folders[key($0)]?.first }) { selectFolder(first) }
    }

    /// Sucht lokal (Kopfzeilen, Vorschau, bereits geladene Texte) und zeigt die Treffer statt des Ordners; leere Eingabe zeigt den Ordner wieder.
    func applySearch() {
        let q = ClientSearchQuery.parse(searchText)
        guard !q.isEmpty else {
            if searchActive { searchActive = false; restoreList() }
            return
        }
        let scope: ClientSearchScope
        switch searchScopeKind {
        case .all: scope = .all
        case .account: scope = selectedFolder.map { .account($0.account) } ?? .all
        case .folder: scope = selectedFolder.map { .folder(account: $0.account, path: $0.path) } ?? .all
        }
        searchActive = true
        messages = store.clientSearch(q, scope: scope)
        if let id = selectedMessageID, !messages.contains(where: { $0.id == id }) { selectedMessageID = nil; opened = nil }
    }

    private func restoreList() {
        if showAllInboxes { messages = store.clientUnifiedInbox() }
        else if let f = selectedFolder { messages = store.clientMessages(account: f.account, folder: f.path) }
        else { messages = [] }
    }

    private func clearSearch() {
        searchText = ""
        searchActive = false
    }

    /// Bereitet gespeicherte Nachrichten aus älteren Versionen für die Suche auf (im Hintergrund, in kleinen Paketen).
    func reindexBodies() {
        let store = self.store
        Task.detached(priority: .utility) {
            while true {
                let batch = store.clientBodiesWithoutSearchText(limit: 100)
                if batch.isEmpty { break }
                for row in batch {
                    let text = MIME.extract(MIME.parse(Array(row.raw))).plainText
                    store.setClientSearchText(account: row.account, folder: row.folder, uid: row.uid, text: text)
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    /// Die Posteingänge aller Konten zusammen, neueste zuerst.
    func selectAllInboxes() {
        clearSearch()
        showAllInboxes = true
        selectedFolder = nil
        selectedMessageID = nil
        opened = nil
        messages = store.clientUnifiedInbox()
    }

    func accountName(for accountKey: String) -> String { accounts.first { key($0) == accountKey }?.name ?? "" }

    /// „Konto · Ordner“ für Suchtreffer.
    func locationLabel(for m: ClientMessage) -> String {
        let folder = folders[m.account]?.first { $0.path == m.folder }?.leafName ?? m.folder
        return accounts.count > 1 ? "\(accountName(for: m.account)) · \(folder)" : folder
    }

    func selectFolder(_ f: ClientFolder) {
        clearSearch()
        showAllInboxes = false
        selectedFolder = f
        selectedMessageID = nil
        opened = nil
        messages = store.clientMessages(account: f.account, folder: f.path)
        Task { await syncSelected() }
    }

    /// Alle Konten: Ordner und Posteingang, danach der gewählte Ordner. Bis zu `parallelSyncs` Konten gleichzeitig;
    /// ein Fehler oder ein langsames Konto betrifft nur dieses Konto.
    func refresh() async {
        guard !running else { return }
        running = true
        busy = true
        defer { running = false; busy = false }
        error = nil
        let selected = selectedFolder
        let all = accounts
        for a in all { accountState[key(a)] = .syncing }
        var done = 0
        status = "0 von \(all.count) Konten abgeglichen …"
        await forEachConcurrently(all.map(\.id), limit: Self.parallelSyncs) { id in
            await self.syncAccount(id: id, selected: selected)
            await MainActor.run {
                done += 1
                self.status = "\(done) von \(all.count) Konten abgeglichen …"
            }
        }
        if searchActive { applySearch() }
        else if showAllInboxes { messages = store.clientUnifiedInbox() }
        else if let f = selectedFolder { messages = store.clientMessages(account: f.account, folder: f.path) }
        let failed = all.compactMap { a -> String? in
            if case .failed(let m) = accountState[key(a)] { return "\(a.name): \(m)" }
            return nil
        }
        error = failed.isEmpty ? nil : (failed.prefix(3).joined(separator: "\n") + (failed.count > 3 ? "\n… und \(failed.count - 3) weitere" : ""))
        status = failed.isEmpty ? "Aktuell" : "\(failed.count) von \(all.count) Konten mit Fehler"
    }

    private func syncAccount(id: UUID, selected: ClientFolder?) async {
        guard let a = accounts.first(where: { $0.id == id }) else { return }
        do {
            let c = try await connected(a)
            try await ClientSync.syncFolders(store: store, client: c, account: key(a))
            folders[key(a)] = store.clientFolders(account: key(a))
            if selectedFolder == nil, !showAllInboxes, let first = folders[key(a)]?.first { selectedFolder = first }
            if let inbox = folders[key(a)]?.first(where: { $0.special == "inbox" }) {
                try await ClientSync.syncFolder(store: store, client: c, account: key(a), path: inbox.path)
            }
            if let f = selected, f.account == key(a), f.special != "inbox", f.selectable {
                try await ClientSync.syncFolder(store: store, client: c, account: key(a), path: f.path)
            }
            folders[key(a)] = store.clientFolders(account: key(a))
            accountState[key(a)] = .ok(Date())
        } catch {
            accountState[key(a)] = .failed(error.localizedDescription)
            drop(a)
        }
    }

    func syncSelected() async {
        if showAllInboxes { await refresh(); return }
        guard let f = selectedFolder, f.selectable, let a = accounts.first(where: { key($0) == f.account }) else { return }
        busy = true
        defer { busy = false }
        do {
            let c = try await connected(a)
            try await ClientSync.syncFolder(store: store, client: c, account: f.account, path: f.path)
            folders[f.account] = store.clientFolders(account: f.account)
            if selectedFolder?.id == f.id { if searchActive { applySearch() } else { messages = store.clientMessages(account: f.account, folder: f.path) } }
            error = nil
        } catch {
            self.error = "\(a.name): \(error.localizedDescription)"
            drop(a)
        }
    }

    // MARK: Lesen

    func open(_ m: ClientMessage) async {
        guard let a = accounts.first(where: { key($0) == m.account }) else { return }
        do {
            let client = try? await connected(a)
            let raw = try await ClientSync.loadBody(store: store, client: client, account: m.account, path: m.folder, uid: m.uid)
            let bytes = Array(raw)
            let (parsed, header) = await Task.detached { () -> (ParsedMessage, MailHeaderInfo) in
                let part = MIME.parse(bytes)
                return (MIME.extract(part), MIME.headerInfo(MIME.splitHeadBody(bytes).head))
            }.value
            guard selectedMessageID == m.id else { return }
            opened = parsed
            openedHeader = header
            error = nil
            if !m.isRead { await setRead(m, true) }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func setRead(_ m: ClientMessage, _ read: Bool) async {
        var flags = store.clientFlags(account: m.account, folder: m.folder, uid: m.uid)
        flags.removeAll { $0.caseInsensitiveCompare("\\Seen") == .orderedSame }
        if read { flags.append("\\Seen") }
        try? store.setClientFlags(account: m.account, folder: m.folder, uid: m.uid, flags: flags)
        messages = store.clientMessages(account: m.account, folder: m.folder)
        folders[m.account] = store.clientFolders(account: m.account)
        guard let a = accounts.first(where: { key($0) == m.account }), let c = try? await connected(a) else { return }
        try? await c.setFlag(m.folder, uid: m.uid, flag: "\\Seen", on: read)
    }
}

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
    @Published private(set) var opened: ParsedMessage?
    @Published private(set) var openedHeader: MailHeaderInfo?
    @Published private(set) var busy = false
    @Published var status = ""
    @Published var error: String?

    private var clients: [UUID: IMAPClient] = [:]
    private var running = false

    private var engine: Engine { Engine.shared }
    private var store: Store { engine.store }
    var accounts: [ClientAccount] { engine.settings.clientAccounts }

    private func key(_ a: ClientAccount) -> String { a.id.uuidString }

    // MARK: Konten

    /// Konto prüfen (Verbindung und Anmeldung) und speichern. Rückgabe: Fehlertext oder `nil`.
    func addAccount(_ account: ClientAccount, password: String) async -> String? {
        var account = account
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
        if selectedFolder?.account == key(account) { selectedFolder = nil; messages = [] }
    }

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

    private func drop(_ account: ClientAccount) {
        if let c = clients.removeValue(forKey: account.id) { Task { await c.close() } }
    }

    // MARK: Abgleich

    func reloadFolders() {
        for a in accounts { folders[key(a)] = store.clientFolders(account: key(a)) }
        if selectedFolder == nil, let first = accounts.first.flatMap({ folders[key($0)]?.first }) { selectFolder(first) }
    }

    func selectFolder(_ f: ClientFolder) {
        selectedFolder = f
        selectedMessageID = nil
        opened = nil
        messages = store.clientMessages(account: f.account, folder: f.path)
        Task { await syncSelected() }
    }

    /// Alle Konten: Ordner und Posteingang, danach der gewählte Ordner.
    func refresh() async {
        guard !running else { return }
        running = true
        busy = true
        defer { running = false; busy = false }
        error = nil
        for a in accounts {
            do {
                let c = try await connected(a)
                status = "\(a.name): Ordner abgleichen …"
                try await ClientSync.syncFolders(store: store, client: c, account: key(a))
                folders[key(a)] = store.clientFolders(account: key(a))
                if selectedFolder == nil, let first = folders[key(a)]?.first { selectedFolder = first }
                if let inbox = folders[key(a)]?.first(where: { $0.special == "inbox" }) {
                    status = "\(a.name): Posteingang abgleichen …"
                    try await ClientSync.syncFolder(store: store, client: c, account: key(a), path: inbox.path)
                }
                if let f = selectedFolder, f.account == key(a), f.special != "inbox", f.selectable {
                    try await ClientSync.syncFolder(store: store, client: c, account: key(a), path: f.path)
                }
                folders[key(a)] = store.clientFolders(account: key(a))
            } catch {
                self.error = "\(a.name): \(error.localizedDescription)"
                drop(a)
            }
        }
        if let f = selectedFolder { messages = store.clientMessages(account: f.account, folder: f.path) }
        status = error == nil ? "Aktuell" : "Fehler"
    }

    func syncSelected() async {
        guard let f = selectedFolder, f.selectable, let a = accounts.first(where: { key($0) == f.account }) else { return }
        busy = true
        defer { busy = false }
        do {
            let c = try await connected(a)
            try await ClientSync.syncFolder(store: store, client: c, account: f.account, path: f.path)
            folders[f.account] = store.clientFolders(account: f.account)
            if selectedFolder?.id == f.id { messages = store.clientMessages(account: f.account, folder: f.path) }
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

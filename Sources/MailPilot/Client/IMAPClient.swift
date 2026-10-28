import Foundation
import Network

/// Eigener IMAP-Client (Implicit TLS, LOGIN). Ein Befehl nach dem anderen; jede öffentliche Methode sperrt die Verbindung
/// für ihre gesamte Dauer, damit sich Befehlsfolgen (SELECT, FETCH) nicht vermischen.
actor IMAPClient {
    struct Config: Hashable {
        var host: String
        var port: UInt16 = 993
        /// Nur für Tests gegen einen lokalen Server auf `false` setzen.
        var tls = true
    }

    private let config: Config
    private var conn: NWConnection?
    private var buffer: [UInt8] = []
    private var tagCounter = 0
    private var selected: String?
    private(set) var capabilities: Set<String> = []

    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(_ config: Config) { self.config = config }

    // MARK: Sperre

    private func lock() async {
        if locked {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            locked = true
        }
    }

    private func unlock() {
        if waiters.isEmpty { locked = false } else { waiters.removeFirst().resume() }
    }

    private func exclusive<T>(_ body: () async throws -> T) async throws -> T {
        await lock()
        defer { unlock() }
        return try await body()
    }

    // MARK: Verbindung

    private final class Flag: @unchecked Sendable { var fired = false }

    func connect() async throws {
        guard let port = NWEndpoint.Port(rawValue: config.port) else { throw IMAPError.connection("ungültiger Port") }
        let c = NWConnection(host: NWEndpoint.Host(config.host), port: port, using: config.tls ? .tls : .tcp)
        conn = c
        buffer = []
        selected = nil
        let flag = Flag()
        let work = DispatchWorkItem { flag.fired = true; c.cancel() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: work)
        defer { work.cancel() }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            final class Once: @unchecked Sendable { var done = false }
            let once = Once()
            c.stateUpdateHandler = { state in
                guard !once.done else { return }
                switch state {
                case .ready: once.done = true; cont.resume()
                case .failed(let e): once.done = true; cont.resume(throwing: IMAPError.connection(e.localizedDescription))
                case .cancelled: once.done = true; cont.resume(throwing: flag.fired ? IMAPError.timeout : IMAPError.connection("abgebrochen"))
                case .waiting(let e): if flag.fired { once.done = true; cont.resume(throwing: IMAPError.connection(e.localizedDescription)) }
                default: break
                }
            }
            c.start(queue: .global(qos: .utility))
        }
        let greeting = try await readUnit(timeout: 20)
        guard String(decoding: greeting, as: UTF8.self).hasPrefix("* OK") || String(decoding: greeting, as: UTF8.self).hasPrefix("* PREAUTH") else {
            throw IMAPError.connection("Unerwartete Begrüßung")
        }
        try await refreshCapabilities()
    }

    func close() {
        conn?.cancel()
        conn = nil
        locked = false
    }

    private func refreshCapabilities() async throws {
        let r = try await rawRun("CAPABILITY")
        for resp in r where resp.keyword == "CAPABILITY" {
            capabilities = Set(resp.body.dropFirst().compactMap { $0.text?.uppercased() })
        }
    }

    // MARK: Ein- und Ausgabe

    private func send(_ data: Data) async throws {
        guard let c = conn else { throw IMAPError.connection("nicht verbunden") }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            c.send(content: data, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: IMAPError.connection(error.localizedDescription)) } else { cont.resume() }
            })
        }
    }

    private func readChunk(timeout: TimeInterval) async throws {
        guard let c = conn else { throw IMAPError.connection("nicht verbunden") }
        let flag = Flag()
        let data: Data = try await withCheckedThrowingContinuation { cont in
            let work = DispatchWorkItem { flag.fired = true; c.cancel() }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: work)
            c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                work.cancel()
                if let error {
                    cont.resume(throwing: flag.fired ? IMAPError.timeout : IMAPError.connection(error.localizedDescription))
                } else if let data, !data.isEmpty {
                    cont.resume(returning: data)
                } else if isComplete {
                    cont.resume(throwing: IMAPError.connection("Der Server hat die Verbindung beendet."))
                } else {
                    cont.resume(returning: Data())
                }
            }
        }
        buffer.append(contentsOf: data)
    }

    /// `{123}` oder `{123+}` am Zeilenende → Länge des folgenden Literals.
    private static func literalSize(_ line: [UInt8]) -> Int? {
        var end = line.count
        while end > 0, line[end - 1] == 10 || line[end - 1] == 13 { end -= 1 }
        guard end > 2, line[end - 1] == 125 else { return nil }
        var j = end - 2
        if line[j] == 43 { j -= 1 }
        var n = 0
        var mult = 1
        var digits = 0
        while j >= 0, line[j] >= 48, line[j] <= 57 { n += Int(line[j] - 48) * mult; mult *= 10; digits += 1; j -= 1 }
        guard digits > 0, j >= 0, line[j] == 123 else { return nil }
        return n
    }

    /// Liest eine vollständige Antwort: Zeilen samt Literalen, bis eine Zeile ohne Literal endet.
    private func readUnit(timeout: TimeInterval) async throws -> [UInt8] {
        var unit: [UInt8] = []
        while true {
            guard let nl = buffer.firstIndex(of: 10) else {
                try await readChunk(timeout: timeout)
                continue
            }
            let line = Array(buffer[0...nl])
            buffer.removeFirst(nl + 1)
            unit.append(contentsOf: line)
            if let n = Self.literalSize(line) {
                while buffer.count < n { try await readChunk(timeout: timeout) }
                unit.append(contentsOf: buffer.prefix(n))
                buffer.removeFirst(n)
                continue
            }
            return unit
        }
    }

    /// Befehl senden und bis zur getaggten Antwort lesen. Gibt die ungetaggten Antworten zurück.
    private func rawRun(_ command: String, timeout: TimeInterval = 60) async throws -> [IMAPResponse] {
        tagCounter += 1
        let tag = "A\(tagCounter)"
        try await send(Data("\(tag) \(command)\r\n".utf8))
        let prefix = Array((tag + " ").utf8)
        var out: [IMAPResponse] = []
        while true {
            let unit = try await readUnit(timeout: timeout)
            if unit.starts(with: prefix) {
                let rest = String(decoding: unit.dropFirst(prefix.count), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                if rest.uppercased().hasPrefix("OK") { return out }
                throw IMAPError.command(rest)
            }
            if unit.first == 42 { out.append(IMAPResponse(raw: unit)) }
        }
    }

    // MARK: Befehle

    func login(user: String, password: String) async throws {
        guard password.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value < 0x7F }) else {
            throw IMAPError.auth("Das Passwort enthält Sonderzeichen, die dieser Client noch nicht senden kann. Nutze ein App-spezifisches Passwort.")
        }
        try await exclusive {
            do {
                _ = try await rawRun("LOGIN \(IMAPCodec.quote(user)) \(IMAPCodec.quote(password))")
            } catch IMAPError.command(let m) {
                throw IMAPError.auth(m)
            }
            try await refreshCapabilities()
        }
    }

    func logout() async {
        _ = try? await exclusive { try await rawRun("LOGOUT", timeout: 5) }
        close()
    }

    func listFolders() async throws -> [IMAPFolderInfo] {
        try await exclusive {
            let r = try await rawRun("LIST \"\" \"*\"")
            var out: [IMAPFolderInfo] = []
            for resp in r where resp.keyword == "LIST" {
                let t = resp.body
                guard t.count >= 4, let rawName = t[3].text else { continue }
                let attrs = Set(t[1].items.compactMap { $0.text?.lowercased() })
                let delimiter = t[2].text ?? "/"
                let path = IMAPCodec.decodeFolderName(rawName)
                let name = path.split(separator: Character(delimiter.isEmpty ? "/" : delimiter)).last.map(String.init) ?? path
                var special: String?
                if path.caseInsensitiveCompare("INBOX") == .orderedSame { special = "inbox" }
                else if attrs.contains("\\sent") { special = "sent" }
                else if attrs.contains("\\drafts") { special = "drafts" }
                else if attrs.contains("\\trash") { special = "trash" }
                else if attrs.contains("\\junk") { special = "junk" }
                else if attrs.contains("\\archive") { special = "archive" }
                out.append(IMAPFolderInfo(path: path, name: name, delimiter: delimiter, special: special,
                                          selectable: !attrs.contains("\\noselect") && !attrs.contains("\\nonexistent")))
            }
            return out
        }
    }

    @discardableResult
    private func select(_ path: String) async throws -> IMAPMailboxStatus {
        let r = try await rawRun("SELECT \(IMAPCodec.quote(IMAPCodec.encodeFolderName(path)))")
        selected = path
        var st = IMAPMailboxStatus()
        for resp in r {
            if let n = resp.count("EXISTS") { st.exists = n }
            if let v = resp.code("UIDVALIDITY") { st.uidValidity = v }
            if let v = resp.code("UIDNEXT") { st.uidNext = v }
        }
        return st
    }

    /// Ordner öffnen und alle UIDs lesen.
    func folderState(_ path: String) async throws -> (status: IMAPMailboxStatus, uids: [UInt32]) {
        try await exclusive {
            let st = try await select(path)
            guard st.exists > 0 else { return (st, []) }
            let r = try await rawRun("UID SEARCH ALL")
            var uids: [UInt32] = []
            for resp in r where resp.keyword == "SEARCH" { uids += resp.body.dropFirst().compactMap(\.number) }
            return (st, uids)
        }
    }

    private static func parseFetch(_ r: IMAPResponse) -> IMAPFetched? {
        let t = r.body
        guard t.count >= 3, t[0].number != nil, t[1].text?.uppercased() == "FETCH" else { return nil }
        let items = t[2].items
        var f = IMAPFetched(uid: 0)
        var i = 0
        while i + 1 < items.count {
            let name = items[i].text?.uppercased() ?? ""
            let v = items[i + 1]
            switch name {
            case "UID": f.uid = v.number ?? 0
            case "FLAGS": f.flags = v.items.compactMap(\.text)
            case "INTERNALDATE": f.internalDate = v.text.flatMap(IMAPCodec.parseInternalDate)
            case "RFC822.SIZE": f.size = Int(v.number ?? 0)
            case "BODY[HEADER]": f.header = v.bytes
            case "BODY[]": f.body = v.bytes
            default: break
            }
            i += 2
        }
        return f.uid == 0 ? nil : f
    }

    /// Kopfzeilen, Flags, Datum und Größe der angegebenen UIDs (in Paketen).
    func fetchHeaders(_ path: String, uids: [UInt32]) async throws -> [IMAPFetched] {
        try await exclusive {
            if selected != path { try await select(path) }
            var out: [IMAPFetched] = []
            let sorted = uids.sorted()
            for start in stride(from: 0, to: sorted.count, by: 100) {
                let chunk = Array(sorted[start..<min(start + 100, sorted.count)])
                let r = try await rawRun("UID FETCH \(IMAPCodec.uidSet(chunk)) (UID FLAGS INTERNALDATE RFC822.SIZE BODY.PEEK[HEADER])", timeout: 120)
                out += r.compactMap(Self.parseFetch)
            }
            return out
        }
    }

    /// Flags aller Nachrichten des Ordners (UID → Flags).
    func fetchFlags(_ path: String, uids: [UInt32]) async throws -> [UInt32: [String]] {
        try await exclusive {
            if selected != path { try await select(path) }
            var out: [UInt32: [String]] = [:]
            let sorted = uids.sorted()
            for start in stride(from: 0, to: sorted.count, by: 500) {
                let chunk = Array(sorted[start..<min(start + 500, sorted.count)])
                let r = try await rawRun("UID FETCH \(IMAPCodec.uidSet(chunk)) (UID FLAGS)")
                for f in r.compactMap(Self.parseFetch) { out[f.uid] = f.flags }
            }
            return out
        }
    }

    /// Vollständige Nachricht, ohne sie als gelesen zu markieren.
    func fetchBody(_ path: String, uid: UInt32) async throws -> [UInt8] {
        try await exclusive {
            if selected != path { try await select(path) }
            let r = try await rawRun("UID FETCH \(uid) (UID BODY.PEEK[])", timeout: 180)
            guard let body = r.compactMap(Self.parseFetch).first(where: { $0.uid == uid })?.body else {
                throw IMAPError.command("Die Nachricht existiert nicht mehr auf dem Server.")
            }
            return body
        }
    }

    func setFlag(_ path: String, uid: UInt32, flag: String, on: Bool) async throws {
        try await exclusive {
            if selected != path { try await select(path) }
            _ = try await rawRun("UID STORE \(uid) \(on ? "+" : "-")FLAGS.SILENT (\(flag))")
        }
    }

    /// Nachricht in einen Ordner legen (Gesendet, Entwürfe). Rückgabe: die neue UID, wenn der Server UIDPLUS kennt.
    @discardableResult
    func append(_ path: String, flags: [String], message: Data) async throws -> UInt32? {
        try await exclusive {
            tagCounter += 1
            let tag = "A\(tagCounter)"
            let literalPlus = capabilities.contains("LITERAL+")
            let flagText = flags.isEmpty ? "" : " (\(flags.joined(separator: " ")))"
            let cmd = "\(tag) APPEND \(IMAPCodec.quote(IMAPCodec.encodeFolderName(path)))\(flagText) {\(message.count)\(literalPlus ? "+" : "")}\r\n"
            try await send(Data(cmd.utf8))
            let prefix = Array((tag + " ").utf8)
            if !literalPlus {
                // Auf die Aufforderung „+“ warten, bevor die Nachricht gesendet wird.
                while true {
                    let unit = try await readUnit(timeout: 30)
                    if unit.first == 43 { break }
                    if unit.starts(with: prefix) {
                        throw IMAPError.command(String(decoding: unit.dropFirst(prefix.count), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                }
            }
            var payload = message
            payload.append(contentsOf: [13, 10])
            try await send(payload)
            while true {
                let unit = try await readUnit(timeout: 120)
                guard unit.starts(with: prefix) else { continue }
                let rest = String(decoding: unit.dropFirst(prefix.count), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                guard rest.uppercased().hasPrefix("OK") else { throw IMAPError.command(rest) }
                guard let r = rest.range(of: "[APPENDUID ") else { return nil }
                let parts = rest[r.upperBound...].prefix { $0 != "]" }.split(separator: " ")
                return parts.count == 2 ? UInt32(parts[1]) : nil
            }
        }
    }

    /// Nachricht endgültig vom Server entfernen (als gelöscht markieren und expungen).
    func deleteMessage(_ path: String, uid: UInt32) async throws {
        try await exclusive {
            if selected != path { try await select(path) }
            _ = try await rawRun("UID STORE \(uid) +FLAGS.SILENT (\\Deleted)")
            if capabilities.contains("UIDPLUS") {
                _ = try await rawRun("UID EXPUNGE \(uid)")
            } else {
                _ = try await rawRun("EXPUNGE")
            }
        }
    }
}

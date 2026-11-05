import Foundation
import Security

/// Konto des eigenen Mail-Clients. Das Passwort liegt im Schlüsselbund, nie in den Einstellungen.
struct ClientAccount: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var email: String
    var username: String
    var host: String
    var port: UInt16 = 993
    /// Anzeigename im Absender („Anna Beispiel <anna@icloud.com>“).
    var displayName = ""
    var smtpHost = "smtp.mail.me.com"
    var smtpPort: UInt16 = 587
    var smtpSecurity: SMTPSecurity = .startTLS
    /// Signatur (Klartext), wird beim Verfassen unter den Text gesetzt.
    var signature = ""

    static let iCloudHost = "imap.mail.me.com"

    init(id: UUID = UUID(), name: String, email: String, username: String, host: String, port: UInt16 = 993, displayName: String = "") {
        self.id = id; self.name = name; self.email = email; self.username = username; self.host = host; self.port = port
        self.displayName = displayName
    }

    /// Tolerant lesen: Konten aus früheren Versionen ohne die SMTP-Felder bleiben erhalten.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        email = try c.decode(String.self, forKey: .email)
        username = try c.decodeIfPresent(String.self, forKey: .username) ?? email
        host = try c.decode(String.self, forKey: .host)
        port = try c.decodeIfPresent(UInt16.self, forKey: .port) ?? 993
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? ""
        smtpHost = try c.decodeIfPresent(String.self, forKey: .smtpHost) ?? "smtp.mail.me.com"
        smtpPort = try c.decodeIfPresent(UInt16.self, forKey: .smtpPort) ?? 587
        smtpSecurity = try c.decodeIfPresent(SMTPSecurity.self, forKey: .smtpSecurity) ?? .startTLS
        signature = try c.decodeIfPresent(String.self, forKey: .signature) ?? ""
    }

    static func iCloud(email: String, displayName: String = "") -> ClientAccount {
        ClientAccount(name: "iCloud", email: email, username: email, host: iCloudHost, displayName: displayName)
    }

    var isICloud: Bool { host == Self.iCloudHost }

    /// Kontoname in der Analyse (Gespräche, Regeln, Einstellungen): unterscheidet sich vom gleichnamigen Konto in Apple Mail.
    var engineName: String { "\(name) (IMAP)" }

    /// Anmeldenamen, die nacheinander versucht werden: bei iCloud zuerst die volle Adresse, dann der Teil vor dem @.
    var loginCandidates: [String] {
        var names = [username]
        if isICloud, let local = username.split(separator: "@").first, String(local) != username { names.append(String(local)) }
        return names
    }

    var smtpConfig: SMTPConfig { SMTPConfig(host: smtpHost, port: smtpPort, security: smtpSecurity) }
}

extension ClientAccount {
    /// So viele Konten des eigenen Clients kann MailPilot gleichzeitig verwalten.
    static let hardLimit = 16
    /// Die Organisation kann die Zahl weiter begrenzen (Vorgabe `maxAccounts`).
    static var maxAccounts: Int { PolicyStore.current.maxClientAccounts }

    /// Fehlertext, wenn `new` nicht zu `existing` hinzugefügt werden darf (Obergrenze, gleiches Postfach doppelt), sonst `nil`.
    static func rejection(adding new: ClientAccount, to existing: [ClientAccount]) -> String? {
        if existing.count >= maxAccounts { return "Mehr als \(maxAccounts) Konten sind nicht möglich. Entferne zuerst ein Konto." }
        let mail = new.email.lowercased()
        if existing.contains(where: { $0.email.lowercased() == mail && $0.host.lowercased() == new.host.lowercased() }) {
            return "Dieses Konto (\(new.email)) ist bereits verbunden."
        }
        return nil
    }

    /// Kontoname, der unter den vorhandenen noch frei ist („GMX“, „GMX 2“, „GMX 3“ …). Der Name erscheint als „<Name> (IMAP)“ in der Analyse.
    static func uniqueName(_ wanted: String, among existing: [ClientAccount]) -> String {
        let taken = Set(existing.map { $0.name.lowercased() })
        if !taken.contains(wanted.lowercased()) { return wanted }
        var n = 2
        while taken.contains("\(wanted) \(n)".lowercased()) { n += 1 }
        return "\(wanted) \(n)"
    }

    /// Beim Kopieren von appleid.apple.com kommen oft typografische Bindestriche (‑ – −) oder unsichtbare Zeichen mit.
    /// Die werden zu „-“ bzw. entfernt; echte Sonderzeichen bleiben stehen und werden vom Client gemeldet.
    static func normalizedPassword(_ raw: String) -> String {
        let dashes: Set<UInt32> = [0x2010, 0x2011, 0x2012, 0x2013, 0x2014, 0x2015, 0x2212, 0xFE63, 0xFF0D, 0x00AD]
        var out = String.UnicodeScalarView()
        for u in raw.unicodeScalars {
            if dashes.contains(u.value) { out.append("-"); continue }
            switch u.properties.generalCategory {
            case .format, .spaceSeparator, .lineSeparator, .paragraphSeparator, .control: continue   // Zero-Width, Leerzeichen, Umbrüche
            default: out.append(u)
            }
        }
        return String(out)
    }
}

enum Keychain {
    private static let service = "de.thorin.mailpilot.imap"

    static func setPassword(_ password: String, for account: ClientAccount) -> Bool {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: account.id.uuidString]
        SecItemDelete(base as CFDictionary)
        var item = base
        item[kSecValueData as String] = Data(password.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func password(for account: ClientAccount) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account.id.uuidString, kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func deletePassword(for account: ClientAccount) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account.id.uuidString]
        SecItemDelete(query as CFDictionary)
    }
}

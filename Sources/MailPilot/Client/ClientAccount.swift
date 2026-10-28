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

    static let iCloudHost = "imap.mail.me.com"

    static func iCloud(email: String) -> ClientAccount {
        ClientAccount(name: "iCloud", email: email, username: email, host: iCloudHost)
    }

    var isICloud: Bool { host == Self.iCloudHost }

    /// Anmeldenamen, die nacheinander versucht werden: bei iCloud zuerst die volle Adresse, dann der Teil vor dem @.
    var loginCandidates: [String] {
        var names = [username]
        if isICloud, let local = username.split(separator: "@").first, String(local) != username { names.append(String(local)) }
        return names
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

import Contacts
import Foundation

/// Namen und VIP-Gruppen aus der Kontakte-App (nur mit ausdrücklicher Erlaubnis).
final class ContactsDirectory: @unchecked Sendable {
    static let shared = ContactsDirectory()

    private let store = CNContactStore()
    private let lock = NSLock()
    private var names: [String: String] = [:]

    var status: CNAuthorizationStatus { CNContactStore.authorizationStatus(for: .contacts) }
    var isAuthorized: Bool { status == .authorized }

    var statusText: String {
        switch status {
        case .authorized: "Zugriff erlaubt"
        case .denied: "Zugriff verweigert – in den Systemeinstellungen unter Datenschutz & Sicherheit → Kontakte erlauben"
        case .restricted: "Zugriff eingeschränkt"
        default: "Noch nicht erlaubt"
        }
    }

    func requestAccess() async -> Bool {
        (try? await store.requestAccess(for: .contacts)) ?? false
    }

    static func displayName(given: String, family: String, nickname: String, organization: String) -> String {
        let person = [given, family].filter { !$0.isEmpty }.joined(separator: " ")
        if !person.isEmpty { return person }
        return nickname.isEmpty ? organization : nickname
    }

    /// Setzt die Zuordnung E-Mail → Name (auch für Tests).
    func setNames(_ map: [String: String]) {
        lock.lock(); defer { lock.unlock() }
        names = map
    }

    func name(for email: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return names[email.lowercased()]
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return names.count
    }

    /// Liest alle Kontakte mit E-Mail-Adresse.
    func reload() throws {
        guard isAuthorized else { return }
        let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactNicknameKey, CNContactOrganizationNameKey, CNContactEmailAddressesKey] as [CNKeyDescriptor]
        var map: [String: String] = [:]
        try store.enumerateContacts(with: CNContactFetchRequest(keysToFetch: keys)) { c, _ in
            let name = Self.displayName(given: c.givenName, family: c.familyName, nickname: c.nickname, organization: c.organizationName)
            guard !name.isEmpty else { return }
            for e in c.emailAddresses { map[(e.value as String).lowercased()] = name }
        }
        setNames(map)
    }

    func groupNames() -> [String] {
        guard isAuthorized, let groups = try? store.groups(matching: nil) else { return [] }
        return groups.map(\.name).sorted()
    }

    /// Mitglieder einer Gruppe: Name und E-Mail-Adressen.
    func members(ofGroup name: String) -> [(name: String, emails: [String])] {
        guard isAuthorized, let group = (try? store.groups(matching: nil))?.first(where: { $0.name == name }),
              let predicate = Optional(CNContact.predicateForContactsInGroup(withIdentifier: group.identifier)) else { return [] }
        let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactNicknameKey, CNContactOrganizationNameKey, CNContactEmailAddressesKey] as [CNKeyDescriptor]
        let contacts = (try? store.unifiedContacts(matching: predicate, keysToFetch: keys)) ?? []
        return contacts.map { c in
            (Self.displayName(given: c.givenName, family: c.familyName, nickname: c.nickname, organization: c.organizationName),
             c.emailAddresses.map { ($0.value as String).lowercased() })
        }
    }
}

enum VIPSync {
    /// Ersetzt die aus Kontakten stammenden VIP-Einträge durch die aktuelle Gruppe; von Hand angelegte bleiben unberührt.
    static func merge(existing: [VIPEntry], members: [(name: String, emails: [String])]) -> [VIPEntry] {
        let manual = existing.filter { !$0.fromContacts }
        let known = Set(manual.map { $0.match.lowercased() })
        var out = manual
        for m in members {
            for email in m.emails where !known.contains(email) && !out.contains(where: { $0.match.lowercased() == email }) {
                out.append(VIPEntry(name: m.name, match: email, fromContacts: true))
            }
        }
        return out
    }
}

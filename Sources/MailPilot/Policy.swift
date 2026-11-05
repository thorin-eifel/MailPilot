import Foundation

/// Vorgaben der Organisation (z. B. CTW IT) für alle Rechner: Claude an/aus, Funktionen, Ordner-Präfix, Datenschutz-Ausnahmen,
/// Anbieter-Vorlagen. Was hier gesetzt ist, kann der Nutzer in den Einstellungen nicht ändern.
///
/// Quellen, in dieser Reihenfolge:
/// 1. Konfigurationsprofil (MDM, Domain `de.thorin.mailpilot`, Schlüssel `Policy` als Dictionary) – nur wenn macOS den Schlüssel als verwaltet meldet.
/// 2. Datei `/Library/Application Support/MailPilot/policy.json`, nur wenn sie root gehört und für niemand sonst beschreibbar ist.
/// Die Schlüssel sind in beiden Fällen dieselben (siehe `docs/Verwaltung.md`).
struct Policy: Codable, Equatable {
    struct ClaudePolicy: Codable, Equatable {
        var enabled: Bool?
        var model: String?
        var modelBulk: String?
        var executablePath: String?
        /// Zusätzliche Umgebungsvariablen für den Claude-Aufruf (z. B. Gateway-Adresse). Keine Geheimnisse hier ablegen.
        var environment: [String: String]?
    }

    struct Features: Codable, Equatable {
        var appleMail: Bool?
        var calendar: Bool?
        var contacts: Bool?
        var notifications: Bool?
    }

    struct Provider: Codable, Equatable {
        var name: String
        var imapHost: String
        var imapPort: Int?
        var smtpHost: String
        var smtpPort: Int?
        /// "starttls" oder "tls"
        var smtpSecurity: String?
        var hint: String?
    }

    /// Name der Organisation und Ansprechpartner – erscheinen in den Einstellungen.
    var organization: String?
    var supportContact: String?
    var claude: ClaudePolicy?
    var features: Features?
    var folderPrefix: String?
    var archiveFolder: String?
    var dryRun: Bool?
    /// Organisationsweite Datenschutz-Ausnahmen; kommen zu denen des Nutzers hinzu und sind nicht entfernbar.
    var privacyRules: [PrivacyRule]?
    var providers: [Provider]?
    /// true: nur die oben genannten Anbieter anbieten (kein „Anderes IMAP/SMTP“, keine Standardliste).
    var onlyListedProviders: Bool?
    var maxAccounts: Int?

    enum Key: String, CaseIterable {
        case claudeEnabled, claudeModel, claudeModelBulk, claudePath
        case appleMail, calendar, contacts, notifications
        case folderPrefix, archiveFolder, dryRun
        case privacyRules, providers, maxAccounts
    }

    func isLocked(_ key: Key) -> Bool {
        switch key {
        case .claudeEnabled: claude?.enabled != nil
        case .claudeModel: claude?.model != nil
        case .claudeModelBulk: claude?.modelBulk != nil
        case .claudePath: claude?.executablePath != nil
        case .appleMail: features?.appleMail != nil
        case .calendar: features?.calendar != nil
        case .contacts: features?.contacts != nil
        case .notifications: features?.notifications != nil
        case .folderPrefix: folderPrefix != nil
        case .archiveFolder: archiveFolder != nil
        case .dryRun: dryRun != nil
        case .privacyRules: !(privacyRules ?? []).isEmpty
        case .providers: !(providers ?? []).isEmpty || onlyListedProviders == true
        case .maxAccounts: maxAccounts != nil
        }
    }

    var isEmpty: Bool { Key.allCases.allSatisfy { !isLocked($0) } && organization == nil }

    /// Kurze Beschreibung der vorgegebenen Einstellungen (für die Anzeige).
    var lockedDescriptions: [String] {
        var out: [String] = []
        if let e = claude?.enabled { out.append(e ? "Claude: eingeschaltet" : "Claude: ausgeschaltet") }
        if let m = claude?.model { out.append("Claude-Modell: \(m)") }
        if let f = features {
            if let v = f.appleMail { out.append("Apple Mail: \(v ? "erlaubt" : "aus")") }
            if let v = f.calendar { out.append("Kalender und Erinnerungen: \(v ? "erlaubt" : "aus")") }
            if let v = f.contacts { out.append("Kontakte: \(v ? "erlaubt" : "aus")") }
            if let v = f.notifications { out.append("Mitteilungen: \(v ? "an" : "aus")") }
        }
        if let f = folderPrefix { out.append("Ordner-Präfix: „\(f)“") }
        if let f = archiveFolder { out.append("Archivordner: „\(f)“") }
        if let v = dryRun { out.append("Probelauf: \(v ? "an" : "aus")") }
        if let n = privacyRules?.count, n > 0 { out.append("\(n) Datenschutz-Ausnahme(n) der Organisation") }
        if let n = providers?.count, n > 0 { out.append("\(n) vorgegebene(r) Mail-Anbieter") }
        if let m = maxAccounts { out.append("Höchstens \(m) Konten") }
        return out
    }

    /// Wendet die Vorgaben auf die Einstellungen des Nutzers an. Gleiche Eingabe, gleiche Ausgabe (kann beliebig oft aufgerufen werden).
    func apply(to s: AppSettings) -> AppSettings {
        var s = s
        if let v = claude?.enabled { s.useClaude = v }
        if let v = claude?.model { s.model = v }
        if let v = claude?.modelBulk { s.modelBulk = v }
        if let v = claude?.executablePath { s.claudePath = v }
        if let v = features?.appleMail { s.useAppleMail = v }
        if let v = features?.calendar { s.useCalendar = v }
        if let v = features?.contacts { s.useContacts = v }
        if let v = features?.notifications { s.notifications = v }
        if let v = folderPrefix { s.folderPrefix = v }
        if let v = archiveFolder { s.archiveFolder = v }
        if let v = dryRun { s.dryRun = v }
        // Vorgegebene Ausnahmen stehen vorn, sind aktiv und nicht änderbar; frühere Kopien werden ersetzt.
        s.privacyRules.removeAll { $0.managed }
        let managed = (privacyRules ?? []).map { r -> PrivacyRule in var r = r; r.managed = true; r.enabled = true; return r }
        s.privacyRules = managed + s.privacyRules
        return s
    }

    var maxClientAccounts: Int { min(ClientAccount.hardLimit, max(1, maxAccounts ?? ClientAccount.hardLimit)) }
}

/// Lädt die Vorgaben einmal beim Start (und auf Wunsch neu).
enum PolicyStore {
    static let filePath = "/Library/Application Support/MailPilot/policy.json"
    nonisolated(unsafe) static private(set) var current: Policy = load()

    static func reload() { current = load() }

    static func load(defaults: UserDefaults = .standard, filePath: String = filePath, requireRootFile: Bool = true) -> Policy {
        if defaults.objectIsForced(forKey: "Policy"), let dict = defaults.dictionary(forKey: "Policy"), let p = decode(dict) { return p }
        guard trusted(file: filePath, requireRoot: requireRootFile), let data = FileManager.default.contents(atPath: filePath) else { return Policy() }
        return (try? JSONDecoder().decode(Policy.self, from: data)) ?? Policy()
    }

    static func decode(_ dict: [String: Any]) -> Policy? {
        guard JSONSerialization.isValidJSONObject(dict), let data = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
        return try? JSONDecoder().decode(Policy.self, from: data)
    }

    /// Eine Datei, die ein normaler Nutzer ändern kann, ist keine Vorgabe: sie muss root gehören und darf nur von root beschreibbar sein.
    static func trusted(file path: String, requireRoot: Bool = true) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { return false }
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0o777
        if perms & 0o022 != 0 { return false }
        if requireRoot, (attrs[.ownerAccountID] as? NSNumber)?.intValue != 0 { return false }
        return true
    }
}

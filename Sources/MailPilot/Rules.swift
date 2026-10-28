import Foundation

// MARK: - Regeln

enum RuleField: String, Codable, CaseIterable, Identifiable {
    case sender, domain, subject, body, recipient

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sender: "Absender enthält"
        case .domain: "Absender-Domain ist"
        case .subject: "Betreff enthält"
        case .body: "Text enthält"
        case .recipient: "Empfänger enthält"
        }
    }

    var symbol: String {
        switch self {
        case .sender: "person.fill"
        case .domain: "globe"
        case .subject: "text.alignleft"
        case .body: "doc.text"
        case .recipient: "arrowshape.turn.up.right.fill"
        }
    }

    var placeholder: String {
        switch self {
        case .sender: "name@firma.de oder Namensteil"
        case .domain: "firma.de"
        case .subject: "Rechnung"
        case .body: "Stichwort"
        case .recipient: "info@meinefirma.de"
        }
    }
}

struct RuleCondition: Codable, Hashable, Identifiable {
    var id = UUID()
    var field: RuleField = .sender
    var value = ""
}

/// Eigene Regel: Bedingungen → Kategorie, Ordner, Priorität, Flagge. Regeln gelten für eingehende Mails.
struct UserRule: Codable, Hashable, Identifiable {
    var id = UUID()
    var name = "Neue Regel"
    var enabled = true
    /// true = alle Bedingungen müssen zutreffen, false = eine genügt.
    var matchAll = true
    var conditions: [RuleCondition] = [RuleCondition()]
    var category: String?
    /// Zielordner relativ zum Ordner-Präfix (leer = Ordner der Kategorie).
    var folder: String?
    var priority: Priority?
    var flag: FlagColor?
    /// Mail nicht in einen Ordner verschieben bzw. zurück in den Posteingang legen.
    var keepInInbox = false
    /// Aus Korrekturen vorgeschlagen und übernommen.
    var learned = false
    /// Mails, die diese Regel trifft, ohne Claude einordnen (spart Aufrufe; braucht eine Kategorie).
    var skipClaude = false

    var hasAction: Bool {
        category != nil || !(folder ?? "").isEmpty || priority != nil || flag != nil || keepInInbox
    }
}

/// Wichtige Person oder Domain.
struct VIPEntry: Codable, Hashable, Identifiable {
    var id = UUID()
    var name = ""
    /// E-Mail-Adresse oder Domain (`firma.de` bzw. `@firma.de`).
    var match = ""
    /// Stammt aus einer Kontaktgruppe und wird beim Abgleich ersetzt.
    var fromContacts = false

    init(id: UUID = UUID(), name: String = "", match: String = "", fromContacts: Bool = false) {
        self.id = id; self.name = name; self.match = match; self.fromContacts = fromContacts
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        match = try c.decodeIfPresent(String.self, forKey: .match) ?? ""
        fromContacts = try c.decodeIfPresent(Bool.self, forKey: .fromContacts) ?? false
    }

    func matches(_ email: String) -> Bool {
        let want = match.trimmingCharacters(in: .whitespaces).lowercased()
        guard !want.isEmpty else { return false }
        let email = email.lowercased()
        if want.contains("@") && !want.hasPrefix("@") { return email == want }
        return RuleEngine.domainMatches(domain: RuleEngine.domain(of: email), want: want)
    }
}

/// Ergebnis der Regelauswertung für eine Nachricht.
struct RuleEffect: Equatable {
    var category: String?
    var folder: String?
    var priority: Priority?
    var flag: FlagColor?
    var keepInInbox = false
    var vip = false
    var decidedBy: String?
}

enum RuleEngine {
    static func domain(of email: String) -> String {
        guard let at = email.lastIndex(of: "@") else { return "" }
        return String(email[email.index(after: at)...]).lowercased()
    }

    static func domainMatches(domain: String, want: String) -> Bool {
        let want = want.hasPrefix("@") ? String(want.dropFirst()) : want
        return !want.isEmpty && (domain == want || domain.hasSuffix("." + want))
    }

    static func matches(_ c: RuleCondition, _ m: StoredMessage) -> Bool {
        let v = c.value.trimmingCharacters(in: .whitespaces).lowercased()
        guard !v.isEmpty else { return false }
        switch c.field {
        case .sender: return m.sender.lowercased().contains(v) || m.senderEmail.contains(v)
        case .domain: return domainMatches(domain: domain(of: m.senderEmail), want: v)
        case .subject: return m.subject.lowercased().contains(v)
        case .body: return m.content.lowercased().contains(v)
        case .recipient: return m.recipients.joined(separator: " ").lowercased().contains(v)
        }
    }

    static func matches(_ rule: UserRule, _ m: StoredMessage, ignoreEnabled: Bool = false) -> Bool {
        guard rule.enabled || ignoreEnabled else { return false }
        let active = rule.conditions.filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !active.isEmpty else { return false }
        let hits = active.map { matches($0, m) }
        return rule.matchAll ? !hits.contains(false) : hits.contains(true)
    }

    /// Wertet VIP-Liste und Regeln aus. Frühere Regeln haben Vorrang; VIP hebt die Priorität immer auf „hoch“.
    static func evaluate(_ m: StoredMessage, settings: AppSettings) -> RuleEffect {
        var e = RuleEffect()
        guard !m.isFromMe else { return e }

        for rule in settings.rules where matches(rule, m) && rule.hasAction {
            var used = false
            if e.category == nil, let c = rule.category, settings.category(named: c) != nil { e.category = c; used = true }
            if e.folder == nil, let f = rule.folder?.trimmingCharacters(in: .whitespaces), !f.isEmpty { e.folder = f; used = true }
            if e.priority == nil, let p = rule.priority { e.priority = p; used = true }
            if e.flag == nil, let f = rule.flag { e.flag = f; used = true }
            if rule.keepInInbox, !e.keepInInbox { e.keepInInbox = true; used = true }
            if used, e.decidedBy == nil { e.decidedBy = "Regel: \(rule.name)" }
        }

        if settings.vips.contains(where: { $0.matches(m.senderEmail) }) {
            e.vip = true
            e.priority = .high
            if e.flag == nil, settings.vipFlagEnabled { e.flag = settings.vipFlagColor }
            if e.decidedBy == nil { e.decidedBy = "VIP" }
        }
        return e
    }
}

// MARK: - Korrekturen und Lernen

struct Correction: Identifiable, Hashable {
    var id: Int64
    var date: Date
    var messageId: String
    var subject: String
    var senderEmail: String
    var fromCategory: String?
    var toCategory: String?
    var toInbox: Bool
    /// "mail" = in Apple Mail verschoben, "app" = im Dashboard geändert.
    var source: String

    var summary: String {
        let from = fromCategory ?? "–"
        return toInbox ? "\(from) → Posteingang" : "\(from) → \(toCategory ?? "–")"
    }
}

struct RuleSuggestion: Identifiable, Hashable {
    var id: Int64
    /// "sender" oder "domain"
    var kind: String
    var value: String
    var category: String?
    var keepInInbox: Bool
    var count: Int

    var title: String {
        let who = kind == "domain" ? "Mails von @\(value)" : "Mails von \(value)"
        return keepInInbox ? "\(who) im Posteingang lassen" : "\(who) → \(category ?? "–")"
    }

    var rule: UserRule {
        var r = UserRule()
        r.name = kind == "domain" ? "Domain \(value)" : "Absender \(value)"
        r.conditions = [RuleCondition(field: kind == "domain" ? .domain : .sender, value: value)]
        r.category = category
        r.keepInInbox = keepInInbox
        r.learned = true
        return r
    }
}

enum Learner {
    /// Private Mail-Anbieter: Hier sagt die Domain nichts über den Absender.
    static let freemail: Set<String> = [
        "gmail.com", "googlemail.com", "icloud.com", "me.com", "mac.com", "outlook.com", "hotmail.com", "live.com",
        "web.de", "gmx.de", "gmx.net", "gmx.at", "t-online.de", "yahoo.com", "yahoo.de", "freenet.de", "posteo.de", "proton.me",
        "protonmail.com", "aol.com", "mail.com", "bluewin.ch", "outlook.de", "online.de",
    ]

    static let senderThreshold = 2
    static let domainSenderThreshold = 3

    /// Erzeugt Regelvorschläge aus wiederholten Korrekturen. Bereits abgedeckte oder verworfene Vorschläge bleiben außen vor.
    static func refreshSuggestions(store: Store, settings: AppSettings) {
        guard settings.learnFromCorrections else { return }
        let names = Set(settings.categories.map(\.name))

        func covered(_ field: RuleField, _ value: String) -> Bool {
            settings.rules.contains { r in
                r.conditions.contains { $0.field == field && $0.value.lowercased() == value.lowercased() }
            }
        }

        for c in (try? store.senderCorrectionGroups(minCount: senderThreshold)) ?? [] {
            guard !covered(.sender, c.value), c.toInbox || c.category.map(names.contains) == true else { continue }
            try? store.upsertSuggestion(kind: "sender", value: c.value, category: c.category, keepInInbox: c.toInbox, count: c.count)
        }
        for c in (try? store.domainCorrectionGroups(minSenders: domainSenderThreshold)) ?? [] {
            guard !freemail.contains(c.value), !covered(.domain, c.value),
                  c.toInbox || c.category.map(names.contains) == true else { continue }
            try? store.upsertSuggestion(kind: "domain", value: c.value, category: c.category, keepInInbox: c.toInbox, count: c.count)
        }
    }

    /// Hinweise für Claude: bisherige Korrekturen zu Absender oder Domain.
    static func hints(for m: StoredMessage, store: Store, settings: AppSettings) -> String {
        var lines: [String] = []
        if settings.vips.contains(where: { $0.matches(m.senderEmail) }) {
            lines.append("Der Absender steht auf der VIP-Liste des Nutzers – Mails von ihm/ihr sind wichtig.")
        }
        guard settings.learnFromCorrections else { return lines.joined(separator: "\n") }
        for c in (try? store.corrections(senderEmail: m.senderEmail, domain: RuleEngine.domain(of: m.senderEmail), limit: 4)) ?? [] {
            if c.toInbox {
                lines.append("Der Nutzer hat Mails dieses Absenders aus „\(c.fromCategory ?? "–")“ zurück in den Posteingang geholt – sie sind keine \(c.fromCategory ?? "solche") Mails.")
            } else if let to = c.toCategory {
                lines.append("Der Nutzer hat Mails dieses Absenders von „\(c.fromCategory ?? "–")“ nach „\(to)“ umsortiert.")
            }
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Schutz vor Verschiebungen in nicht lesbare Ordner

/// Manche Konten (z. B. Exchange/IMAP mit Unterordnern) nehmen Mails per Skript an, zeigen den Zielordner aber leer an.
/// Dort lässt sich nicht prüfen, ob eine Mail angekommen ist – deshalb wird in solchen Konten nur markiert, nicht verschoben.
enum MoveGate {
    /// Zielordner wurde nachweislich zurückgelesen.
    case allowed
    /// Noch ungeprüft: Es wird nur eine Probe-Mail verschoben und verifiziert, erst danach der Rest.
    case canary
    /// Zielordner nicht zurücklesbar: nur markieren.
    case blocked

    static let minSample = 3

    /// Urteil aus einer Stichprobe bereits einsortierter Mails: Wie viele davon sind im Zielordner auffindbar?
    /// `nil` = zu wenig Daten, dann entscheidet die Probe-Mail.
    static func decide(sample: Int, found: Int) -> String? {
        guard sample >= minSample else { return nil }
        return found * 2 >= sample ? "ok" : "blocked"
    }

    /// Prüft anhand der Datenbank und einer lesenden Ordnerabfrage, ob die Zielordner des Kontos zurücklesbar sind.
    static func verdict(account: String, store: Store, bridge: MailBridge, settings: AppSettings) async -> String? {
        var paths = settings.categories.compactMap { settings.folderPath(for: $0) }
        if !settings.archiveFolder.isEmpty { paths.append(settings.folderPrefix + settings.archiveFolder) }
        guard let sample = try? store.movedSample(account: account, mailboxes: Array(Set(paths)),
                                                  movedBefore: Date().addingTimeInterval(-15 * 60), limit: 25),
              sample.count >= minSample else { return nil }
        let refs = Set(sample.map { MailBridge.FolderRef(account: account, path: $0.mailbox) })
        guard let listing = try? await bridge.folderContents(Array(refs)) else { return nil }
        let found = sample.filter { listing[.init(account: account, path: $0.mailbox)]?.contains($0.messageId) == true }.count
        return decide(sample: sample.count, found: found)
    }
}

extension UserRule {
    /// Tolerantes Lesen: Regeln aus älteren Versionen (ohne neuere Felder) bleiben erhalten.
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? id
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? name
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? enabled
        matchAll = try c.decodeIfPresent(Bool.self, forKey: .matchAll) ?? matchAll
        conditions = try c.decodeIfPresent([RuleCondition].self, forKey: .conditions) ?? conditions
        category = try c.decodeIfPresent(String.self, forKey: .category)
        folder = try c.decodeIfPresent(String.self, forKey: .folder)
        priority = try c.decodeIfPresent(Priority.self, forKey: .priority)
        flag = try c.decodeIfPresent(FlagColor.self, forKey: .flag)
        keepInInbox = try c.decodeIfPresent(Bool.self, forKey: .keepInInbox) ?? keepInInbox
        learned = try c.decodeIfPresent(Bool.self, forKey: .learned) ?? learned
        skipClaude = try c.decodeIfPresent(Bool.self, forKey: .skipClaude) ?? skipClaude
    }
}

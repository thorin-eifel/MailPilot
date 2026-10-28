import Foundation

struct CategoryRule: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var description: String
    /// Zielordner (ohne Präfix). Leer = im Posteingang lassen.
    var folder: String
    var flag: FlagColor?
    /// SF-Symbol-Name; leer = aus dem Namen abgeleitet.
    var icon: String?

    static let defaults: [CategoryRule] = [
        CategoryRule(name: "Handlung nötig", description: "Jemand erwartet von mir eine Antwort, Entscheidung oder Aufgabe.", folder: "", flag: .red),
        CategoryRule(name: "Termine", description: "Einladungen, Terminabsprachen, Buchungsbestätigungen.", folder: "", flag: .orange),
        CategoryRule(name: "Persönlich", description: "Private Nachrichten von echten Personen.", folder: "", flag: nil),
        CategoryRule(name: "Info", description: "Relevante Information ohne nötige Reaktion.", folder: "", flag: nil),
        CategoryRule(name: "Rechnungen", description: "Rechnungen, Zahlungen, Belege, Kontoauszüge.", folder: "Rechnungen", flag: .yellow),
        CategoryRule(name: "Bestellungen", description: "Bestell-, Versand- und Lieferbestätigungen.", folder: "Bestellungen", flag: nil),
        CategoryRule(name: "Benachrichtigungen", description: "Automatische System-, Konto- und Dienstmeldungen.", folder: "Benachrichtigungen", flag: nil),
        CategoryRule(name: "Newsletter", description: "Newsletter, Blogs, Digest-Mails.", folder: "Newsletter", flag: nil),
        CategoryRule(name: "Werbung", description: "Werbung, Angebote, Marketing.", folder: "Werbung", flag: nil),
    ]
}

/// Wohin Fristen aus Gesprächen automatisch übernommen werden.
enum DeadlineTarget: String, Codable, CaseIterable, Identifiable {
    case off, reminders, calendar, both

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: "Aus"
        case .reminders: "Erinnerungen"
        case .calendar: "Kalender"
        case .both: "Erinnerungen und Kalender"
        }
    }

    var kinds: [DeadlineKind] {
        switch self {
        case .off: []
        case .reminders: [.reminder]
        case .calendar: [.calendar]
        case .both: [.reminder, .calendar]
        }
    }
}

enum DeadlineKind: String {
    case reminder, calendar
}

struct AppSettings: Codable, Equatable {
    var pollMinutes = 5
    var lookbackDays = 3
    var maxPerCycle = 20
    var model = "sonnet"
    var claudePath = ""
    var autoMove = true
    var autoFlag = true
    var autoDrafts = true
    var dryRun = false
    var notifications = true
    var includeSent = true
    var followUpDays = 3
    var briefingHour = 8
    var folderPrefix = "Claude/"
    /// Mails ohne eigenen Kategorie-Ordner, deren Gespräch erledigt/Info ist, werden ab diesem Alter archiviert (0 = nie).
    var archiveAfterDays = 30
    var archiveFolder = "Archiv"
    var customInstructions = ""
    var categories: [CategoryRule] = CategoryRule.defaults
    /// Konten, auf denen MailPilot arbeitet. `nil` = alle Konten in Mail.
    var enabledAccounts: [String]?
    /// Eigene Regeln (Reihenfolge = Vorrang) und VIP-Liste.
    var rules: [UserRule] = []
    var vips: [VIPEntry] = []
    var vipFlagEnabled = true
    var vipFlagColor: FlagColor = .red
    var vipNotify = true
    /// Korrekturen in Mail oder im Dashboard erkennen und daraus Regeln vorschlagen.
    var learnFromCorrections = true
    /// Bei überfälligen Gesprächen („wartet auf Antwort“) automatisch einen Nachfass-Entwurf vorbereiten.
    var autoFollowUpDrafts = true
    /// Fristen automatisch in Erinnerungen und/oder Kalender eintragen.
    var deadlineTarget: DeadlineTarget = .off
    var reminderList = "MailPilot"
    var calendarID = ""
    var calendarName = ""
    /// Rechnungen aus Mails der Kategorie `invoiceCategory` samt PDF-Anhang auslesen.
    var extractInvoices = true
    var invoiceCategory = "Rechnungen"

    func isEnabled(_ account: String) -> Bool {
        enabledAccounts.map { $0.contains(account) } ?? true
    }

    func category(named name: String?) -> CategoryRule? {
        guard let name else { return nil }
        return categories.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    func folderPath(for rule: CategoryRule) -> String? {
        let folder = rule.folder.trimmingCharacters(in: .whitespaces)
        return folder.isEmpty ? nil : folderPrefix + folder
    }

    static func load(from url: URL) -> AppSettings {
        // Fehlende Felder (z. B. nach einem Update) bekommen ihre Standardwerte – siehe init(from:).
        guard let data = try? Data(contentsOf: url),
              let s = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
        return s
    }

    func save(to url: URL) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(self).write(to: url, options: .atomic)
    }
}

enum Paths {
    static let appSupport: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("MailPilot", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static var database: URL { appSupport.appendingPathComponent("mailpilot.sqlite") }
    static var settings: URL { appSupport.appendingPathComponent("settings.json") }
    static var scripts: URL {
        let dir = appSupport.appendingPathComponent("scripts", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

extension AppSettings {
    /// Tolerantes Dekodieren: Unbekannte oder fehlende Felder fallen auf den Standardwert zurück,
    /// damit neue Einstellungen die gespeicherte Konfiguration nicht verwerfen.
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func v<T: Decodable>(_ key: CodingKeys, _ current: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? current
        }
        pollMinutes = v(.pollMinutes, pollMinutes)
        lookbackDays = v(.lookbackDays, lookbackDays)
        maxPerCycle = v(.maxPerCycle, maxPerCycle)
        model = v(.model, model)
        claudePath = v(.claudePath, claudePath)
        autoMove = v(.autoMove, autoMove)
        autoFlag = v(.autoFlag, autoFlag)
        autoDrafts = v(.autoDrafts, autoDrafts)
        dryRun = v(.dryRun, dryRun)
        notifications = v(.notifications, notifications)
        includeSent = v(.includeSent, includeSent)
        followUpDays = v(.followUpDays, followUpDays)
        briefingHour = v(.briefingHour, briefingHour)
        folderPrefix = v(.folderPrefix, folderPrefix)
        archiveAfterDays = v(.archiveAfterDays, archiveAfterDays)
        archiveFolder = v(.archiveFolder, archiveFolder)
        customInstructions = v(.customInstructions, customInstructions)
        categories = v(.categories, categories)
        enabledAccounts = (try? c.decodeIfPresent([String].self, forKey: .enabledAccounts)) ?? nil
        rules = v(.rules, rules)
        vips = v(.vips, vips)
        vipFlagEnabled = v(.vipFlagEnabled, vipFlagEnabled)
        vipFlagColor = v(.vipFlagColor, vipFlagColor)
        vipNotify = v(.vipNotify, vipNotify)
        learnFromCorrections = v(.learnFromCorrections, learnFromCorrections)
        autoFollowUpDrafts = v(.autoFollowUpDrafts, autoFollowUpDrafts)
        deadlineTarget = v(.deadlineTarget, deadlineTarget)
        reminderList = v(.reminderList, reminderList)
        calendarID = v(.calendarID, calendarID)
        calendarName = v(.calendarName, calendarName)
        extractInvoices = v(.extractInvoices, extractInvoices)
        invoiceCategory = v(.invoiceCategory, invoiceCategory)
    }
}

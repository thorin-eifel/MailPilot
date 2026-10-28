import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var engine: Engine
    @ViewState private var testResult: String?
    @ViewState private var testing = false
    @ViewState private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            AccountsSection()

            Section(header: SectionHeader(title: "Automatik", symbol: "wand.and.stars")) {
                Toggle("Mails automatisch in Ordner verschieben", isOn: $engine.settings.autoMove)
                Toggle("Mails automatisch markieren (Flagge)", isOn: $engine.settings.autoFlag)
                Toggle("Antwortentwürfe automatisch vorbereiten", isOn: $engine.settings.autoDrafts)
                Toggle("Nachfass-Entwürfe bei überfälligen Gesprächen vorbereiten", isOn: $engine.settings.autoFollowUpDrafts)
                Toggle("Rechnungen aus Mails und PDF-Anhängen auslesen", isOn: $engine.settings.extractInvoices)
                if engine.settings.extractInvoices {
                    Picker("Kategorie der Rechnungen", selection: $engine.settings.invoiceCategory) {
                        ForEach(engine.settings.categories.map(\.name), id: \.self) { Text($0).tag($0) }
                    }
                }
                Toggle("Probelauf – nur protokollieren, nichts in Mail ändern", isOn: $engine.settings.dryRun)
                Toggle("Gesendete Mails einbeziehen (für „Warte auf Antwort“)", isOn: $engine.settings.includeSent)
                Toggle("Mitteilungen (wichtige Mails, Follow-ups, Briefing)", isOn: $engine.settings.notifications)
                TextField("Ordner-Präfix", text: $engine.settings.folderPrefix)
                Stepper(engine.settings.archiveAfterDays == 0 ? "Erledigte Mails nicht archivieren" : "Erledigte Mails ohne Kategorie-Ordner nach \(engine.settings.archiveAfterDays) Tagen archivieren",
                        value: $engine.settings.archiveAfterDays, in: 0...365, step: 5)
                TextField("Archivordner", text: $engine.settings.archiveFolder)
                Text("Ordner werden im jeweiligen Konto angelegt, z. B. „\(engine.settings.folderPrefix)Rechnungen“. Beim ersten Start wird der gesamte Posteingang katalogisiert und einsortiert; danach läuft der Zeitplan.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section(header: SectionHeader(title: "Zeitplan", symbol: "clock.fill")) {
                Stepper("Alle \(engine.settings.pollMinutes) Minuten prüfen", value: $engine.settings.pollMinutes, in: 1...120)
                Stepper("Zeitraum: letzte \(engine.settings.lookbackDays) Tage", value: $engine.settings.lookbackDays, in: 1...30)
                Stepper("Max. \(engine.settings.maxPerCycle) Mails pro Durchlauf", value: $engine.settings.maxPerCycle, in: 5...100, step: 5)
                Stepper("Follow-up nach \(engine.settings.followUpDays) Tagen ohne Antwort", value: $engine.settings.followUpDays, in: 1...30)
                Stepper("Tägliches Briefing ab \(engine.settings.briefingHour) Uhr", value: $engine.settings.briefingHour, in: 0...23)
                Toggle("Beim Anmelden starten", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            testResult = "Anmeldeobjekt: \(error.localizedDescription)"
                        }
                    }
            }

            DeadlinesSection()

            Section(header: SectionHeader(title: "Claude", symbol: "sparkles")) {
                Picker("Modell", selection: $engine.settings.model) {
                    Text("Sonnet (empfohlen)").tag("sonnet")
                    Text("Haiku (schnell)").tag("haiku")
                    Text("Opus (gründlich)").tag("opus")
                }
                TextField("Pfad zur claude CLI (leer = automatisch)", text: $engine.settings.claudePath)
                HStack {
                    Button("Verbindung testen") {
                        testing = true
                        Task {
                            testResult = await engine.testClaude()
                            testing = false
                        }
                    }
                    if testing { ProgressView().controlSize(.small) }
                }
                if let testResult { Text(testResult).font(.caption).textSelection(.enabled) }
                VStack(alignment: .leading) {
                    Text("Eigene Anweisungen (Tonalität, Signatur, Wichtige Personen …)")
                    TextEditor(text: $engine.settings.customInstructions)
                        .frame(minHeight: 80)
                        .font(.body)
                }
            }

            Section(header: SectionHeader(title: "Kategorien", symbol: "tag.fill")) {
                ForEach($engine.settings.categories) { $rule in
                    CategoryEditor(rule: $rule, prefix: engine.settings.folderPrefix) {
                        engine.settings.categories.removeAll { $0.id == rule.id }
                    }
                }
                HStack {
                    Button("Kategorie hinzufügen") {
                        engine.settings.categories.append(CategoryRule(name: "Neue Kategorie", description: "", folder: "", flag: nil))
                    }
                    Spacer()
                    Button("Standard wiederherstellen") { engine.settings.categories = CategoryRule.defaults }
                }
            }

            Section(header: SectionHeader(title: "Daten", symbol: "externaldrive.fill")) {
                LabeledContent("Speicherort", value: Paths.appSupport.path)
                Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([Paths.database]) }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(CTW.bg)
        .tint(CTW.accent)
        .navigationTitle("Einstellungen")
    }
}

struct CategoryEditor: View {
    @Binding var rule: CategoryRule
    let prefix: String
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Menu {
                    ForEach(CategoryRule.symbolChoices, id: \.self) { sym in
                        Button { rule.icon = sym } label: { Label(sym, systemImage: sym) }
                    }
                    Divider()
                    Button("Automatisch") { rule.icon = nil }
                } label: {
                    IconTile(symbol: rule.symbolName, color: CTW.accent, size: 28)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Symbol wählen")
                TextField("Name", text: $rule.name).fontWeight(.semibold)
                Picker("Flagge", selection: $rule.flag) {
                    Text("keine").tag(FlagColor?.none)
                    ForEach(FlagColor.allCases) { c in Text(c.label).tag(FlagColor?.some(c)) }
                }
                .frame(width: 150)
                Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
            }
            TextField("Beschreibung für Claude", text: $rule.description)
            TextField("Zielordner (leer = im Posteingang lassen)", text: $rule.folder)
            if !rule.folder.isEmpty {
                Text("→ \(prefix)\(rule.folder)").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

/// Auswahl der Mail-Konten, auf denen MailPilot arbeiten darf.
struct AccountsSection: View {
    @EnvironmentObject var engine: Engine
    @ViewState private var refreshing = false

    var body: some View {
        Section {
            if engine.accounts.isEmpty {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Lese Konten aus Apple Mail …").foregroundStyle(.secondary)
                }
            }
            ForEach(engine.accounts) { account in
                Toggle(isOn: Binding(
                    get: { engine.settings.isEnabled(account.name) },
                    set: { engine.setAccount(account.name, enabled: $0) }
                )) {
                    HStack(alignment: .top, spacing: 10) {
                    IconTile(symbol: account.symbol, color: engine.settings.isEnabled(account.name) ? CTW.accent : CTW.grey500, size: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.name).fontWeight(.semibold).foregroundStyle(CTW.ink)
                        Text(account.emails.joined(separator: ", "))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        HStack(spacing: 6) {
                            Text("\(account.inboxCount) Mails im Posteingang").font(.caption).foregroundStyle(.secondary)
                            if engine.settings.isEnabled(account.name) {
                                if engine.isScanned(account.name) {
                                    Badge(text: "Erstscan erledigt", color: CTW.teal700, symbol: "checkmark")
                                } else {
                                    Badge(text: "Erstscan ausstehend", color: CTW.action, symbol: "clock")
                                }
                                MoveStatusBadge(account: account.name)
                            }
                        }
                    }
                    }
                }
                .toggleStyle(.switch)
            }
            HStack {
                Button("Alle") { engine.settings.enabledAccounts = engine.accounts.map(\.name) }
                    .buttonStyle(.ctwSecondary)
                Button("Keine") { engine.settings.enabledAccounts = [] }
                    .buttonStyle(.ctwSecondary)
                Spacer()
                if refreshing { ProgressView().controlSize(.small) }
                Button {
                    refreshing = true
                    Task {
                        await engine.refreshAccounts()
                        refreshing = false
                    }
                } label: {
                    Label("Konten neu laden", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.ctwSecondary)
            }
        } header: {
            SectionHeader(title: "Konten", symbol: "person.2.fill")
        } footer: {
            Text("MailPilot liest, sortiert und verfolgt nur Mails der aktivierten Konten. Ein neu aktiviertes Konto wird zuerst komplett gescannt und einsortiert, danach läuft der Zeitplan weiter. Deaktivierte Konten bleiben unverändert. Nach jedem Verschieben prüft MailPilot, ob die Mail im Zielordner angekommen ist; Konten, deren Zielordner sich nicht zurücklesen lassen, werden nur markiert.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .task { if engine.accounts.isEmpty { await engine.refreshAccounts() } }
    }
}

/// Abschnittsüberschrift mit Symbol im CTW-Stil.
struct SectionHeader: View {
    let title: String
    let symbol: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).foregroundStyle(CTW.accent)
            Text(title.uppercased()).tracking(0.8)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(CTW.muted)
    }
}

/// Zeigt, ob MailPilot in einem Konto verschieben darf, und erlaubt eine erneute Prüfung.
struct MoveStatusBadge: View {
    @EnvironmentObject var engine: Engine
    let account: String
    @ViewState private var checking = false

    var body: some View {
        HStack(spacing: 6) {
            switch engine.moveStatus[account] {
            case "ok":
                Badge(text: "Verschieben geprüft", color: CTW.teal700, symbol: "checkmark.shield.fill")
            case "blocked":
                Badge(text: "Nur markieren – Ordner nicht lesbar", color: CTW.action, symbol: "exclamationmark.shield.fill")
                Button {
                    checking = true
                    Task {
                        await engine.recheckMoveGate(account)
                        checking = false
                    }
                } label: {
                    Label("Erneut prüfen", systemImage: "arrow.clockwise").font(.caption)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(CTW.accent)
                .disabled(checking)
            default:
                Badge(text: "Verschieben ungeprüft", color: CTW.grey500, symbol: "questionmark.circle")
            }
        }
        .help(helpText)
    }

    private var helpText: String {
        switch engine.moveStatus[account] {
        case "ok": "Verschobene Mails wurden im Zielordner wiedergefunden."
        case "blocked": "Verschobene Mails lassen sich im Zielordner nicht zurücklesen. In diesem Konto wird nur markiert, nicht verschoben. Nach einer Änderung am Konto oder an den Ordnern „Erneut prüfen“."
        default: "Die erste Verschiebung dient als Probe: Wird die Mail im Zielordner gefunden, wird das Konto freigegeben."
        }
    }
}

/// Fristen automatisch in Erinnerungen und/oder Kalender übernehmen.
struct DeadlinesSection: View {
    @EnvironmentObject var engine: Engine

    private var listOptions: [String] {
        var names = engine.reminderLists
        for extra in [engine.settings.reminderList, "MailPilot"] where !extra.isEmpty && !names.contains(extra) { names.append(extra) }
        return names
    }

    /// Kalender können gleich heißen – dann nummerieren.
    private func label(_ c: CalendarInfo) -> String {
        let same = engine.calendars.filter { $0.name == c.name }
        guard same.count > 1, let i = same.firstIndex(of: c) else { return c.name }
        return "\(c.name) (\(i + 1))"
    }

    var body: some View {
        Section {
            Picker("Fristen übernehmen in", selection: $engine.settings.deadlineTarget) {
                ForEach(DeadlineTarget.allCases) { Text($0.label).tag($0) }
            }
            if engine.settings.deadlineTarget == .reminders || engine.settings.deadlineTarget == .both {
                Picker("Erinnerungsliste", selection: $engine.settings.reminderList) {
                    ForEach(listOptions, id: \.self) { Text($0).tag($0) }
                }
            }
            if engine.settings.deadlineTarget == .calendar || engine.settings.deadlineTarget == .both {
                Picker("Kalender", selection: Binding(
                    get: { engine.settings.calendarID },
                    set: { id in
                        engine.settings.calendarID = id
                        engine.settings.calendarName = engine.calendars.first { $0.id == id }?.name ?? ""
                    }
                )) {
                    Text("Bitte wählen").tag("")
                    ForEach(engine.calendars) { Text(label($0)).tag($0.id) }
                }
                if engine.settings.calendarID.isEmpty {
                    Label("Ohne Kalenderauswahl werden keine Termine angelegt.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(CTW.action)
                }
            }
        } header: {
            SectionHeader(title: "Fristen", symbol: "calendar.badge.clock")
        } footer: {
            Text("Hat ein offenes Gespräch eine Frist (von Claude erkannt oder von dir gesetzt), wird sie automatisch als Erinnerung (9 Uhr am Fristtag) bzw. ganztägiger Termin eingetragen – ohne Werbung und Newsletter, jede Frist nur einmal. Beim ersten Zugriff fragt macOS nach der Berechtigung für Erinnerungen bzw. Kalender.")
                .font(.caption).foregroundStyle(CTW.muted)
        }
        .task { await engine.loadExportTargets() }
    }
}

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

            Section("Automatik") {
                Toggle("Mails automatisch in Ordner verschieben", isOn: $engine.settings.autoMove)
                Toggle("Mails automatisch markieren (Flagge)", isOn: $engine.settings.autoFlag)
                Toggle("Antwortentwürfe automatisch vorbereiten", isOn: $engine.settings.autoDrafts)
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

            Section("Zeitplan") {
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

            Section("Claude") {
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

            Section("Kategorien") {
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

            Section("Daten") {
                LabeledContent("Speicherort", value: Paths.appSupport.path)
                Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([Paths.database]) }
            }
        }
        .formStyle(.grouped)
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
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.name).fontWeight(.medium)
                        Text(account.emails.joined(separator: ", "))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        HStack(spacing: 6) {
                            Text("\(account.inboxCount) Mails im Posteingang").font(.caption).foregroundStyle(.secondary)
                            if engine.settings.isEnabled(account.name) {
                                if engine.isScanned(account.name) {
                                    Badge(text: "Erstscan erledigt", color: .green)
                                } else {
                                    Badge(text: "Erstscan ausstehend", color: .orange)
                                }
                            }
                        }
                    }
                }
                .toggleStyle(.switch)
            }
            HStack {
                Button("Alle") { engine.settings.enabledAccounts = engine.accounts.map(\.name) }
                Button("Keine") { engine.settings.enabledAccounts = [] }
                Spacer()
                if refreshing { ProgressView().controlSize(.small) }
                Button("Konten neu laden") {
                    refreshing = true
                    Task {
                        await engine.refreshAccounts()
                        refreshing = false
                    }
                }
            }
        } header: {
            Text("Konten")
        } footer: {
            Text("MailPilot liest, sortiert und verfolgt nur Mails der aktivierten Konten. Ein neu aktiviertes Konto wird zuerst komplett gescannt und einsortiert, danach läuft der Zeitplan weiter. Deaktivierte Konten bleiben unverändert.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .task { if engine.accounts.isEmpty { await engine.refreshAccounts() } }
    }
}

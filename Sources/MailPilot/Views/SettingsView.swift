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
                Stepper("Ältere Mails: \(engine.settings.batchSize) pro Claude-Aufruf", value: $engine.settings.batchSize, in: 1...25)
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

            PrivacySection()

            StyleSection()

            ContactsSection()

            AvailabilitySection()

            Section(header: SectionHeader(title: "Claude", symbol: "sparkles")) {
                Picker("Modell", selection: $engine.settings.model) {
                    Text("Sonnet (empfohlen)").tag("sonnet")
                    Text("Haiku (schnell)").tag("haiku")
                    Text("Opus (gründlich)").tag("opus")
                }
                Picker("Modell für ältere Mails (Massenanalyse)", selection: $engine.settings.modelBulk) {
                    Text("Haiku (günstig, empfohlen)").tag("haiku")
                    Text("Sonnet").tag("sonnet")
                    Text("Wie oben").tag("")
                }
                Toggle("Automatische Mails ohne Claude einordnen (Header, bekannte Absender)", isOn: $engine.settings.prefilterEnabled)
                Stepper(engine.settings.initialScanDays == 0 ? "Erstscan: gesamter Posteingang" : "Erstscan: nur die letzten \(engine.settings.initialScanDays) Tage",
                        value: $engine.settings.initialScanDays, in: 0...3650, step: 30)
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

            DataSection()
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
            Toggle("Apple Mail verwenden", isOn: $engine.settings.useAppleMail)
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
            Text("MailPilot liest, sortiert und verfolgt nur Mails der aktivierten Konten. Ein neu aktiviertes Konto wird zuerst komplett gescannt und einsortiert, danach läuft der Zeitplan weiter. Deaktivierte Konten bleiben unverändert. Konten mit dem Zusatz „(IMAP)“ liest MailPilot direkt vom Server (Bereich „Postfach“). Aktiviere dasselbe Postfach nicht doppelt, also nicht gleichzeitig über Apple Mail und als „(IMAP)“-Konto. Ohne „Apple Mail verwenden“ spricht MailPilot Apple Mail nie an. Nach jedem Verschieben prüft MailPilot, ob die Mail im Zielordner angekommen ist; Konten, deren Zielordner sich nicht zurücklesen lassen, werden nur markiert.")
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
    @ViewState private var confirmProbe = false

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
                Badge(text: engine.settings.probeMoveAccounts.contains(account) ? "Probe-Verschiebung erlaubt" : "Verschieben aus – ungeprüft",
                      color: CTW.grey500, symbol: "questionmark.circle")
                if !engine.settings.probeMoveAccounts.contains(account) {
                    Button { confirmProbe = true } label: { Label("Verschieben testen …", systemImage: "testtube.2").font(.caption) }
                        .buttonStyle(.borderless)
                        .foregroundStyle(CTW.accent)
                }
            }
        }
        .help(helpText)
        .confirmationDialog("Verschieben in „\(account)“ testen?", isPresented: $confirmProbe, titleVisibility: .visible) {
            Button("Eine Mail probeweise verschieben", role: .destructive) { engine.settings.probeMoveAccounts.append(account) }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("MailPilot verschiebt dann eine einzelne Mail in einen Ordner „Claude/…“ und prüft, ob sie dort wieder auftaucht. Bei manchen Konten – vor allem Exchange – kann diese Mail danach in Mail nicht mehr sichtbar sein (sie liegt dann nur auf dem Server). Teste das lieber zuerst mit einem Konto, in dem das nicht weh tut.")
        }
    }

    private var helpText: String {
        switch engine.moveStatus[account] {
        case "ok": "Verschobene Mails wurden im Zielordner wiedergefunden."
        case "blocked": "Verschobene Mails lassen sich im Zielordner nicht zurücklesen. In diesem Konto wird nur markiert, nicht verschoben. Nach einer Änderung am Konto oder an den Ordnern „Erneut prüfen“."
        default: "In diesem Konto wird nicht verschoben, nur markiert. Mit „Verschieben testen“ erlaubst du eine einzelne Probe-Verschiebung."
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
            Group {
                Picker("Kalender für Fristen und Einladungen", selection: Binding(
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
                Toggle("Einladungen aus Mails automatisch eintragen", isOn: $engine.settings.autoAddInvites)
                    .disabled(engine.settings.calendarID.isEmpty)
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

/// Ausnahmen: Absender, Domains oder Stichworte, deren Inhalt nie an Claude gehen soll.
struct PrivacySection: View {
    @EnvironmentObject var engine: Engine
    @ViewState private var preview: Engine.PrivacyPreview?
    @ViewState private var confirm = false

    var body: some View {
        Section {
            if engine.settings.privacyRules.isEmpty {
                Label("Noch keine Ausnahmen. Beispiel: Domain „kanzlei-mueller.de“ oder Betreff enthält „Gesundheit“.", systemImage: "lock.shield")
                    .font(.callout).foregroundStyle(CTW.muted)
            }
            ForEach($engine.settings.privacyRules) { $rule in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        Toggle("Aktiv", isOn: $rule.enabled).labelsHidden().toggleStyle(.switch)
                        TextField("Name", text: $rule.name).textFieldStyle(.plain).font(.system(size: 14, weight: .semibold))
                        Spacer()
                        Button(role: .destructive) { engine.settings.privacyRules.removeAll { $0.id == rule.id } } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Ausnahme löschen")
                    }
                    ConditionsEditor(conditions: $rule.conditions, matchAll: $rule.matchAll)
                    Toggle("Mailtext nicht speichern (empfohlen)", isOn: Binding(get: { !rule.keepBody }, set: { rule.keepBody = !$0 }))
                        .toggleStyle(.switch)
                }
                .padding(12)
                .background(CTW.surfaceSoft.opacity(rule.enabled ? 1 : 0.5), in: RoundedRectangle(cornerRadius: CTW.radius))
                .overlay(RoundedRectangle(cornerRadius: CTW.radius).strokeBorder(CTW.lineSoft))
            }
            HStack {
                Button { engine.settings.privacyRules.append(PrivacyRule()) } label: { Label("Ausnahme hinzufügen", systemImage: "plus") }
                    .buttonStyle(.ctwSecondary)
                Spacer()
                Button {
                    preview = engine.privacyPreview()
                    confirm = true
                } label: { Label("Gespeicherte Mails prüfen …", systemImage: "trash.slash") }
                    .buttonStyle(.ctwSecondary)
                    .disabled(engine.settings.privacyRules.isEmpty)
            }
        } header: {
            SectionHeader(title: "Datenschutz", symbol: "lock.shield.fill")
        } footer: {
            Text("Auf diese Mails (bei gesendeten Mails: auf deren Empfänger) und auf alle Gespräche, die sie enthalten, hat Claude nie Zugriff: keine Analyse, kein Entwurf, kein Briefing, keine Rechnungsauslesung, weder Mailtext noch Betreff oder Absender. MailPilot sortiert sie nur mit deinen eigenen Regeln. Die Claude-CLI speichert keine Sitzungen.")
                .font(.caption).foregroundStyle(CTW.muted)
        }
        .confirmationDialog("Gespeicherte Mails bereinigen?", isPresented: $confirm, titleVisibility: .visible) {
            if let p = preview, !p.messages.isEmpty {
                Button("\(p.messages.count) Mails bereinigen", role: .destructive) { engine.applyPrivacyRetroactively() }
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            let n = preview?.messages.count ?? 0
            Text(n == 0 ? "Auf keine bereits gespeicherte Mail trifft eine Ausnahme zu."
                 : "\(n) gespeicherte Mails in \(preview?.threadKeys.count ?? 0) Gesprächen: Mailtext und Zusammenfassungen werden von diesem Rechner gelöscht. Schon an Claude gesendete Inhalte lassen sich nicht zurückholen; die Mails selbst in Apple Mail bleiben unverändert.")
        }
    }
}

/// Bedingungen (wie bei Regeln) bearbeiten.
struct ConditionsEditor: View {
    @Binding var conditions: [RuleCondition]
    @Binding var matchAll: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Eyebrow(text: "Wenn")
                Picker("", selection: $matchAll) {
                    Text("alle Bedingungen zutreffen").tag(true)
                    Text("mindestens eine zutrifft").tag(false)
                }
                .labelsHidden()
                .fixedSize()
            }
            ForEach($conditions) { $c in
                HStack(spacing: 8) {
                    Picker("", selection: $c.field) {
                        ForEach(RuleField.allCases) { Label($0.label, systemImage: $0.symbol).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 200)
                    TextField(c.field.placeholder, text: $c.value).textFieldStyle(.roundedBorder)
                    Button { conditions.removeAll { $0.id == c.id } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .disabled(conditions.count <= 1)
                        .accessibilityLabel("Bedingung entfernen")
                }
            }
            Button { conditions.append(RuleCondition()) } label: { Label("Bedingung", systemImage: "plus") }
                .buttonStyle(.borderless).foregroundStyle(CTW.accent)
        }
    }
}

/// Antwortstil: aus den eigenen gesendeten Mails lernen.
struct StyleSection: View {
    @EnvironmentObject var engine: Engine
    @ViewState private var profile = ""
    @ViewState private var loaded = false

    var body: some View {
        Section {
            Toggle("Entwürfe in meinem Stil schreiben", isOn: $engine.settings.useStyleProfile)
            HStack(spacing: 10) {
                Text(engine.styleInfo).font(.callout).foregroundStyle(CTW.muted)
                Spacer()
                if engine.styleBusy { ProgressView().controlSize(.small) }
                Button { Task { await engine.loadSentHistory() } } label: { Label("Sendeverlauf einlesen (180 Tage)", systemImage: "tray.and.arrow.down") }
                    .buttonStyle(.ctwSecondary)
                    .disabled(engine.styleBusy)
                Button {
                    Task { await engine.learnStyle(manual: true); profile = engine.styleProfile }
                } label: { Label(engine.styleProfile.isEmpty ? "Stil lernen" : "Neu lernen", systemImage: "wand.and.stars") }
                    .buttonStyle(.ctwPrimary)
                    .disabled(engine.styleBusy)
            }
            if !engine.styleProfile.isEmpty || !profile.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Stilleitfaden (frei bearbeitbar)").font(.caption).foregroundStyle(CTW.muted)
                    TextEditor(text: $profile)
                        .frame(minHeight: 160)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .background(CTW.surfaceSoft, in: RoundedRectangle(cornerRadius: CTW.radius))
                        .overlay(RoundedRectangle(cornerRadius: CTW.radius).strokeBorder(CTW.line))
                        .onChange(of: profile) { _, new in if loaded { engine.setStyleProfile(new) } }
                }
            }
        } header: {
            SectionHeader(title: "Antwortstil", symbol: "signature")
        } footer: {
            Text("Zum Lernen schickt MailPilot bis zu 40 deiner gesendeten Mails (ohne zitierte Verläufe, ohne Mails an Empfänger mit Datenschutz-Ausnahme) an Claude und speichert nur den daraus abgeleiteten Leitfaden. Bei jedem Entwurf kommen der Leitfaden und bis zu zwei frühere Mails an dieselbe Person als Beispiel mit. Du kannst den Leitfaden jederzeit von Hand ändern.")
                .font(.caption).foregroundStyle(CTW.muted)
        }
        .onAppear { profile = engine.styleProfile; DispatchQueue.main.async { loaded = true } }
    }
}

/// Sicherung, Wiederherstellung und Export der lokalen Daten.
struct DataSection: View {
    @EnvironmentObject var engine: Engine
    @ViewState private var includeBodies = false
    @ViewState private var restoreURL: URL?
    @ViewState private var restoreMessage: String?
    @ViewState private var confirmRestore = false
    @ViewState private var confirmImport = false
    @ViewState private var importURL: URL?

    var body: some View {
        Section {
            LabeledContent("Speicherort", value: Paths.appSupport.path)
            LabeledContent("Datenbank", value: engine.databaseSizeText)
            Toggle("Täglich automatisch sichern", isOn: $engine.settings.autoBackup)
            if engine.settings.autoBackup {
                Stepper("Letzte \(engine.settings.backupKeep) Sicherungen behalten", value: $engine.settings.backupKeep, in: 1...60)
            }
            HStack(spacing: 8) {
                Text(engine.lastBackupText).font(.caption).foregroundStyle(CTW.muted)
                Spacer()
                Button { engine.backupNow() } label: { Label("Jetzt sichern", systemImage: "externaldrive.badge.plus") }.buttonStyle(.ctwSecondary)
                Button { saveBackupAs() } label: { Label("Sichern unter …", systemImage: "square.and.arrow.down") }.buttonStyle(.ctwSecondary)
                Button { NSWorkspace.shared.open(Backups.folder) } label: { Label("Ordner", systemImage: "folder") }.buttonStyle(.ctwSecondary)
            }
            HStack {
                Text("Aus einer Sicherung wiederherstellen").foregroundStyle(CTW.ink)
                Spacer()
                Button { pickRestore() } label: { Label("Wiederherstellen …", systemImage: "arrow.counterclockwise") }.buttonStyle(.ctwSecondary)
            }
            if let restoreMessage { Label(restoreMessage, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(CTW.action) }
            Divider().overlay(CTW.lineSoft)
            HStack(spacing: 8) {
                Toggle("Mailtexte in den Export aufnehmen", isOn: $includeBodies).toggleStyle(.switch)
                Spacer()
                Button { exportJSON() } label: { Label("Daten als JSON …", systemImage: "curlybraces") }.buttonStyle(.ctwSecondary)
                Button { exportThreadsCSV() } label: { Label("Gespräche als CSV …", systemImage: "tablecells") }.buttonStyle(.ctwSecondary)
            }
            HStack(spacing: 8) {
                Text("Regeln, Kategorien, VIPs und Ausnahmen übertragen").foregroundStyle(CTW.ink)
                Spacer()
                Button { exportSettings() } label: { Label("Einstellungen exportieren …", systemImage: "square.and.arrow.up") }.buttonStyle(.ctwSecondary)
                Button { pickSettings() } label: { Label("Importieren …", systemImage: "square.and.arrow.down.on.square") }.buttonStyle(.ctwSecondary)
            }
        } header: {
            SectionHeader(title: "Daten & Sicherung", symbol: "externaldrive.fill")
        } footer: {
            Text("Alle Daten liegen nur auf diesem Rechner. Sicherungen enthalten auch die gespeicherten Mailtexte und sind nur für dich lesbar; bewahre sie entsprechend auf. Der Export enthält standardmäßig keine Mailtexte, und vertrauliche Mails nie.")
                .font(.caption).foregroundStyle(CTW.muted)
        }
        .confirmationDialog("Sicherung wiederherstellen?", isPresented: $confirmRestore, titleVisibility: .visible) {
            Button("Wiederherstellen und MailPilot beenden", role: .destructive) {
                if let url = restoreURL {
                    restoreMessage = engine.restoreBackup(from: url)
                    if restoreMessage == nil { NSApp.terminate(nil) }
                }
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("MailPilot beendet sich jetzt. Beim nächsten Start ersetzt die Sicherung die aktuelle Datenbank; der bisherige Stand bleibt im Sicherungsordner als „vor-wiederherstellung-…“ erhalten.")
        }
        .confirmationDialog("Einstellungen ersetzen?", isPresented: $confirmImport, titleVisibility: .visible) {
            Button("Importieren", role: .destructive) { if let url = importURL { _ = engine.importSettings(from: url) } }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Alle aktuellen Einstellungen, Regeln, VIPs und Ausnahmen werden durch den Inhalt der Datei ersetzt.")
        }
    }

    private func saveBackupAs() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = Backups.fileName()
        panel.message = "Sicherung der MailPilot-Datenbank speichern"
        if panel.runModal() == .OK, let url = panel.url { engine.backupNow(to: url) }
    }

    private func pickRestore() {
        let panel = NSOpenPanel()
        panel.directoryURL = Backups.folder
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Sicherung auswählen (.sqlite)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let problem = Backups.validate(url) { restoreMessage = problem; return }
        restoreMessage = nil
        restoreURL = url
        confirmRestore = true
    }

    private func exportJSON() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "MailPilot-Export-\(Deadlines.format(Date())).json"
        if panel.runModal() == .OK, let url = panel.url { engine.exportJSON(to: url, includeBodies: includeBodies) }
    }

    private func exportThreadsCSV() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Gespraeche-\(Deadlines.format(Date())).csv"
        if panel.runModal() == .OK, let url = panel.url { engine.exportThreadsCSV(to: url) }
    }

    private func exportSettings() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "MailPilot-Einstellungen.json"
        if panel.runModal() == .OK, let url = panel.url { engine.exportSettings(to: url) }
    }

    private func pickSettings() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importURL = url
        confirmImport = true
    }
}

/// Kontakte: Namen anzeigen und VIP-Liste aus einer Gruppe füllen.
struct ContactsSection: View {
    @EnvironmentObject var engine: Engine
    @ViewState private var groups: [String] = []

    var body: some View {
        Section {
            HStack {
                Label(ContactsDirectory.shared.statusText, systemImage: ContactsDirectory.shared.isAuthorized ? "checkmark.shield.fill" : "person.crop.circle.badge.questionmark")
                    .foregroundStyle(ContactsDirectory.shared.isAuthorized ? CTW.teal700 : CTW.muted)
                Spacer()
                if !ContactsDirectory.shared.isAuthorized {
                    Button { Task { await engine.requestContactsAccess(); groups = ContactsDirectory.shared.groupNames() } } label: {
                        Label("Zugriff erlauben …", systemImage: "person.crop.circle.badge.checkmark")
                    }
                    .buttonStyle(.ctwPrimary)
                } else {
                    Button { Task { await engine.syncContacts(); groups = ContactsDirectory.shared.groupNames() } } label: {
                        Label("Jetzt abgleichen", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(.ctwSecondary)
                }
            }
            if ContactsDirectory.shared.isAuthorized {
                Toggle("Namen aus Kontakten verwenden, wenn die Mail keinen Namen enthält", isOn: $engine.settings.useContactNames)
                Picker("VIP-Liste aus Kontaktgruppe", selection: $engine.settings.vipContactGroup) {
                    Text("Aus").tag("")
                    ForEach(groups, id: \.self) { Text($0).tag($0) }
                }
                .onChange(of: engine.settings.vipContactGroup) { _, _ in Task { await engine.syncContacts() } }
                Text("\(ContactsDirectory.shared.count) Kontakte mit E-Mail-Adresse geladen.").font(.caption).foregroundStyle(CTW.muted)
            }
        } header: {
            SectionHeader(title: "Kontakte", symbol: "person.crop.rectangle.stack")
        } footer: {
            Text("MailPilot liest Namen und E-Mail-Adressen nur lokal; an Claude gehen sie nicht. Mitglieder der gewählten Gruppe stehen automatisch auf der VIP-Liste (in „Regeln & VIP“ mit dem Vermerk „Kontakte“); von Hand eingetragene VIPs bleiben unberührt.")
                .font(.caption).foregroundStyle(CTW.muted)
        }
        .onAppear { groups = ContactsDirectory.shared.groupNames() }
    }
}

/// Freie Zeiten aus dem Kalender für Antwortentwürfe.
struct AvailabilitySection: View {
    @EnvironmentObject var engine: Engine
    @ViewState private var calendars: [CalendarAvailability.Info] = []

    private var preview: [String] {
        engine.freeSlotTexts(for: [], force: true)
    }

    var body: some View {
        Section {
            HStack {
                Label(CalendarAvailability.shared.statusText, systemImage: CalendarAvailability.shared.isAuthorized ? "checkmark.shield.fill" : "calendar.badge.exclamationmark")
                    .foregroundStyle(CalendarAvailability.shared.isAuthorized ? CTW.teal700 : CTW.muted)
                Spacer()
                if !CalendarAvailability.shared.isAuthorized {
                    Button { Task { await engine.requestCalendarAccess(); calendars = CalendarAvailability.shared.calendars() } } label: {
                        Label("Zugriff erlauben …", systemImage: "calendar.badge.checkmark")
                    }
                    .buttonStyle(.ctwPrimary)
                }
            }
            Toggle("Freie Zeiten in Antwortentwürfen vorschlagen", isOn: $engine.settings.useFreeSlots)
            if CalendarAvailability.shared.isAuthorized {
                Stepper("Arbeitszeit ab \(engine.settings.workStartHour) Uhr", value: $engine.settings.workStartHour, in: 5...14)
                Stepper("Arbeitszeit bis \(engine.settings.workEndHour) Uhr", value: $engine.settings.workEndHour, in: 12...22)
                Picker("Dauer eines Termins", selection: $engine.settings.slotMinutes) {
                    ForEach([30, 45, 60, 90, 120], id: \.self) { Text("\($0) Minuten").tag($0) }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Kalender, die Zeiten belegen (keiner gewählt = alle)").font(.caption).foregroundStyle(CTW.muted)
                    ForEach(calendars) { c in
                        Toggle(isOn: Binding(
                            get: { engine.settings.availabilityCalendars.contains(c.id) },
                            set: { on in
                                engine.settings.availabilityCalendars.removeAll { $0 == c.id }
                                if on { engine.settings.availabilityCalendars.append(c.id) }
                            })) {
                            Text(c.title) + Text(c.source.isEmpty ? "" : "  ·  \(c.source)").foregroundColor(CTW.muted)
                        }
                    }
                }
                if !preview.isEmpty {
                    Text("Nächste freie Zeiten: " + preview.joined(separator: "; ")).font(.caption).foregroundStyle(CTW.muted)
                }
            }
        } header: {
            SectionHeader(title: "Kalender & freie Zeiten", symbol: "calendar.badge.clock")
        } footer: {
            Text("Wenn eine Mail nach einem Termin fragt, nennt Claude im Entwurf freie Zeiten aus deinem Kalender. Dafür gehen nur die Zeiträume („Dienstag, 4. November, 10:00–11:00 Uhr“) an Claude – nie Titel, Orte oder Teilnehmer. Ganztägige, abgesagte und als „frei“ markierte Termine blockieren nichts.")
                .font(.caption).foregroundStyle(CTW.muted)
        }
        .onAppear { calendars = CalendarAvailability.shared.calendars() }
    }
}

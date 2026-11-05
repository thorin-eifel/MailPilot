import SwiftUI

/// Verwaltung der Konten des eigenen Mail-Clients (bis zu 16): Liste, Bearbeiten, Entfernen.
struct ClientAccountsSection: View {
    @EnvironmentObject var engine: Engine
    @ObservedObject private var model = ClientModel.shared
    @ViewState private var editing: ClientAccount?
    @ViewState private var removing: ClientAccount?

    private var accounts: [ClientAccount] { engine.settings.clientAccounts }

    var body: some View {
        Section {
            if accounts.isEmpty {
                Text("Noch kein Konto. Im Bereich „Postfach“ lässt sich ein IMAP-Konto hinzufügen.").foregroundStyle(.secondary)
            }
            ForEach(accounts) { account in
                HStack(alignment: .top, spacing: 10) {
                    IconTile(symbol: "envelope.fill", color: stateColor(account), size: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.name).fontWeight(.semibold).foregroundStyle(CTW.ink)
                        Text("\(account.email) · \(account.host)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        if case .failed(let message)? = model.accountState[account.id.uuidString] {
                            Label(message, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(CTW.action).lineLimit(2)
                        }
                    }
                    Spacer()
                    Button("Bearbeiten") { editing = account }.buttonStyle(.ctwSecondary)
                    Button(role: .destructive) { removing = account } label: { Image(systemName: "trash") }
                        .buttonStyle(.ctwSecondary).help("Konto entfernen").accessibilityLabel("Konto \(account.name) entfernen")
                }
            }
            Toggle("Beim Verfassen formatierten Text anbieten (fett, kursiv, Links)", isOn: $engine.settings.richCompose)
            HStack {
                Button { model.addingAccount = true; engine.requestedSidebar = .mailbox } label: { Label("Konto hinzufügen", systemImage: "plus") }
                    .buttonStyle(.ctwSecondary).disabled(accounts.count >= ClientAccount.maxAccounts)
                Spacer()
                Text("\(accounts.count) von \(ClientAccount.maxAccounts) Konten").font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            SectionHeader(title: "Postfach-Konten (IMAP)", symbol: "tray.2.fill")
        } footer: {
            Text("Diese Konten liest MailPilot direkt vom Server. Entfernen löscht nur die lokale Kopie und das gespeicherte Passwort – die Mails auf dem Server bleiben. Bis zu \(ClientAccount.maxAccounts) Konten; bis zu \(ClientModel.parallelSyncs) werden gleichzeitig abgeglichen.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .sheet(item: $editing) { EditClientAccountSheet(account: $0).environmentObject(engine) }
        .confirmationDialog("Konto „\(removing?.name ?? "")“ entfernen?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible) {
            Button("Entfernen", role: .destructive) {
                if let a = removing { engine.setAccount(a.engineName, enabled: false); model.removeAccount(a) }
                removing = nil
            }
            Button("Abbrechen", role: .cancel) { removing = nil }
        } message: {
            Text("Die lokale Kopie der Mails und das Passwort im Schlüsselbund werden entfernt, Claude wird für das Konto ausgeschaltet. Bereits gespeicherte Auswertungen bleiben, auf dem Server bleibt alles.")
        }
    }

    private func stateColor(_ a: ClientAccount) -> Color {
        switch model.accountState[a.id.uuidString] {
        case .failed: CTW.action
        case .ok: CTW.accent
        default: CTW.grey500
        }
    }
}

private struct EditClientAccountSheet: View {
    @EnvironmentObject var engine: Engine
    @Environment(\.dismiss) private var dismiss
    @ViewState private var account: ClientAccount
    @ViewState private var password = ""
    @ViewState private var imapPort: String
    @ViewState private var smtpPort: String
    @ViewState private var working = false
    @ViewState private var error: String?

    init(account: ClientAccount) {
        _account = ViewState(initialValue: account)
        _imapPort = ViewState(initialValue: String(account.port))
        _smtpPort = ViewState(initialValue: String(account.smtpPort))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Eyebrow(text: "Konto bearbeiten · \(account.name)")
            Form {
                TextField("Name im Absender", text: $account.displayName)
                TextField("Signatur (steht unter jeder neuen Nachricht)", text: $account.signature, axis: .vertical).lineLimit(3...8)
                TextField("Benutzername", text: $account.username)
                SecureField("Neues Passwort (leer = unverändert)", text: $password)
                TextField("IMAP-Server", text: $account.host)
                TextField("IMAP-Port", text: $imapPort)
                TextField("SMTP-Server", text: $account.smtpHost)
                TextField("SMTP-Port", text: $smtpPort)
                Picker("SMTP-Verschlüsselung", selection: $account.smtpSecurity) {
                    Text("STARTTLS (Port 587)").tag(SMTPSecurity.startTLS)
                    Text("TLS (Port 465)").tag(SMTPSecurity.tls)
                }
            }
            .formStyle(.grouped).scrollContentBackground(.hidden)
            Text("Der Kontoname bleibt, damit die Auswertung der Mails zugeordnet bleibt. Bei geändertem Server, Benutzernamen oder Passwort wird die Anmeldung zuerst geprüft.")
                .font(.caption).foregroundStyle(CTW.muted)
            if let error { Label(error, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(CTW.action) }
            HStack {
                if working { ProgressView().controlSize(.small) }
                Spacer()
                Button("Abbrechen") { dismiss() }.buttonStyle(.ctwSecondary).keyboardShortcut(.cancelAction)
                Button {
                    working = true
                    error = nil
                    var a = account
                    a.port = UInt16(imapPort) ?? a.port
                    a.smtpPort = UInt16(smtpPort) ?? a.smtpPort
                    Task {
                        error = await ClientModel.shared.updateAccount(a, newPassword: password)
                        working = false
                        if error == nil { dismiss() }
                    }
                } label: { Label("Sichern", systemImage: "checkmark") }
                    .buttonStyle(.ctwPrimary).keyboardShortcut(.defaultAction)
                    .disabled(working || account.host.isEmpty || account.username.isEmpty || UInt16(imapPort) == nil || UInt16(smtpPort) == nil)
            }
        }
        .padding(20)
        .frame(width: 500)
        .background(CTW.surface)
    }
}

/// Als Standard-Mailprogramm festlegen (`mailto:`-Links und `.eml`-Dateien).
struct DefaultMailSection: View {
    @ViewState private var mailto = DefaultMailApp.isDefaultForMailto
    @ViewState private var eml = DefaultMailApp.isDefaultForEML
    @ViewState private var mailtoName = DefaultMailApp.name(of: DefaultMailApp.current(forScheme: "mailto"))
    @ViewState private var emlName = DefaultMailApp.name(of: DefaultMailApp.currentForEML())
    @ViewState private var error: String?

    var body: some View {
        Section {
            row("E-Mail-Links (mailto:)", isDefault: mailto, current: mailtoName)
            row(".eml-Dateien", isDefault: eml, current: emlName)
            HStack {
                Button {
                    Task {
                        error = await DefaultMailApp.makeDefault()
                        refresh()
                    }
                } label: { Label("Als Standard-Mailprogramm festlegen", systemImage: "checkmark.seal") }
                    .buttonStyle(.ctwSecondary).disabled(mailto && eml)
                Button("Aktualisieren") { refresh() }.buttonStyle(.ctwSecondary)
            }
            if let error { Label(error, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(CTW.action) }
        } header: {
            SectionHeader(title: "Standard-Mailprogramm", symbol: "envelope.badge.shield.half.filled")
        } footer: {
            Text("Dann öffnen Klicks auf E-Mail-Adressen und Links in anderen Programmen MailPilot mit einer neuen Nachricht, und .eml-Dateien erscheinen hier. Dateien lassen sich außerdem im Finder markieren und über Dienste → „Mit MailPilot senden“ als Anhang verschicken (nach dem ersten Start der App aus dem Ordner „Programme“, ggf. nach erneuter Anmeldung). macOS fragt beim Festlegen selbst um Bestätigung.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func row(_ title: String, isDefault: Bool, current: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            if isDefault { Badge(text: "MailPilot", color: CTW.teal700, symbol: "checkmark") } else { Text(current).foregroundStyle(.secondary) }
        }
    }

    private func refresh() {
        mailto = DefaultMailApp.isDefaultForMailto
        eml = DefaultMailApp.isDefaultForEML
        mailtoName = DefaultMailApp.name(of: DefaultMailApp.current(forScheme: "mailto"))
        emlName = DefaultMailApp.name(of: DefaultMailApp.currentForEML())
    }
}

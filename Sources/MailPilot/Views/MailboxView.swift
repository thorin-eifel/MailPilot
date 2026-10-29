import SwiftUI
import WebKit

/// Eigener Mail-Client: Ordner, Nachrichtenliste, Leseansicht.
struct MailboxView: View {
    @EnvironmentObject var engine: Engine
    @ObservedObject private var model = ClientModel.shared
    @ViewState private var allowRemote = false
    @ViewState private var compose: ComposeDraft?
    @ViewState private var showMail = false

    var body: some View {
        Group {
            if engine.settings.clientAccounts.isEmpty {
                emptyState
            } else {
                HStack(spacing: 0) {
                    listColumn.frame(width: 380).frame(maxHeight: .infinity)
                    Divider()
                    readerColumn.frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CTW.bg)
        .sheet(isPresented: $model.addingAccount) { AddAccountSheet().environmentObject(engine) }
        .confirmationDialog("Claude für dieses Konto einschalten?", isPresented: Binding(get: { model.confirmEnable != nil }, set: { if !$0 { model.confirmEnable = nil } }),
                            titleVisibility: .visible) {
            Button(engine.settings.dryRun ? "Einschalten (Probelauf aktiv)" : "Einschalten und Erstscan starten") {
                if let a = model.confirmEnable { engine.setAccount(a.engineName, enabled: true) }
                model.confirmEnable = nil
            }
            Button("Abbrechen", role: .cancel) { model.confirmEnable = nil }
        } message: {
            Text("Claude liest die Mails der letzten \(engine.settings.initialScanDays) Tage (außer Datenschutz-Ausnahmen), vergibt Kategorien, schreibt Antwortentwürfe und sortiert Mails in Ordner „\(engine.settings.folderPrefix)…“ auf dem Server. Das ändert dein echtes Postfach. Jede Verschiebung steht unter „Aktivität“ und lässt sich rückgängig machen." + (engine.settings.dryRun ? " Der Probelauf ist an: dann wird nur protokolliert, nichts verschoben." : ""))
        }
        .sheet(item: $compose) { ComposeSheet(draft: $0).environmentObject(engine) }
        .onChange(of: model.pendingCompose?.id) { _, _ in takePending() }
        .onAppear { takePending(); model.reloadAnalysis() }
        .onChange(of: model.messages.count) { _, _ in model.reloadAnalysis() }
        .onReceive(engine.$threads) { _ in model.reloadAnalysis() }
        .task {
            model.reloadFolders()
            await model.refresh()
            // Alle 60 Sekunden den gewählten Ordner abgleichen, solange die Ansicht offen ist.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                if Task.isCancelled { break }
                await model.syncSelected()
            }
        }
        .toolbar {
            ToolbarItem {
                Button { startNew() } label: { Label("Neue Nachricht", systemImage: "square.and.pencil") }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(engine.settings.clientAccounts.isEmpty)
                    .help("Neue Nachricht (⇧⌘N)")
            }
            ToolbarItem {
                Button { Task { await model.refresh() } } label: { Label("Postfach abgleichen", systemImage: "arrow.triangle.2.circlepath") }
                    .disabled(model.busy)
                    .help("Postfach abgleichen")
            }
        }
    }

    // MARK: Leer

    private var emptyState: some View {
        VStack(spacing: 14) {
            ContentUnavailableView("Noch kein Konto", systemImage: "tray.2",
                                   description: Text("Verbinde ein IMAP-Konto (iCloud, GMX, WEB.DE, IONOS, Strato, Posteo, mailbox.org oder ein eigener Server), um Mails direkt in MailPilot zu lesen und zu senden."))
                .foregroundStyle(CTW.muted)
            Button { model.addingAccount = true } label: { Label("Konto hinzufügen", systemImage: "plus") }
                .buttonStyle(.ctwPrimary)
        }
    }

    // MARK: Liste

    private var listColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Eyebrow(text: "\(model.messages.count) Nachrichten")
                Text(model.selectedFolder?.name ?? "Postfach").font(.system(size: 20, weight: .bold)).foregroundStyle(CTW.ink)
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(CTW.surface)
            .overlay(alignment: .bottom) { Rectangle().fill(CTW.lineSoft).frame(height: 1) }

            List(model.messages, selection: Binding(get: { model.selectedMessageID }, set: { id in
                model.selectedMessageID = id
                allowRemote = false
                showMail = false
                if let m = model.messages.first(where: { $0.id == id }) { Task { await model.open(m) } }
            })) { m in
                MessageListRow(message: m, analysis: model.analysis[m.messageId]).tag(m.id).listRowSeparatorTint(CTW.lineSoft)
            }
            .scrollContentBackground(.hidden)
            .background(CTW.surface)
            .overlay {
                if model.messages.isEmpty {
                    ContentUnavailableView(model.busy ? "Lade …" : "Keine Nachrichten", systemImage: "tray").foregroundStyle(CTW.muted)
                }
            }
        }
        .background(CTW.surface.ignoresSafeArea(edges: .top))
    }

    // MARK: Lesen

    @ViewBuilder
    private var readerColumn: some View {
        if let id = model.selectedMessageID, let m = model.messages.first(where: { $0.id == id }) {
            if let t = model.thread(for: m.messageId), !showMail {
                // Wie in „Gespräche“: Stand, Entwurf und Verlauf; die Mail selbst steht hinter „Mail anzeigen“.
                VStack(spacing: 0) {
                    HStack {
                        Spacer()
                        Button { showMail = true } label: { Label("Mail anzeigen", systemImage: "envelope.open") }.buttonStyle(.ctwSecondary)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    ThreadDetailView(thread: t).id(t.threadKey)
                }
                .background(CTW.bg.ignoresSafeArea(edges: .top))
            } else {
                mailReader(m)
            }
        } else {
            ContentUnavailableView("Nachricht auswählen", systemImage: "envelope.open").foregroundStyle(CTW.muted)
        }
    }

    private func mailReader(_ m: ClientMessage) -> some View {
        Group {
            VStack(alignment: .leading, spacing: 0) {
                if model.thread(for: m.messageId) != nil {
                    HStack {
                        Spacer()
                        Button { showMail = false } label: { Label("Gespräch anzeigen", systemImage: "bubble.left.and.bubble.right") }.buttonStyle(.ctwSecondary)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 8)
                }
                readerHeader(m)
                claudeCard(m)
                Divider()
                if let parsed = model.opened {
                    attachments(parsed)
                    if let html = parsed.htmlWithInlineImages() {
                        if !allowRemote, html.range(of: #"(?i)(src|href|url)\s*[=(]\s*["']?https?://"#, options: .regularExpression) != nil {
                            HStack {
                                Label("Externe Bilder und Inhalte sind blockiert.", systemImage: "eye.slash").font(.caption)
                                Spacer()
                                Button("Laden") { allowRemote = true }.buttonStyle(.ctwSecondary)
                            }
                            .padding(.horizontal, 16).padding(.vertical, 6)
                            .foregroundStyle(CTW.muted)
                            .background(CTW.surfaceSoft)
                        }
                        MailWebView(html: html, allowRemote: allowRemote)
                    } else {
                        ScrollView {
                            Text(parsed.text.isEmpty ? "(kein Text)" : parsed.text)
                                .textSelection(.enabled).foregroundStyle(CTW.ink)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(20)
                        }
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(CTW.surface.ignoresSafeArea(edges: .top))
        }
    }

    private func readerHeader(_ m: ClientMessage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(m.subject.isEmpty ? "(kein Betreff)" : m.subject).font(.system(size: 20, weight: .bold)).foregroundStyle(CTW.ink).textSelection(.enabled)
            HStack(spacing: 8) {
                IconTile(symbol: "person.crop.circle", color: CTW.accent, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(m.senderName.isEmpty ? m.senderEmail : "\(m.senderName) <\(m.senderEmail)>").fontWeight(.semibold).foregroundStyle(CTW.ink).textSelection(.enabled)
                    if !m.recipients.isEmpty { Text("An: " + m.recipients.joined(separator: ", ")).font(.caption).foregroundStyle(CTW.muted).lineLimit(2).textSelection(.enabled) }
                }
                Spacer()
                Text(m.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(CTW.muted)
                Button { startReply(m, all: false) } label: { Image(systemName: "arrowshape.turn.up.left") }
                    .buttonStyle(.borderless).disabled(model.opened == nil).help("Antworten").accessibilityLabel("Antworten")
                Button { startReply(m, all: true) } label: { Image(systemName: "arrowshape.turn.up.left.2") }
                    .buttonStyle(.borderless).disabled(model.opened == nil).help("Allen antworten").accessibilityLabel("Allen antworten")
                Button { startForward(m) } label: { Image(systemName: "arrowshape.turn.up.right") }
                    .buttonStyle(.borderless).disabled(model.opened == nil).help("Weiterleiten").accessibilityLabel("Weiterleiten")
                PlanMenu(subject: m.subject, sender: m.senderDisplay, date: m.date, messageId: m.messageId, ownClient: true, due: model.thread(for: m.messageId)?.dueDate)
                Button { Task { await model.setRead(m, !m.isRead) } } label: {
                    Image(systemName: m.isRead ? "envelope.badge" : "envelope.open")
                }
                .buttonStyle(.borderless)
                .help(m.isRead ? "Als ungelesen markieren" : "Als gelesen markieren")
                .accessibilityLabel(m.isRead ? "Als ungelesen markieren" : "Als gelesen markieren")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Claudes Einschätzung zur Nachricht und zum Gespräch: Kategorie, Zusammenfassung, nächster Schritt, Frist, Entwurf.
    @ViewBuilder
    private func claudeCard(_ m: ClientMessage) -> some View {
        if let a = model.analysis[m.messageId] {
            let t = model.thread(for: m.messageId)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles").foregroundStyle(CTW.accent)
                    if let c = a.category { Badge(text: c, color: CTW.accent, symbol: "tag.fill") }
                    if let d = a.decidedBy, d != "Claude" { Badge(text: d, color: CTW.accent, symbol: d == "VIP" ? "star.fill" : "slider.horizontal.3") }
                    if let p = a.priority, p != .normal { Badge(text: p.label, color: p == .high ? CTW.action : CTW.grey500, symbol: p.symbol) }
                    if let t { Badge(text: t.status.label, color: t.status == .needsReply ? CTW.action : CTW.teal700, symbol: t.status.symbol) }
                    Spacer()
                }
                if let s = t?.summary, !s.isEmpty { Text(s).font(.callout).foregroundStyle(CTW.ink).textSelection(.enabled) }
                else if let s = a.summary, !s.isEmpty { Text(s).font(.callout).foregroundStyle(CTW.ink).textSelection(.enabled) }
                if let n = t?.nextStep, !n.isEmpty { Label(n, systemImage: "arrow.right.circle.fill").font(.callout.weight(.medium)).foregroundStyle(CTW.accent) }
                if let due = t?.dueDate { Label("Frist: \(Deadlines.parse(due).map { $0.formatted(date: .complete, time: .omitted) } ?? due)", systemImage: "calendar").font(.callout).foregroundStyle(CTW.accent) }
                if let draft = t?.draft, !draft.isEmpty, t?.draftFor == m.messageId || t?.draftFor == nil {
                    Button { startReply(m, all: false, prefill: draft) } label: { Label("Antwort mit Claudes Entwurf", systemImage: "square.and.pencil") }
                        .buttonStyle(.ctwSecondary).disabled(model.opened == nil)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(CTW.accent.opacity(0.06))
        } else if let account = model.account(UUID(uuidString: m.account) ?? UUID()), !engine.settings.isEnabled(account.engineName) {
            HStack {
                Image(systemName: "sparkles").foregroundStyle(CTW.muted)
                Text("Claude ist für dieses Konto aus.").font(.caption).foregroundStyle(CTW.muted)
                Spacer()
            }
            .padding(.horizontal, 16).padding(.vertical, 6)
        }
    }

    @ViewBuilder
    private func attachments(_ parsed: ParsedMessage) -> some View {
        let files = parsed.attachments.filter { !($0.isInline && $0.mime.hasPrefix("image/") && $0.contentID != nil) }
        if !files.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(files) { a in
                        Button { save(a) } label: {
                            Label("\(a.name) · \(ByteCountFormatter.string(fromByteCount: Int64(a.data.count), countStyle: .file))", systemImage: "paperclip")
                        }
                        .buttonStyle(.ctwSecondary)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
            }
        }
    }

    private func takePending() {
        if let d = model.pendingCompose { compose = d; model.pendingCompose = nil }
    }

    private func startNew() {
        let id = model.selectedFolder.flatMap { UUID(uuidString: $0.account) } ?? engine.settings.clientAccounts.first?.id
        if let id { compose = ComposeDraft(accountID: id) }
    }

    private func startReply(_ m: ClientMessage, all: Bool, prefill: String = "") {
        guard let parsed = model.opened, let header = model.openedHeader, let id = UUID(uuidString: m.account), let account = model.account(id) else { return }
        var draft = ComposeDraft.reply(to: m, header: header, parsed: parsed, accountID: id, ownEmail: account.email, all: all)
        if !prefill.isEmpty { draft.body = prefill + "\n\n" + draft.body }
        compose = draft
    }

    private func startForward(_ m: ClientMessage) {
        guard let parsed = model.opened, let header = model.openedHeader, let id = UUID(uuidString: m.account) else { return }
        compose = .forward(m, header: header, parsed: parsed, accountID: id)
    }

    private func save(_ a: MailAttachment) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = a.name
        if panel.runModal() == .OK, let url = panel.url { try? a.data.write(to: url) }
    }
}

struct MessageListRow: View {
    let message: ClientMessage
    var analysis: StoredMessage?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(message.isRead ? Color.clear : CTW.accent).frame(width: 8, height: 8).padding(.top, 6)
                .accessibilityLabel(message.isRead ? "Gelesen" : "Ungelesen")
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(message.senderDisplay).font(.system(size: 13, weight: message.isRead ? .regular : .semibold)).foregroundStyle(CTW.ink).lineLimit(1)
                    Spacer()
                    Text(message.date.formatted(.relative(presentation: .numeric))).font(.caption).foregroundStyle(CTW.muted)
                }
                Text(message.subject.isEmpty ? "(kein Betreff)" : message.subject)
                    .font(.system(size: 12.5, weight: message.isRead ? .regular : .medium)).foregroundStyle(CTW.ink).lineLimit(1)
                if let a = analysis {
                    if let s = a.summary, !s.isEmpty { Text(s).font(.caption).foregroundStyle(CTW.muted).lineLimit(2) }
                    HStack(spacing: 4) {
                        if let c = a.category { Badge(text: c, color: CTW.accent, symbol: "tag.fill") }
                        if a.priority == .high { Badge(text: "Wichtig", color: CTW.action, symbol: "exclamationmark.2") }
                    }
                } else if !message.preview.isEmpty {
                    Text(message.preview).font(.caption).foregroundStyle(CTW.muted).lineLimit(2)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - HTML-Anzeige ohne Skripte und ohne Nachladen

struct MailWebView: NSViewRepresentable {
    let html: String
    let allowRemote: Bool

    static let blockRules = """
    [{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}}]
    """

    final class Coordinator: NSObject, WKNavigationDelegate {
        var key = ""
        var ruleList: WKContentRuleList?

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .linkActivated {
                if let url = navigationAction.request.url, ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") { NSWorkspace.shared.open(url) }
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.defaultWebpagePreferences.allowsContentJavaScript = false
        let web = WKWebView(frame: .zero, configuration: cfg)
        web.navigationDelegate = context.coordinator
        web.setValue(false, forKey: "drawsBackground")
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        let key = "\(allowRemote)|\(html.hashValue)"
        guard context.coordinator.key != key else { return }
        context.coordinator.key = key
        let csp = allowRemote
            ? "default-src 'none'; img-src data: https: http:; style-src 'unsafe-inline' https: http:; font-src data: https: http:"
            : "default-src 'none'; img-src data:; style-src 'unsafe-inline'; font-src data:"
        let doc = """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="\(csp)">
        <style>:root{color-scheme: light dark} body{font:14px -apple-system, sans-serif; margin:16px; word-wrap:break-word} img{max-width:100%; height:auto}</style>
        </head><body>\(html)</body></html>
        """
        let controller = web.configuration.userContentController
        controller.removeAllContentRuleLists()
        if allowRemote {
            web.loadHTMLString(doc, baseURL: nil)
        } else {
            WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "mailpilot-block-remote", encodedContentRuleList: Self.blockRules) { list, _ in
                DispatchQueue.main.async {
                    if let list { controller.add(list) }
                    web.loadHTMLString(doc, baseURL: nil)
                }
            }
        }
    }
}

// MARK: - Konto hinzufügen

/// Voreinstellungen für gängige Anbieter. Alles läuft mit Benutzername und Passwort (bei iCloud, GMX u. a. ein App-/Zugangspasswort);
/// Anmeldung per OAuth (Microsoft 365, Gmail) gibt es nicht.
struct MailProvider: Identifiable, Hashable {
    var name: String
    var imapHost: String
    var smtpHost: String
    var smtpPort: UInt16
    var smtpSecurity: SMTPSecurity
    var hint: String

    var id: String { name }
    var isCustom: Bool { imapHost.isEmpty }

    static let all: [MailProvider] = [
        .init(name: "iCloud", imapHost: "imap.mail.me.com", smtpHost: "smtp.mail.me.com", smtpPort: 587, smtpSecurity: .startTLS,
              hint: "Erzeuge unter appleid.apple.com → Anmeldung und Sicherheit → App-spezifische Passwörter ein Passwort für MailPilot. Dein normales Apple-Passwort funktioniert hier nicht."),
        .init(name: "GMX", imapHost: "imap.gmx.net", smtpHost: "mail.gmx.net", smtpPort: 587, smtpSecurity: .startTLS,
              hint: "Aktiviere in GMX unter Einstellungen → POP3/IMAP den Abruf über externe Programme."),
        .init(name: "WEB.DE", imapHost: "imap.web.de", smtpHost: "smtp.web.de", smtpPort: 587, smtpSecurity: .startTLS,
              hint: "Aktiviere in WEB.DE unter Einstellungen → POP3/IMAP den Abruf über externe Programme."),
        .init(name: "IONOS", imapHost: "imap.ionos.de", smtpHost: "smtp.ionos.de", smtpPort: 587, smtpSecurity: .startTLS,
              hint: "Benutzername ist die vollständige E-Mail-Adresse."),
        .init(name: "Strato", imapHost: "imap.strato.de", smtpHost: "smtp.strato.de", smtpPort: 465, smtpSecurity: .tls,
              hint: "Benutzername ist die vollständige E-Mail-Adresse."),
        .init(name: "Posteo", imapHost: "posteo.de", smtpHost: "posteo.de", smtpPort: 587, smtpSecurity: .startTLS,
              hint: "Benutzername ist die vollständige E-Mail-Adresse."),
        .init(name: "mailbox.org", imapHost: "imap.mailbox.org", smtpHost: "smtp.mailbox.org", smtpPort: 587, smtpSecurity: .startTLS,
              hint: "Benutzername ist die vollständige E-Mail-Adresse; mit Zwei-Faktor-Anmeldung brauchst du ein App-Passwort."),
        .init(name: "Anderes IMAP/SMTP", imapHost: "", smtpHost: "", smtpPort: 587, smtpSecurity: .startTLS,
              hint: "Trage die Serverdaten deines Anbieters ein. IMAP muss verschlüsselt sein (meist Port 993)."),
    ]
}

struct AddAccountSheet: View {
    @EnvironmentObject var engine: Engine
    @Environment(\.dismiss) private var dismiss
    @ViewState private var provider = MailProvider.all[0]
    @ViewState private var displayName = ""
    @ViewState private var email = ""
    @ViewState private var username = ""
    @ViewState private var password = ""
    @ViewState private var imapHost = ""
    @ViewState private var imapPort = "993"
    @ViewState private var smtpHost = ""
    @ViewState private var smtpPort = "587"
    @ViewState private var smtpSecurity: SMTPSecurity = .startTLS
    @ViewState private var working = false
    @ViewState private var error: String?

    private var host: String { provider.isCustom ? imapHost.trimmingCharacters(in: .whitespaces) : provider.imapHost }
    private var valid: Bool {
        email.contains("@") && !password.isEmpty && !host.isEmpty && UInt16(imapPort) != nil
            && (!provider.isCustom || (!smtpHost.trimmingCharacters(in: .whitespaces).isEmpty && UInt16(smtpPort) != nil))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Eyebrow(text: "Konto hinzufügen")
            Form {
                Picker("Anbieter", selection: $provider) { ForEach(MailProvider.all) { Text($0.name).tag($0) } }
                TextField("Name im Absender (optional)", text: $displayName)
                TextField("E-Mail-Adresse", text: $email).textContentType(.emailAddress)
                TextField("Benutzername (leer = E-Mail-Adresse)", text: $username)
                SecureField(provider.name == "iCloud" ? "App-spezifisches Passwort" : "Passwort", text: $password)
                if provider.isCustom {
                    TextField("IMAP-Server", text: $imapHost)
                    TextField("IMAP-Port", text: $imapPort)
                    TextField("SMTP-Server", text: $smtpHost)
                    TextField("SMTP-Port", text: $smtpPort)
                    Picker("SMTP-Verschlüsselung", selection: $smtpSecurity) {
                        Text("STARTTLS (Port 587)").tag(SMTPSecurity.startTLS)
                        Text("TLS (Port 465)").tag(SMTPSecurity.tls)
                    }
                }
            }
            .formStyle(.grouped).scrollContentBackground(.hidden)
            Text(provider.hint).font(.callout).foregroundStyle(CTW.muted)
            if let error { Label(error, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(CTW.action) }
            Text("Das Passwort wird im Schlüsselbund gespeichert, nicht in den Einstellungen. Geprüft wird nur die IMAP-Anmeldung; der SMTP-Versand zeigt sich beim ersten Senden.")
                .font(.caption).foregroundStyle(CTW.muted)
            HStack {
                if working { ProgressView().controlSize(.small) }
                Spacer()
                Button("Abbrechen") { dismiss() }.buttonStyle(.ctwSecondary).keyboardShortcut(.cancelAction)
                Button { connect() } label: { Label("Verbinden", systemImage: "checkmark") }
                    .buttonStyle(.ctwPrimary).keyboardShortcut(.defaultAction)
                    .disabled(working || !valid)
            }
        }
        .padding(20)
        .frame(width: 500)
        .background(CTW.surface)
        .onChange(of: provider) { _, p in
            if !p.isCustom { imapPort = "993"; smtpHost = p.smtpHost; smtpPort = String(p.smtpPort); smtpSecurity = p.smtpSecurity }
            error = nil
        }
        .onAppear { smtpHost = provider.smtpHost; smtpPort = String(provider.smtpPort); smtpSecurity = provider.smtpSecurity }
    }

    private func connect() {
        working = true
        error = nil
        let mail = email.trimmingCharacters(in: .whitespaces)
        let login = username.trimmingCharacters(in: .whitespaces)
        // Zwei Konten beim selben Anbieter brauchen verschiedene Namen (sie erscheinen als „<Name> (IMAP)“).
        let taken = engine.settings.clientAccounts.contains { $0.name == provider.name }
        var account = ClientAccount(name: provider.isCustom ? (mail.split(separator: "@").last.map(String.init) ?? "IMAP") : (taken ? "\(provider.name) \(mail)" : provider.name),
                                    email: mail, username: login.isEmpty ? mail : login, host: host, port: UInt16(imapPort) ?? 993,
                                    displayName: displayName.trimmingCharacters(in: .whitespaces))
        account.smtpHost = provider.isCustom ? smtpHost.trimmingCharacters(in: .whitespaces) : provider.smtpHost
        account.smtpPort = provider.isCustom ? (UInt16(smtpPort) ?? 587) : provider.smtpPort
        account.smtpSecurity = provider.isCustom ? smtpSecurity : provider.smtpSecurity
        let pw = password
        Task {
            error = await ClientModel.shared.addAccount(account, password: pw)
            working = false
            if error == nil { dismiss() }
        }
    }
}

// MARK: - Ordnerbaum in der Seitenleiste

/// Konten und Ordner unter „Postfach“; Unterordner eingerückt. Dazu je Konto der Claude-Schalter.
struct MailboxSidebarTree: View {
    @EnvironmentObject var engine: Engine
    @ObservedObject private var model = ClientModel.shared
    let open: () -> Void

    /// Oberste Ebene: Spezialordner zuerst, dann nach Name; jeder Ordner gefolgt von seinen Unterordnern (nach Pfad).
    /// Unterordner, deren Elternordner fehlt, stehen am Ende.
    static func ordered(_ folders: [ClientFolder]) -> [ClientFolder] {
        let all = folders.filter(\.selectable)
        let byPath: (ClientFolder, ClientFolder) -> Bool = { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
        let roots = all.filter { $0.depth == 0 }.sorted { ($0.sortRank, $0.path.lowercased()) < ($1.sortRank, $1.path.lowercased()) }
        var out: [ClientFolder] = []
        var used = Set<String>()
        for r in roots {
            out.append(r)
            used.insert(r.id)
            let prefix = r.path + r.delimiter
            for c in all.filter({ $0.path.hasPrefix(prefix) }).sorted(by: byPath) where used.insert(c.id).inserted { out.append(c) }
        }
        out += all.filter { !used.contains($0.id) }.sorted(by: byPath)
        return out
    }

    var body: some View {
        ForEach(engine.settings.clientAccounts) { account in
            if engine.settings.clientAccounts.count > 1 { Eyebrow(text: account.name).padding(.leading, 28).listRowSeparator(.hidden) }
            ForEach(Self.ordered(model.folders[account.id.uuidString] ?? [])) { f in
                folderRow(f)
            }
            claudeSwitch(account).listRowSeparator(.hidden)
        }
        Button { model.addingAccount = true } label: { Label("Konto hinzufügen", systemImage: "plus").font(.caption) }
            .buttonStyle(.plain).foregroundStyle(CTW.muted).padding(.leading, 14).listRowSeparator(.hidden)
    }

    private func folderRow(_ f: ClientFolder) -> some View {
        let selected = model.selectedFolder?.id == f.id
        return Button { model.selectFolder(f); open() } label: {
            HStack(spacing: 6) {
                Image(systemName: f.symbol).foregroundStyle(selected ? CTW.accent : CTW.muted).frame(width: 18)
                Text(f.leafName).lineLimit(1)
                Spacer(minLength: 0)
                if f.unread > 0 { Text("\(f.unread)").font(.caption2).monospacedDigit().foregroundStyle(CTW.muted) }
            }
            .padding(.leading, 14 + CGFloat(f.depth) * 14)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowSeparator(.hidden)
        .listRowBackground(selected ? RoundedRectangle(cornerRadius: 6).fill(CTW.accent.opacity(0.14)).padding(.horizontal, 10) : nil)
    }

    private func claudeSwitch(_ account: ClientAccount) -> some View {
        let on = engine.settings.isEnabled(account.engineName)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").foregroundStyle(on ? CTW.accent : CTW.muted).frame(width: 18)
                Text(on ? "Claude aktiv" : "Claude aus").font(.caption.weight(.semibold)).foregroundStyle(CTW.ink)
                Spacer()
                Toggle("", isOn: Binding(get: { on }, set: { want in
                    if want { model.confirmEnable = account } else { engine.setAccount(account.engineName, enabled: false) }
                }))
                .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                .accessibilityLabel("Claude für \(account.name)")
            }
            if on {
                Text(engine.isScanned(account.engineName) ? "Neue Mails laufend verarbeitet" : "Erstscan läuft/wartet")
                    .font(.caption2).foregroundStyle(CTW.muted).padding(.leading, 24)
            }
        }
        .padding(.leading, 14).padding(.vertical, 4)
    }
}

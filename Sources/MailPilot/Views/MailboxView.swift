import SwiftUI
import WebKit

/// Eigener Mail-Client: Ordner, Nachrichtenliste, Leseansicht.
struct MailboxView: View {
    @EnvironmentObject var engine: Engine
    @ObservedObject private var model = ClientModel.shared
    @ViewState private var addingAccount = false
    @ViewState private var allowRemote = false
    @ViewState private var compose: ComposeDraft?

    var body: some View {
        Group {
            if engine.settings.clientAccounts.isEmpty {
                emptyState
            } else {
                HSplitView {
                    folderColumn.frame(minWidth: 180, idealWidth: 210, maxWidth: 280)
                    listColumn.frame(minWidth: 320, idealWidth: 380)
                    readerColumn.frame(minWidth: 420, maxWidth: .infinity)
                }
            }
        }
        .background(CTW.bg)
        .sheet(isPresented: $addingAccount) { AddAccountSheet().environmentObject(engine) }
        .sheet(item: $compose) { ComposeSheet(draft: $0).environmentObject(engine) }
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
                                   description: Text("Verbinde ein iCloud-Konto, um Mails direkt in MailPilot zu lesen. Dafür brauchst du ein App-spezifisches Passwort von appleid.apple.com."))
                .foregroundStyle(CTW.muted)
            Button { addingAccount = true } label: { Label("iCloud-Konto hinzufügen", systemImage: "plus") }
                .buttonStyle(.ctwPrimary)
        }
    }

    // MARK: Ordner

    private var folderColumn: some View {
        List(selection: Binding(get: { model.selectedFolder?.id }, set: { id in
            if let f = model.folders.values.flatMap({ $0 }).first(where: { $0.id == id }) { model.selectFolder(f) }
        })) {
            ForEach(engine.settings.clientAccounts) { account in
                Section {
                    ForEach((model.folders[account.id.uuidString] ?? []).filter(\.selectable)) { f in
                        Label(f.name, systemImage: f.symbol)
                            .badge(f.unread)
                            .tag(f.id)
                    }
                } header: {
                    HStack {
                        Eyebrow(text: account.name)
                        Spacer()
                        Button(role: .destructive) { model.removeAccount(account) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .help("Konto entfernen")
                            .accessibilityLabel("Konto entfernen")
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                Button { addingAccount = true } label: { Label("Konto hinzufügen", systemImage: "plus") }
                    .buttonStyle(.ctwSecondary)
                if model.busy { HStack(spacing: 6) { ProgressView().controlSize(.mini); Text(model.status).lineLimit(1) }.font(.caption).foregroundStyle(CTW.muted) }
                if let e = model.error {
                    Label(e, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(CTW.action).lineLimit(4)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
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
                if let m = model.messages.first(where: { $0.id == id }) { Task { await model.open(m) } }
            })) { m in
                MessageListRow(message: m).tag(m.id).listRowSeparatorTint(CTW.lineSoft)
            }
            .scrollContentBackground(.hidden)
            .background(CTW.surface)
            .overlay {
                if model.messages.isEmpty {
                    ContentUnavailableView(model.busy ? "Lade …" : "Keine Nachrichten", systemImage: "tray").foregroundStyle(CTW.muted)
                }
            }
        }
        .background(CTW.surface)
    }

    // MARK: Lesen

    @ViewBuilder
    private var readerColumn: some View {
        if let id = model.selectedMessageID, let m = model.messages.first(where: { $0.id == id }) {
            VStack(alignment: .leading, spacing: 0) {
                readerHeader(m)
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
            .background(CTW.surface)
        } else {
            ContentUnavailableView("Nachricht auswählen", systemImage: "envelope.open").foregroundStyle(CTW.muted)
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
        .overlay(alignment: .bottom) { Rectangle().fill(CTW.lineSoft).frame(height: 1) }
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

    private func startNew() {
        let id = model.selectedFolder.flatMap { UUID(uuidString: $0.account) } ?? engine.settings.clientAccounts.first?.id
        if let id { compose = ComposeDraft(accountID: id) }
    }

    private func startReply(_ m: ClientMessage, all: Bool) {
        guard let parsed = model.opened, let header = model.openedHeader, let id = UUID(uuidString: m.account), let account = model.account(id) else { return }
        compose = .reply(to: m, header: header, parsed: parsed, accountID: id, ownEmail: account.email, all: all)
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
                if !message.preview.isEmpty { Text(message.preview).font(.caption).foregroundStyle(CTW.muted).lineLimit(2) }
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

struct AddAccountSheet: View {
    @EnvironmentObject var engine: Engine
    @Environment(\.dismiss) private var dismiss
    @ViewState private var displayName = ""
    @ViewState private var email = ""
    @ViewState private var password = ""
    @ViewState private var working = false
    @ViewState private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Eyebrow(text: "iCloud-Konto hinzufügen")
            Text("Erzeuge unter appleid.apple.com → Anmeldung und Sicherheit → App-spezifische Passwörter ein Passwort für MailPilot. Dein normales Apple-Passwort funktioniert hier nicht und wird nicht gebraucht.")
                .font(.callout).foregroundStyle(CTW.muted)
            Form {
                TextField("Name im Absender (optional)", text: $displayName)
                TextField("iCloud-Adresse", text: $email).textContentType(.emailAddress)
                SecureField("App-spezifisches Passwort", text: $password)
            }
            .formStyle(.grouped).scrollContentBackground(.hidden)
            if let error { Label(error, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(CTW.action) }
            Text("Das Passwort wird im Schlüsselbund gespeichert, nicht in den Einstellungen.").font(.caption).foregroundStyle(CTW.muted)
            HStack {
                if working { ProgressView().controlSize(.small) }
                Spacer()
                Button("Abbrechen") { dismiss() }.buttonStyle(.ctwSecondary).keyboardShortcut(.cancelAction)
                Button {
                    working = true
                    error = nil
                    Task {
                        let account = ClientAccount.iCloud(email: email.trimmingCharacters(in: .whitespaces), displayName: displayName.trimmingCharacters(in: .whitespaces))
                        error = await ClientModel.shared.addAccount(account, password: password.trimmingCharacters(in: .whitespaces))
                        working = false
                        if error == nil { dismiss() }
                    }
                } label: { Label("Verbinden", systemImage: "checkmark") }
                    .buttonStyle(.ctwPrimary).keyboardShortcut(.defaultAction)
                    .disabled(working || !email.contains("@") || password.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
        .background(CTW.surface)
    }
}

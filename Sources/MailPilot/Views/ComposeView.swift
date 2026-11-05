import SwiftUI
import UniformTypeIdentifiers

/// Nachricht verfassen: Neu, Antwort, Allen antworten, Weiterleiten. Gesendet wird erst auf „Senden“.
struct ComposeSheet: View {
    @EnvironmentObject var engine: Engine
    @Environment(\.dismiss) private var dismiss
    @ViewState private var draft: ComposeDraft
    @ViewState private var showCc: Bool
    @ViewState private var working = false
    @ViewState private var error: String?
    @ViewState private var confirmDiscard = false
    @ViewState private var savedBody: String?
    @StateObject private var editor = RichTextController()
    @ViewState private var rich = Engine.shared.settings.richCompose
    @ViewState private var askLink = false
    @ViewState private var linkText = ""
    /// Text, mit dem der Editor startet (Signatur ist schon eingesetzt).
    private let initialText: String

    init(draft: ComposeDraft) {
        var d = draft
        // Signatur des Kontos einsetzen (einmal): unter den Text, bei Antworten über das Zitat.
        if d.appliedSignature == nil {
            let sig = ClientModel.shared.account(d.accountID)?.signature ?? ""
            d.body = Signature.replacing(nil, with: sig, in: d.body)
            d.appliedSignature = sig
        }
        initialText = d.body
        _draft = ViewState(initialValue: d)
        _showCc = ViewState(initialValue: !d.cc.isEmpty || !d.bcc.isEmpty)
    }

    private var accounts: [ClientAccount] { engine.settings.clientAccounts }
    private var hasContent: Bool { !draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !draft.subject.isEmpty || !draft.to.isEmpty }
    private var attachmentBytes: Int { draft.attachments.reduce(0) { $0 + $1.data.count } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow(text: draft.kind == .reply ? "Antworten" : (draft.kind == .forward ? "Weiterleiten" : "Neue Nachricht"))
            if accounts.count > 1 {
                Picker("Von", selection: $draft.accountID) {
                    ForEach(accounts) { Text("\($0.displayName.isEmpty ? $0.name : $0.displayName) <\($0.email)>").tag($0.id) }
                }
            }
            field("An", text: $draft.to)
            if showCc {
                field("Cc", text: $draft.cc)
                field("Bcc", text: $draft.bcc)
            } else {
                Button("Cc/Bcc anzeigen") { showCc = true }.buttonStyle(.link).font(.caption)
            }
            field("Betreff", text: $draft.subject)
            formatBar
            RichTextEditor(controller: editor, initialText: initialText, rich: rich)
                .frame(minHeight: 280)
                .padding(8)
                .background(CTW.surfaceSoft, in: RoundedRectangle(cornerRadius: CTW.radius))
                .overlay(RoundedRectangle(cornerRadius: CTW.radius).strokeBorder(CTW.line))
                .onAppear { editor.onChange = { draft.body = $0 } }

            if !draft.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(draft.attachments) { a in
                            HStack(spacing: 4) {
                                Image(systemName: "paperclip")
                                Text("\(a.name) · \(ByteCountFormatter.string(fromByteCount: Int64(a.data.count), countStyle: .file))").lineLimit(1)
                                Button { draft.attachments.removeAll { $0.id == a.id } } label: { Image(systemName: "xmark.circle.fill") }
                                    .buttonStyle(.borderless).accessibilityLabel("Anhang entfernen")
                            }
                            .font(.caption).padding(.horizontal, 8).padding(.vertical, 4)
                            .background(CTW.surfaceSoft, in: Capsule())
                        }
                    }
                }
                if attachmentBytes > 20_000_000 {
                    Label("Anhänge über 20 MB lehnen viele Mailserver ab.", systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(CTW.action)
                }
            }
            if let error { Label(error, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(CTW.action).textSelection(.enabled) }

            HStack {
                Button { addAttachments() } label: { Label("Anhang", systemImage: "paperclip") }.buttonStyle(.ctwSecondary)
                if working { ProgressView().controlSize(.small) }
                Spacer()
                Button("Abbrechen") { if hasContent && draft.body != savedBody { confirmDiscard = true } else { dismiss() } }
                    .buttonStyle(.ctwSecondary).keyboardShortcut(.cancelAction)
                Button { saveDraft() } label: { Label("Entwurf sichern", systemImage: "tray.and.arrow.down") }
                    .buttonStyle(.ctwSecondary).disabled(working || !hasContent)
                Button { send() } label: { Label("Senden", systemImage: "paperplane.fill") }
                    .buttonStyle(.ctwPrimary).keyboardShortcut(.return, modifiers: .command)
                    .disabled(working || draft.to.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text("Gesendet wird erst, wenn du auf „Senden“ klickst.").font(.caption).foregroundStyle(CTW.muted)
        }
        .padding(20)
        .frame(minWidth: 640, idealWidth: 700, minHeight: 560)
        .background(CTW.surface)
        .onChange(of: draft.accountID) { _, _ in swapSignature() }
        .alert("Link einfügen", isPresented: $askLink) {
            TextField("https://…", text: $linkText)
            Button("Übernehmen") { editor.setLink(linkText) }
            Button("Abbrechen", role: .cancel) {}
        } message: { Text("Der markierte Text wird zum Link. Leer lassen entfernt einen vorhandenen Link.") }
        .confirmationDialog("Nachricht verwerfen?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Entwurf sichern und schließen") { saveDraft(thenClose: true) }
            Button("Verwerfen", role: .destructive) { dismiss() }
            Button("Weiter schreiben", role: .cancel) {}
        }
    }

    /// Formatierung: fett, kursiv, unterstrichen, durchgestrichen, Link – oder reiner Text.
    private var formatBar: some View {
        HStack(spacing: 4) {
            Toggle(isOn: $rich) { Text("Formatiert") }.toggleStyle(.switch).controlSize(.mini)
                .help("Aus: reiner Text ohne Formatierung")
            if rich {
                Divider().frame(height: 16)
                formatButton("bold", "Fett (⌘B)", "b") { editor.toggleBold() }
                formatButton("italic", "Kursiv (⌘I)", "i") { editor.toggleItalic() }
                formatButton("underline", "Unterstrichen (⌘U)", "u") { editor.toggleUnderline() }
                formatButton("strikethrough", "Durchgestrichen", nil) { editor.toggleStrikethrough() }
                formatButton("link", "Link (⌘K)", "k") { linkText = ""; askLink = true }
            }
            Spacer()
        }
        .font(.caption)
    }

    private func formatButton(_ symbol: String, _ help: String, _ key: KeyEquivalent?, _ action: @escaping () -> Void) -> some View {
        let button = Button(action: action) { Image(systemName: symbol).frame(width: 22, height: 20) }
            .buttonStyle(.borderless).help(help).accessibilityLabel(help)
        return Group {
            if let key { button.keyboardShortcut(key, modifiers: .command) } else { button }
        }
    }

    /// Bei einem anderen Absenderkonto die Signatur austauschen.
    private func swapSignature() {
        let new = ClientModel.shared.account(draft.accountID)?.signature ?? ""
        if let e = Signature.edit(old: draft.appliedSignature, new: new, in: editor.string) { editor.replace(e.range, with: e.replacement) }
        draft.appliedSignature = new
    }

    /// Text und – falls formatiert – HTML aus dem Editor in den Entwurf übernehmen.
    private func syncFromEditor() {
        draft.body = editor.string
        draft.html = rich && HTMLExport.hasFormatting(editor.attributed) ? HTMLExport.html(from: editor.attributed) : nil
    }

    private func field(_ title: String, text: Binding<String>) -> some View {
        HStack(spacing: 8) {
            Text(title).frame(width: 52, alignment: .trailing).foregroundStyle(CTW.muted)
            TextField("", text: text).textFieldStyle(.roundedBorder)
        }
    }

    private func addAttachments() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let data = try? Data(contentsOf: url) else { error = "„\(url.lastPathComponent)“ konnte nicht gelesen werden."; continue }
            let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            draft.attachments.append(OutgoingAttachment(name: url.lastPathComponent, mime: mime, data: data))
        }
    }

    private func send() {
        working = true
        error = nil
        syncFromEditor()
        Task {
            error = await ClientModel.shared.send(draft)
            working = false
            if error == nil { dismiss() }
        }
    }

    private func saveDraft(thenClose: Bool = false) {
        working = true
        error = nil
        syncFromEditor()
        Task {
            var d = draft
            error = await ClientModel.shared.saveDraft(&d)
            draft.draftUID = d.draftUID
            savedBody = draft.body
            working = false
            if error == nil, thenClose { dismiss() }
        }
    }
}

// MARK: - .eml-Datei anzeigen

/// Zeigt eine geöffnete `.eml`-Datei (nur Lesen) mit Antworten und Weiterleiten.
struct EMLViewerSheet: View {
    @EnvironmentObject var engine: Engine
    @Environment(\.dismiss) private var dismiss
    let message: OpenedEML
    @ViewState private var allowRemote = false

    private var account: ClientAccount? {
        let model = ClientModel.shared
        return model.selectedFolder.flatMap { f in engine.settings.clientAccounts.first { $0.id.uuidString == f.account } } ?? engine.settings.clientAccounts.first
    }

    /// Eine Nachricht aus der Datei als Grundlage für Antwort und Weiterleitung (gehört zu keinem Server).
    private var synthetic: ClientMessage {
        let h = message.header
        return ClientMessage(account: "", folder: "", uid: 0, messageId: h.messageId, inReplyTo: h.inReplyTo, references: h.references, subject: h.subject,
                             senderName: h.fromName, senderEmail: h.fromEmail, recipients: h.to, date: h.date ?? Date(), flags: [], size: 0, preview: "", hasBody: true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Eyebrow(text: "Datei · \(message.fileName)")
                Text(message.header.subject.isEmpty ? "(kein Betreff)" : message.header.subject).font(.system(size: 20, weight: .bold)).foregroundStyle(CTW.ink).textSelection(.enabled)
                Text("Von: " + (message.header.fromName.isEmpty ? message.header.fromEmail : "\(message.header.fromName) <\(message.header.fromEmail)>")).textSelection(.enabled)
                if !message.header.to.isEmpty { Text("An: " + message.header.to.joined(separator: ", ")).font(.caption).foregroundStyle(CTW.muted).textSelection(.enabled) }
                if let d = message.header.date { Text(d.formatted(date: .long, time: .shortened)).font(.caption).foregroundStyle(CTW.muted) }
            }
            .padding(16)
            Divider()
            let files = message.parsed.attachments.filter { !($0.isInline && $0.mime.hasPrefix("image/") && $0.contentID != nil) }
            if !files.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(files) { a in
                            Button { save(a) } label: { Label("\(a.name) · \(ByteCountFormatter.string(fromByteCount: Int64(a.data.count), countStyle: .file))", systemImage: "paperclip") }
                                .buttonStyle(.ctwSecondary)
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 8)
                }
                Divider()
            }
            if let html = message.parsed.htmlWithInlineImages() {
                MailWebView(html: html, allowRemote: allowRemote)
            } else {
                ScrollView {
                    Text(message.parsed.text.isEmpty ? "(kein Text)" : message.parsed.text).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(20)
                }
            }
            Divider()
            HStack {
                if message.parsed.html != nil, !allowRemote { Button("Externe Inhalte laden") { allowRemote = true }.buttonStyle(.ctwSecondary) }
                Spacer()
                Button("Schließen") { dismiss() }.buttonStyle(.ctwSecondary).keyboardShortcut(.cancelAction)
                Button { start(forward: true) } label: { Label("Weiterleiten", systemImage: "arrowshape.turn.up.right") }.buttonStyle(.ctwSecondary).disabled(account == nil)
                Button { start(forward: false) } label: { Label("Antworten", systemImage: "arrowshape.turn.up.left") }.buttonStyle(.ctwPrimary).disabled(account == nil)
            }
            .padding(12)
        }
        .frame(minWidth: 680, idealWidth: 760, minHeight: 560, idealHeight: 680)
        .background(CTW.surface)
    }

    private func start(forward: Bool) {
        guard let account else { return }
        var draft = forward
            ? ComposeDraft.forward(synthetic, header: message.header, parsed: message.parsed, accountID: account.id)
            : ComposeDraft.reply(to: synthetic, header: message.header, parsed: message.parsed, accountID: account.id, ownEmail: account.email, all: false)
        draft.origin = nil
        ClientModel.shared.pendingCompose = draft
        engine.requestedSidebar = .mailbox
        dismiss()
    }

    private func save(_ a: MailAttachment) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = a.name
        if panel.runModal() == .OK, let url = panel.url { try? a.data.write(to: url) }
    }
}

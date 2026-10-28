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

    init(draft: ComposeDraft) {
        _draft = ViewState(initialValue: draft)
        _showCc = ViewState(initialValue: !draft.cc.isEmpty || !draft.bcc.isEmpty)
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
            TextEditor(text: $draft.body)
                .font(.body)
                .frame(minHeight: 280)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(CTW.surfaceSoft, in: RoundedRectangle(cornerRadius: CTW.radius))
                .overlay(RoundedRectangle(cornerRadius: CTW.radius).strokeBorder(CTW.line))

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
        .confirmationDialog("Nachricht verwerfen?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Entwurf sichern und schließen") { saveDraft(thenClose: true) }
            Button("Verwerfen", role: .destructive) { dismiss() }
            Button("Weiter schreiben", role: .cancel) {}
        }
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
        Task {
            error = await ClientModel.shared.send(draft)
            working = false
            if error == nil { dismiss() }
        }
    }

    private func saveDraft(thenClose: Bool = false) {
        working = true
        error = nil
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

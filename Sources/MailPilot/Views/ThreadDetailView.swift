import SwiftUI

struct ThreadDetailView: View {
    @EnvironmentObject var engine: Engine
    let thread: MailThread
    @ViewState private var draft = ""
    @ViewState private var hint = ""
    @ViewState private var working = false
    @ViewState private var messages: [StoredMessage] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                GroupBox("Stand") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(thread.summary.isEmpty ? "–" : thread.summary).textSelection(.enabled)
                        if !thread.nextStep.isEmpty {
                            Label(thread.nextStep, systemImage: "arrow.right.circle").foregroundStyle(.blue)
                        }
                        if let due = thread.dueDate {
                            Label("Frist: \(due)", systemImage: "calendar").foregroundStyle(.orange)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }

                GroupBox("Antwortentwurf") {
                    VStack(alignment: .leading, spacing: 8) {
                        TextEditor(text: $draft)
                            .font(.body)
                            .frame(minHeight: 160)
                            .scrollContentBackground(.hidden)
                            .background(.background, in: RoundedRectangle(cornerRadius: 6))
                        HStack {
                            TextField("Anweisung an Claude, z. B. „kürzer, Termin Dienstag vorschlagen“", text: $hint)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit(redraft)
                            Button(draft.isEmpty ? "Entwurf erstellen" : "Neu schreiben", action: redraft)
                                .disabled(working)
                        }
                        HStack {
                            if working { ProgressView().controlSize(.small) }
                            Spacer()
                            Button("Speichern") { engine.saveDraft(draft, for: thread) }
                                .disabled(draft == (thread.draft ?? ""))
                            Button("In Mail als Antwort öffnen") {
                                engine.saveDraft(draft, for: thread)
                                Task { await engine.openReply(for: thread, text: draft) }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(draft.isEmpty)
                        }
                        Text("Mail öffnet ein Antwortfenster – gesendet wird erst, wenn du auf Senden klickst.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(4)
                }

                GroupBox("Verlauf (\(messages.count))") {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(messages.reversed()) { m in
                            MessageRow(message: m)
                            if m.id != messages.first?.id { Divider() }
                        }
                    }
                }
            }
            .padding(20)
        }
        .onAppear {
            draft = thread.draft ?? ""
            messages = engine.messages(in: thread)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(thread.subject.isEmpty ? "(kein Betreff)" : thread.subject).font(.title2.bold()).textSelection(.enabled)
            HStack {
                Text(thread.counterpart).foregroundStyle(.secondary)
                Text("·").foregroundStyle(.secondary)
                Text("\(thread.messageCount) Nachrichten").foregroundStyle(.secondary)
                Spacer()
                Picker("Status", selection: Binding(get: { thread.status }, set: { engine.setStatus($0, for: thread) })) {
                    ForEach(ThreadStatus.allCases) { s in
                        Label(s.label, systemImage: s.symbol).tag(s)
                    }
                }
                .fixedSize()
                if thread.status != .done {
                    Button("Erledigt") { engine.setStatus(.done, for: thread) }
                }
            }
        }
    }

    private func redraft() {
        working = true
        Task {
            if let text = await engine.redraft(thread, hint: hint) {
                draft = text
                hint = ""
            }
            working = false
        }
    }
}

struct MessageRow: View {
    let message: StoredMessage
    @ViewState private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: message.isFromMe ? "arrow.up.right" : "arrow.down.left")
                    .foregroundStyle(message.isFromMe ? .green : .blue)
                Text(message.isFromMe ? "Ich" : message.senderName).fontWeight(.medium)
                Text(message.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(message.account) / \(message.mailbox)").font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                if let url = message.mailURL {
                    Button { NSWorkspace.shared.open(url) } label: { Image(systemName: "envelope.open") }
                        .buttonStyle(.borderless)
                        .help("In Mail öffnen")
                }
            }
            if let s = message.summary { Text(s).font(.callout) }
            if let e = message.error { Text(e).font(.caption).foregroundStyle(.red) }
            if expanded {
                Text(message.content).font(.caption).textSelection(.enabled).padding(.top, 4)
            }
            Button(expanded ? "Weniger" : "Volltext") { expanded.toggle() }
                .buttonStyle(.link).font(.caption)
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

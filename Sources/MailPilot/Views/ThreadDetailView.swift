import SwiftUI

struct ThreadDetailView: View {
    @EnvironmentObject var engine: Engine
    let thread: MailThread
    @ViewState private var draft = ""
    @ViewState private var hint = ""
    @ViewState private var working = false
    @ViewState private var messages: [StoredMessage] = []
    @ViewState private var ruleDraft: UserRule?

    private var sender: StoredMessage? { messages.last(where: { !$0.isFromMe }) }
    private var senderIsVIP: Bool { sender.map { engine.isVIP($0.senderEmail) } ?? false }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                VStack(alignment: .leading, spacing: 10) {
                    Eyebrow(text: "Stand", number: "01")
                    Text(thread.summary.isEmpty ? "–" : thread.summary)
                        .foregroundStyle(CTW.ink)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    if !thread.nextStep.isEmpty {
                        Label(thread.nextStep, systemImage: "arrow.right.circle.fill")
                            .foregroundStyle(CTW.accent)
                            .fontWeight(.medium)
                    }
                    if let due = thread.dueDate {
                        Label("Frist: \(due)", systemImage: "calendar").foregroundStyle(CTW.accent)
                    }
                }
                .ctwCard()

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Eyebrow(text: "Antwortentwurf", number: "02")
                        Spacer()
                        if working { ProgressView().controlSize(.small) }
                    }
                    TextEditor(text: $draft)
                        .font(.body)
                        .foregroundStyle(CTW.ink)
                        .frame(minHeight: 170)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .background(CTW.surfaceSoft, in: RoundedRectangle(cornerRadius: CTW.radius))
                        .overlay(RoundedRectangle(cornerRadius: CTW.radius).strokeBorder(CTW.line))
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles").foregroundStyle(CTW.accent)
                        TextField("Anweisung an Claude, z. B. „kürzer, Termin Dienstag vorschlagen“", text: $hint)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(redraft)
                        Button(action: redraft) {
                            Label(draft.isEmpty ? "Entwurf erstellen" : "Neu schreiben", systemImage: "wand.and.stars")
                        }
                        .buttonStyle(.ctwSecondary)
                        .disabled(working)
                    }
                    HStack(spacing: 8) {
                        Label("Gesendet wird erst, wenn du in Mail auf Senden klickst.", systemImage: "hand.raised.fill")
                            .font(.caption).foregroundStyle(CTW.muted)
                        Spacer()
                        Button { engine.saveDraft(draft, for: thread) } label: {
                            Label("Speichern", systemImage: "square.and.arrow.down")
                        }
                        .buttonStyle(.ctwSecondary)
                        .disabled(draft == (thread.draft ?? ""))
                        Button {
                            engine.saveDraft(draft, for: thread)
                            Task { await engine.openReply(for: thread, text: draft) }
                        } label: {
                            Label("In Mail öffnen", systemImage: "arrowshape.turn.up.left.fill")
                        }
                        .buttonStyle(.ctwPrimary)
                        .disabled(draft.isEmpty)
                    }
                }
                .ctwCard()

                VStack(alignment: .leading, spacing: 4) {
                    Eyebrow(text: "Verlauf · \(messages.count) Nachrichten", number: "03")
                        .padding(.bottom, 4)
                    ForEach(messages.reversed()) { m in
                        MessageRow(message: m)
                        if m.id != messages.first?.id { Divider().overlay(CTW.lineSoft) }
                    }
                }
                .ctwCard()
            }
            .padding(20)
        }
        .background(CTW.bg)
        .onAppear {
            draft = thread.draft ?? ""
            messages = engine.messages(in: thread)
        }
        .sheet(item: $ruleDraft) { RuleEditorSheet(rule: $0).environmentObject(engine) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Badge(text: thread.status.label, color: thread.status.color, symbol: thread.status.symbol)
                if senderIsVIP { Badge(text: "VIP", color: CTW.action, symbol: "star.fill") }
                if thread.priority == .high { Badge(text: "Wichtig", color: CTW.action, symbol: "exclamationmark.2") }
                if let cat = thread.category {
                    Badge(text: cat, color: CTW.grey500,
                          symbol: engine.settings.category(named: cat)?.symbolName ?? CategoryRule.guessSymbol(for: cat))
                }
            }
            Text(thread.subject.isEmpty ? "(kein Betreff)" : thread.subject)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(CTW.ink)
                .textSelection(.enabled)
            HStack(spacing: 10) {
                Label(thread.counterpart, systemImage: "person.crop.circle").foregroundStyle(CTW.muted)
                Label("\(thread.messageCount)", systemImage: "envelope").foregroundStyle(CTW.muted)
                Spacer()
                Menu {
                    ForEach(engine.settings.categories) { c in
                        Button { Task { await engine.changeCategory(of: thread, to: c.name) } } label: {
                            Label(c.name, systemImage: c.name == thread.category ? "checkmark" : c.symbolName)
                        }
                    }
                } label: {
                    Label("Kategorie", systemImage: "tag.fill")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Kategorie ändern – MailPilot sortiert die Mail um und merkt sich das")
                Menu {
                    if let s = sender {
                        Button { engine.toggleVIP(email: s.senderEmail, name: s.senderName) } label: {
                            Label(senderIsVIP ? "VIP entfernen" : "Absender als VIP markieren", systemImage: "star.fill")
                        }
                        Button { ruleDraft = ruleDraft(for: s) } label: {
                            Label("Regel für diesen Absender …", systemImage: "slider.horizontal.3")
                        }
                        Button { ruleDraft = ruleDraft(for: s, domain: true) } label: {
                            Label("Regel für die Domain …", systemImage: "globe")
                        }
                    }
                } label: {
                    Label("Absender", systemImage: "person.crop.circle.badge.checkmark")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(sender == nil)
                Menu {
                    ForEach(ThreadStatus.allCases) { s in
                        Button { engine.setStatus(s, for: thread) } label: { Label(s.label, systemImage: s.symbol) }
                    }
                } label: {
                    Label("Status", systemImage: "slider.horizontal.3")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                if thread.status != .done {
                    Button { engine.setStatus(.done, for: thread) } label: {
                        Label("Erledigt", systemImage: "checkmark")
                    }
                    .buttonStyle(.ctwSecondary)
                }
            }
            .font(.system(size: 12.5))
        }
    }

    private func ruleDraft(for m: StoredMessage, domain: Bool = false) -> UserRule {
        var r = UserRule()
        let d = RuleEngine.domain(of: m.senderEmail)
        r.name = domain ? "Domain \(d)" : "Absender \(m.senderEmail)"
        r.conditions = [RuleCondition(field: domain ? .domain : .sender, value: domain ? d : m.senderEmail)]
        r.category = thread.category
        return r
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
            HStack(spacing: 8) {
                IconTile(symbol: message.isFromMe ? "arrow.up.right" : "arrow.down.left",
                         color: message.isFromMe ? CTW.teal700 : CTW.accent, size: 22)
                    .accessibilityLabel(message.isFromMe ? "Gesendet" : "Empfangen")
                Text(message.isFromMe ? "Ich" : message.senderName).fontWeight(.semibold).foregroundStyle(CTW.ink)
                if let d = message.decidedBy, d != "Claude" {
                    Badge(text: d, color: CTW.accent, symbol: d == "VIP" ? "star.fill" : (d == "Korrektur" ? "graduationcap.fill" : "slider.horizontal.3"))
                }
                Text(message.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(CTW.muted)
                Spacer()
                Label("\(message.account) / \(message.mailbox)", systemImage: "folder")
                    .font(.caption2).foregroundStyle(CTW.muted).lineLimit(1)
                if let url = message.mailURL {
                    Button { NSWorkspace.shared.open(url) } label: { Image(systemName: "envelope.open.fill") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(CTW.accent)
                        .help("In Mail öffnen")
                }
            }
            if let s = message.summary { Text(s).font(.callout).foregroundStyle(CTW.ink).padding(.leading, 30) }
            if let e = message.error {
                Label(e, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(CTW.action).padding(.leading, 30)
            }
            if expanded {
                Text(message.content).font(.caption).foregroundStyle(CTW.ink).textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(CTW.surfaceSoft, in: RoundedRectangle(cornerRadius: CTW.radius))
                    .padding(.leading, 30)
            }
            Button(expanded ? "Weniger" : "Volltext") {
                withAnimation(CTW.base) { expanded.toggle() }
            }
            .buttonStyle(.link).font(.caption).padding(.leading, 30)
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

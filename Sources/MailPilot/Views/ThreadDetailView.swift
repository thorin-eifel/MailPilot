import SwiftUI

struct ThreadDetailView: View {
    @EnvironmentObject var engine: Engine
    let thread: MailThread
    @ViewState private var draft = ""
    @ViewState private var hint = ""
    @ViewState private var working = false
    @ViewState private var messages: [StoredMessage] = []
    @ViewState private var ruleDraft: UserRule?
    @ViewState private var showSnoozePicker = false
    @ViewState private var showDuePicker = false
    @ViewState private var confirmExclude = false

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
                    HStack(spacing: 8) {
                        if let due = thread.dueDate {
                            Label("Frist: \(Deadlines.parse(due).map { $0.formatted(date: .complete, time: .omitted) } ?? due)",
                                  systemImage: "calendar")
                                .foregroundStyle(CTW.accent)
                        } else {
                            Label("Keine Frist", systemImage: "calendar").foregroundStyle(CTW.muted)
                        }
                        Menu {
                            if thread.dueDate != nil {
                                Button { Task { await engine.exportDeadline(thread, kind: .reminder) } } label: {
                                    Label("In Erinnerungen eintragen", systemImage: "checklist")
                                }
                                Button { Task { await engine.exportDeadline(thread, kind: .calendar) } } label: {
                                    Label("In Kalender eintragen", systemImage: "calendar.badge.plus")
                                }
                                Divider()
                            }
                            Button { showDuePicker = true } label: {
                                Label(thread.dueDate == nil ? "Frist setzen …" : "Frist ändern …", systemImage: "calendar.badge.clock")
                            }
                            if thread.dueDate != nil {
                                Button(role: .destructive) { engine.setDueDate(thread, to: nil) } label: {
                                    Label("Frist entfernen", systemImage: "xmark.circle")
                                }
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .help("Frist in Erinnerungen oder Kalender eintragen, ändern oder entfernen")
                    }
                }
                .ctwCard()

                if thread.isPrivate {
                    HStack(alignment: .top, spacing: 12) {
                        IconTile(symbol: "lock.shield.fill", color: CTW.accent, size: 34)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Vertraulich – nicht an Claude gesendet").fontWeight(.semibold).foregroundStyle(CTW.ink)
                            Text("Für dieses Gespräch gilt eine Datenschutz-Ausnahme: Inhalt, Betreff und Absender gehen nie an Claude. Es gibt keine Zusammenfassung, keinen Entwurf und keine Frist. Antworten kannst du direkt in Mail.")
                                .font(.callout).foregroundStyle(CTW.muted)
                        }
                    }
                    .ctwCard()
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Eyebrow(text: thread.isFollowUpCase ? "Nachfass-Entwurf" : "Antwortentwurf", number: "02")
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
                                .onSubmit { redraft() }
                            if !thread.isFollowUpCase {
                                Button { redraft(slots: true) } label: {
                                    Label("Zeiten vorschlagen", systemImage: "calendar.badge.clock")
                                }
                                .buttonStyle(.ctwSecondary)
                                .disabled(working || !CalendarAvailability.shared.isAuthorized || !engine.settings.useFreeSlots)
                                .help(CalendarAvailability.shared.isAuthorized
                                      ? "Schreibt den Entwurf neu und schlägt dabei freie Zeiten aus deinem Kalender vor"
                                      : "Dafür braucht MailPilot Zugriff auf den Kalender (Einstellungen → Kalender & freie Zeiten)")
                            }
                            Button { redraft() } label: {
                                Label(draft.isEmpty ? (thread.isFollowUpCase ? "Nachfass-Entwurf erstellen" : "Entwurf erstellen") : "Neu schreiben",
                                      systemImage: "wand.and.stars")
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
                                Task { await engine.openReply(for: thread, text: draft, save: true) }
                            } label: {
                                Label("In Entwürfe legen", systemImage: "tray.and.arrow.down")
                            }
                            .buttonStyle(.ctwSecondary)
                            .disabled(draft.isEmpty)
                            .help("Legt den Entwurf im Ordner „Entwürfe“ des Mail-Kontos ab – ohne Fenster. Gesendet wird nichts.")
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
                }

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
        .confirmationDialog("Absender von Claude ausschließen?", isPresented: $confirmExclude, titleVisibility: .visible) {
            Button("Ausschließen und Inhalte entfernen", role: .destructive) {
                if let s = sender { engine.excludeSender(s.senderEmail, name: s.senderName) }
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Mails von und an \(sender?.senderEmail ?? "") gehen künftig nie mehr an Claude. Bereits gespeicherte Mailtexte und Zusammenfassungen dieses Absenders werden von diesem Rechner gelöscht.")
        }
        .sheet(isPresented: $showDuePicker) {
            DueDatePickerSheet(initial: Deadlines.parse(thread.dueDate)) { engine.setDueDate(thread, to: $0) }
        }
        .sheet(isPresented: $showSnoozePicker) {
            SnoozePickerSheet { date in engine.snooze(thread, until: date) }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Badge(text: thread.status.label, color: thread.status.color, symbol: thread.status.symbol)
                if thread.isPrivate { Badge(text: "Vertraulich", color: CTW.teal700, symbol: "lock.shield.fill") }
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
                    ForEach(SnoozeOption.allCases) { o in
                        if let date = o.date(from: Date()) {
                            Button { engine.snooze(thread, until: date) } label: {
                                Label("\(o.label) · \(date.formatted(date: .abbreviated, time: .shortened))", systemImage: o.symbol)
                            }
                        }
                    }
                    Button { showSnoozePicker = true } label: { Label("Datum und Uhrzeit …", systemImage: "calendar.badge.plus") }
                    if thread.isSnoozed {
                        Divider()
                        Button { engine.snooze(thread, until: nil) } label: { Label("Zurückstellung aufheben", systemImage: "bell.fill") }
                    }
                } label: {
                    Label(thread.isSnoozed ? "Zurückgestellt" : "Zurückstellen", systemImage: "moon.zzz.fill")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Gespräch ausblenden und zu einem späteren Zeitpunkt wieder zeigen")
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
                        Divider()
                        Button { confirmExclude = true } label: {
                            Label("Von Claude ausschließen …", systemImage: "lock.shield")
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

    private func redraft(slots: Bool = false) {
        working = true
        Task {
            if let text = await engine.redraft(thread, hint: hint, forceSlots: slots) {
                draft = text
                hint = ""
            }
            working = false
        }
    }
}

struct MessageRow: View {
    @EnvironmentObject var engine: Engine
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
                PlanMenu(subject: message.subject, sender: message.senderName, date: message.date, messageId: message.messageId,
                         ownClient: engine.isClientAccount(message.account))
                if message.mailURL != nil {
                    Button { engine.openMessage(messageId: message.messageId) } label: { Image(systemName: "envelope.open.fill") }
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

/// Eigenes Datum und eigene Uhrzeit für „Zurückstellen“.
struct SnoozePickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ViewState private var date: Date
    let onPick: (Date) -> Void

    init(onPick: @escaping (Date) -> Void) {
        self.onPick = onPick
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        _date = ViewState(initialValue: Calendar.current.date(bySettingHour: 8, minute: 0, second: 0, of: tomorrow) ?? tomorrow)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Eyebrow(text: "Zurückstellen bis")
            DatePicker("", selection: $date, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                .datePickerStyle(.graphical)
                .labelsHidden()
            HStack {
                Spacer()
                Button("Abbrechen") { dismiss() }.buttonStyle(.ctwSecondary).keyboardShortcut(.cancelAction)
                Button {
                    onPick(date)
                    dismiss()
                } label: { Label("Zurückstellen", systemImage: "moon.zzz.fill") }
                    .buttonStyle(.ctwPrimary)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 340)
        .background(CTW.surface)
    }
}

/// Frist (nur Datum) setzen oder ändern.
struct DueDatePickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ViewState private var date: Date
    let onPick: (Date) -> Void

    init(initial: Date?, onPick: @escaping (Date) -> Void) {
        self.onPick = onPick
        _date = ViewState(initialValue: initial ?? Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Eyebrow(text: "Frist")
            DatePicker("", selection: $date, displayedComponents: [.date])
                .datePickerStyle(.graphical)
                .labelsHidden()
            HStack {
                Spacer()
                Button("Abbrechen") { dismiss() }.buttonStyle(.ctwSecondary).keyboardShortcut(.cancelAction)
                Button {
                    onPick(date)
                    dismiss()
                } label: { Label("Übernehmen", systemImage: "checkmark") }
                    .buttonStyle(.ctwPrimary)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 340)
        .background(CTW.surface)
    }
}

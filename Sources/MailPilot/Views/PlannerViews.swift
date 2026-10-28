import EventKit
import SwiftUI

// MARK: - Zugriff

/// Hinweis mit Knopf, solange Kalender oder Erinnerungen nicht freigegeben sind.
private struct AccessCard: View {
    let what: String
    let status: EKAuthorizationStatus
    let settingsPane: String
    let request: () async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("\(what): \(Planner.statusText(status, what: what))", systemImage: "lock.fill").foregroundStyle(CTW.ink)
            if status == .notDetermined {
                Button { Task { await request() } } label: { Label("Zugriff erlauben", systemImage: "checkmark.shield") }.buttonStyle(.ctwPrimary)
            } else {
                Button {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(settingsPane)") { NSWorkspace.shared.open(url) }
                } label: { Label("Systemeinstellungen öffnen", systemImage: "gearshape") }.buttonStyle(.ctwSecondary)
            }
        }
        .ctwCard()
    }
}

private func dot(_ hex: UInt32) -> some View {
    Circle().fill(Color(hex: hex)).frame(width: 9, height: 9).accessibilityHidden(true)
}

// MARK: - Kalender

enum CalendarMode: String, CaseIterable, Identifiable {
    case week, month
    var id: String { rawValue }
    var label: String { self == .week ? "Woche" : "Monat" }
}

struct CalendarView: View {
    @EnvironmentObject var engine: Engine
    @ObservedObject private var planner = Planner.shared
    @ViewState private var mode: CalendarMode = .week
    @ViewState private var anchor = Date()
    @ViewState private var editing: EventEditorModel?
    @AppStorage("planner.hiddenCalendars") private var hiddenRaw = ""

    private let cal = Calendar.current

    private var hidden: Set<String> { Set(hiddenRaw.split(separator: ",").map(String.init)) }

    private var days: [Date] {
        switch mode {
        case .week: PlannerLogic.days(from: PlannerLogic.weekStart(of: anchor, calendar: cal), count: 7, calendar: cal)
        case .month: PlannerLogic.monthGrid(for: anchor, calendar: cal)
        }
    }

    private var range: DateInterval {
        let first = days.first ?? anchor
        let last = cal.date(byAdding: .day, value: 1, to: days.last ?? anchor) ?? anchor
        return DateInterval(start: first, end: last)
    }

    private var visible: [PlannerEvent] { planner.events.filter { !hidden.contains($0.calendarID) } }

    private var title: String {
        if mode == .month { return anchor.formatted(.dateTime.month(.wide).year()) }
        guard let a = days.first, let b = days.last else { return "" }
        return "\(a.formatted(.dateTime.day().month(.abbreviated))) – \(b.formatted(.dateTime.day().month(.abbreviated).year()))"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if !planner.eventsAllowed {
                    AccessCard(what: "Kalender", status: planner.eventStatus, settingsPane: "Privacy_Calendars") { await planner.requestEvents() }
                } else {
                    if mode == .week { weekGrid } else { monthGrid }
                }
                if let e = planner.error { Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(CTW.action) }
            }
            .padding(24)
        }
        .task(id: "\(mode.rawValue)|\(range.start.timeIntervalSince1970)") { await planner.load(range: range) }
        .sheet(item: $editing) { model in EventEditor(model: model) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    Eyebrow(text: "Planen")
                    Text("Kalender").font(.system(size: 28, weight: .bold)).foregroundStyle(CTW.ink)
                    Text(title).foregroundStyle(CTW.muted)
                }
                Spacer()
                Button { newEvent(on: Date()) } label: { Label("Neuer Termin", systemImage: "plus") }
                    .buttonStyle(.ctwPrimary).disabled(!planner.eventsAllowed)
            }
            HStack(spacing: 8) {
                Button { step(-1) } label: { Image(systemName: "chevron.left") }.buttonStyle(.ctwSecondary).accessibilityLabel("Zurück")
                Button("Heute") { anchor = Date() }.buttonStyle(.ctwSecondary)
                Button { step(1) } label: { Image(systemName: "chevron.right") }.buttonStyle(.ctwSecondary).accessibilityLabel("Weiter")
                Picker("", selection: $mode) { ForEach(CalendarMode.allCases) { Text($0.label).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 160)
                Spacer()
                Menu {
                    ForEach(planner.calendars) { c in
                        Toggle(isOn: Binding(get: { !hidden.contains(c.id) }, set: { setHidden(c.id, !$0) })) { Text("\(c.title) (\(c.source))") }
                    }
                } label: { Label("Kalender", systemImage: "calendar") }
                    .menuStyle(.borderlessButton).fixedSize().disabled(planner.calendars.isEmpty)
            }
        }
    }

    private func step(_ n: Int) {
        anchor = cal.date(byAdding: mode == .week ? .weekOfYear : .month, value: n, to: anchor) ?? anchor
    }

    private func setHidden(_ id: String, _ hide: Bool) {
        var s = hidden
        if hide { s.insert(id) } else { s.remove(id) }
        hiddenRaw = s.sorted().joined(separator: ",")
    }

    private func newEvent(on day: Date) {
        let start = cal.date(bySettingHour: 9, minute: 0, second: 0, of: day) ?? day
        editing = EventEditorModel(input: .init(eventID: nil, calendarID: planner.defaultCalendarID, title: "", start: start,
                                                end: start.addingTimeInterval(3600), allDay: false, location: "", notes: "", url: nil), existing: nil)
    }

    private func edit(_ e: PlannerEvent) {
        guard var input = planner.eventInput(for: e) else { return }
        // Bei wiederkehrenden Terminen gilt der angeklickte Termin; Zeiten kommen vom Vorkommen.
        input.start = e.start
        input.end = e.end
        editing = EventEditorModel(input: input, existing: e)
    }

    // MARK: Raster

    private var weekGrid: some View {
        HStack(alignment: .top, spacing: 8) {
            ForEach(days, id: \.self) { day in
                VStack(alignment: .leading, spacing: 6) {
                    dayHeader(day)
                    ForEach(PlannerLogic.events(on: day, in: visible, calendar: cal)) { e in chip(e, on: day) }
                    Spacer(minLength: 0)
                }
                .padding(8)
                .frame(maxWidth: .infinity, minHeight: 360, alignment: .topLeading)
                .background(cal.isDateInToday(day) ? CTW.accent.opacity(0.07) : CTW.surface, in: RoundedRectangle(cornerRadius: CTW.radius))
                .overlay(RoundedRectangle(cornerRadius: CTW.radius).strokeBorder(CTW.lineSoft))
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { newEvent(on: day) }
            }
        }
    }

    private var monthGrid: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                ForEach(Array(days.prefix(7)), id: \.self) { d in
                    Text(d.formatted(.dateTime.weekday(.abbreviated))).font(.caption.weight(.semibold)).foregroundStyle(CTW.muted).frame(maxWidth: .infinity)
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7), spacing: 6) {
                ForEach(days, id: \.self) { day in
                    let items = PlannerLogic.events(on: day, in: visible, calendar: cal)
                    let inMonth = cal.isDate(day, equalTo: anchor, toGranularity: .month)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(cal.component(.day, from: day))")
                            .font(.system(size: 12, weight: cal.isDateInToday(day) ? .bold : .regular))
                            .foregroundStyle(cal.isDateInToday(day) ? CTW.action : (inMonth ? CTW.ink : CTW.muted.opacity(0.6)))
                        ForEach(items.prefix(3)) { e in chip(e, on: day, compact: true) }
                        if items.count > 3 {
                            Button("+\(items.count - 3) weitere") { anchor = day; mode = .week }.buttonStyle(.link).font(.caption2)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(6)
                    .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
                    .background(cal.isDateInToday(day) ? CTW.accent.opacity(0.07) : CTW.surface, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(CTW.lineSoft))
                    .opacity(inMonth ? 1 : 0.65)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { newEvent(on: day) }
                }
            }
        }
    }

    private func dayHeader(_ day: Date) -> some View {
        HStack(spacing: 4) {
            Text(day.formatted(.dateTime.weekday(.abbreviated))).font(.caption.weight(.semibold)).foregroundStyle(CTW.muted)
            Text("\(cal.component(.day, from: day))")
                .font(.system(size: 15, weight: .bold)).foregroundStyle(cal.isDateInToday(day) ? CTW.action : CTW.ink)
            Spacer()
        }
    }

    private func chip(_ e: PlannerEvent, on day: Date, compact: Bool = false) -> some View {
        Button { edit(e) } label: {
            HStack(alignment: .top, spacing: 5) {
                RoundedRectangle(cornerRadius: 1.5).fill(Color(hex: e.colorHex)).frame(width: 3)
                VStack(alignment: .leading, spacing: 1) {
                    Text(timeText(e, on: day)).font(.system(size: 10)).foregroundStyle(CTW.muted).lineLimit(1)
                    Text(e.title).font(.system(size: compact ? 11 : 12, weight: .medium)).foregroundStyle(CTW.ink).lineLimit(compact ? 1 : 3)
                    if !compact, !e.location.isEmpty { Text(e.location).font(.system(size: 10)).foregroundStyle(CTW.muted).lineLimit(1) }
                }
                Spacer(minLength: 0)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(4)
            .background(Color(hex: e.colorHex, opacity: 0.12), in: RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(e.title) · \(e.calendarTitle)")
    }

    private func timeText(_ e: PlannerEvent, on day: Date) -> String {
        if e.allDay { return "ganztägig" }
        let startsToday = cal.isDate(e.start, inSameDayAs: day)
        let endsToday = cal.isDate(e.end, inSameDayAs: day)
        let s = e.start.formatted(.dateTime.hour().minute()), f = e.end.formatted(.dateTime.hour().minute())
        if startsToday && endsToday { return "\(s)–\(f)" }
        return startsToday ? "ab \(s)" : (endsToday ? "bis \(f)" : "ganztägig")
    }
}

// MARK: - Termin bearbeiten

@MainActor
struct EventEditorModel: Identifiable {
    let id = UUID()
    var input: Planner.EventInput
    var existing: PlannerEvent?
}

private struct EventEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var planner = Planner.shared
    @ViewState private var input: Planner.EventInput
    let existing: PlannerEvent?
    @ViewState private var confirmDelete = false

    init(model: EventEditorModel) {
        _input = ViewState(initialValue: model.input)
        existing = model.existing
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Eyebrow(text: existing == nil ? "Neuer Termin" : "Termin bearbeiten")
            Form {
                TextField("Titel", text: $input.title)
                Toggle("Ganztägig", isOn: $input.allDay)
                if input.allDay {
                    DatePicker("Von", selection: $input.start, displayedComponents: .date)
                    DatePicker("Bis", selection: $input.end, in: input.start..., displayedComponents: .date)
                } else {
                    DatePicker("Beginn", selection: $input.start)
                    DatePicker("Ende", selection: $input.end, in: input.start...)
                }
                TextField("Ort", text: $input.location)
                Picker("Kalender", selection: $input.calendarID) {
                    ForEach(planner.calendars.filter(\.writable)) { Text("\($0.title) (\($0.source))").tag($0.id) }
                }
                TextField("Notizen", text: $input.notes, axis: .vertical).lineLimit(3...8)
                if let url = input.url, let id = PlannerDraft.messageId(fromLink: url) {
                    Button { Engine.shared.openMessage(messageId: id); dismiss() } label: { Label("Zugehörige Mail öffnen", systemImage: "envelope.open") }
                        .buttonStyle(.link)
                } else if let url = input.url {
                    Link(destination: url) { Label("Verknüpfung öffnen", systemImage: "link") }
                }
            }
            .formStyle(.grouped).scrollContentBackground(.hidden)
            HStack {
                if existing != nil {
                    Button(role: .destructive) { confirmDelete = true } label: { Label("Löschen", systemImage: "trash") }.buttonStyle(.ctwSecondary)
                }
                Spacer()
                Button("Abbrechen") { dismiss() }.buttonStyle(.ctwSecondary).keyboardShortcut(.cancelAction)
                Button {
                    Task { if await planner.saveEvent(input) { dismiss() } }
                } label: { Label("Sichern", systemImage: "checkmark") }
                    .buttonStyle(.ctwPrimary).keyboardShortcut(.defaultAction)
                    .disabled(input.title.trimmingCharacters(in: .whitespaces).isEmpty || input.calendarID.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 500)
        .background(CTW.surface)
        .confirmationDialog("Termin löschen?", isPresented: $confirmDelete) {
            Button("Löschen", role: .destructive) {
                if let existing { Task { await planner.deleteEvent(existing); dismiss() } }
            }
        } message: {
            Text("Bei wiederkehrenden Terminen wird nur dieser Termin gelöscht.")
        }
    }
}

// MARK: - Erinnerungen

struct RemindersView: View {
    @EnvironmentObject var engine: Engine
    @ObservedObject private var planner = Planner.shared
    @ViewState private var listFilter = ""
    @ViewState private var showDone = false
    @ViewState private var quick = ""
    @ViewState private var editing: Planner.ReminderInput?

    private var shown: [PlannerReminder] { planner.reminders.filter { listFilter.isEmpty || $0.listID == listFilter } }

    private var parsed: QuickAdd.Result? {
        let t = quick.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : QuickAdd.parse(t)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        Eyebrow(text: "Planen")
                        Text("Erinnerungen").font(.system(size: 28, weight: .bold)).foregroundStyle(CTW.ink)
                        Text("\(shown.filter { !$0.completed }.count) offen").foregroundStyle(CTW.muted)
                    }
                    Spacer()
                    Menu {
                        Button("Alle Listen") { listFilter = "" }
                        Divider()
                        ForEach(planner.reminderLists) { l in Button("\(l.title) (\(l.source))") { listFilter = l.id } }
                    } label: {
                        Label(planner.reminderLists.first { $0.id == listFilter }?.title ?? "Alle Listen", systemImage: "list.bullet")
                    }
                    .menuStyle(.borderlessButton).fixedSize().disabled(planner.reminderLists.isEmpty)
                    Toggle("Erledigte", isOn: $showDone).toggleStyle(.checkbox)
                }
                if !planner.remindersAllowed {
                    AccessCard(what: "Erinnerungen", status: planner.reminderStatus, settingsPane: "Privacy_Reminders") { await planner.requestReminders() }
                } else {
                    quickAdd
                    let groups = PlannerLogic.grouped(shown, showDone: showDone)
                    if groups.isEmpty {
                        ContentUnavailableView("Keine Erinnerungen", systemImage: "checklist",
                                               description: Text("Schreibe oben, was zu tun ist – etwa „Steuerberater anrufen morgen 14 Uhr“."))
                            .foregroundStyle(CTW.muted).ctwCard(padding: 24)
                    }
                    ForEach(groups, id: \.0) { group, items in
                        VStack(alignment: .leading, spacing: 0) {
                            Eyebrow(text: group.label).padding(.bottom, 6)
                            VStack(spacing: 0) {
                                ForEach(items) { r in
                                    row(r)
                                    if r.id != items.last?.id { Divider() }
                                }
                            }
                            .ctwCard(padding: 4)
                        }
                    }
                }
                if let e = planner.error { Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(CTW.action) }
            }
            .padding(24)
        }
        .task { await planner.reload() }
        .sheet(item: Binding(get: { editing.map { ReminderEditorModel(input: $0) } }, set: { if $0 == nil { editing = nil } })) { model in
            ReminderEditor(model: model)
        }
    }

    private var quickAdd: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "plus.circle.fill").foregroundStyle(CTW.accent)
                TextField("Neue Erinnerung – z. B. „Miete überweisen am 3.11.“", text: $quick)
                    .textFieldStyle(.plain).onSubmit(add)
                Button("Hinzufügen", action: add).buttonStyle(.ctwSecondary).disabled(parsed == nil)
            }
            .padding(10)
            .background(CTW.surface, in: RoundedRectangle(cornerRadius: CTW.radius))
            .overlay(RoundedRectangle(cornerRadius: CTW.radius).strokeBorder(CTW.line))
            if let p = parsed {
                let preview = PlannerReminder(id: "", listID: "", listTitle: "", colorHex: 0, title: p.title, notes: "", due: p.date, hasTime: p.hasTime,
                                              completed: false, priority: 0, url: nil)
                Text(p.date == nil ? "„\(p.title)“ ohne Datum" : "„\(p.title)“ · fällig \(PlannerLogic.dueText(preview))")
                    .font(.caption).foregroundStyle(CTW.muted)
            }
        }
    }

    private func add() {
        guard let p = parsed else { return }
        let list = listFilter.isEmpty ? planner.defaultListID : listFilter
        Task {
            if await planner.saveReminder(.init(id: nil, listID: list, title: p.title, notes: "", due: p.date, hasTime: p.hasTime, priority: 0, url: nil)) { quick = "" }
        }
    }

    private func row(_ r: PlannerReminder) -> some View {
        let overdue = PlannerLogic.group(r) == .overdue
        return HStack(alignment: .top, spacing: 10) {
            Button { Task { await planner.setCompleted(r, !r.completed) } } label: {
                Image(systemName: r.completed ? "checkmark.circle.fill" : "circle").font(.system(size: 18)).foregroundStyle(r.completed ? CTW.teal700 : CTW.muted)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(r.completed ? "Als offen markieren" : "Als erledigt markieren")
            VStack(alignment: .leading, spacing: 2) {
                Text(r.title).foregroundStyle(r.completed ? CTW.muted : CTW.ink).strikethrough(r.completed)
                HStack(spacing: 8) {
                    if r.due != nil {
                        Label(PlannerLogic.dueText(r), systemImage: "clock").font(.caption).foregroundStyle(overdue ? CTW.action : CTW.muted)
                    }
                    HStack(spacing: 4) { dot(r.colorHex); Text(r.listTitle).font(.caption).foregroundStyle(CTW.muted) }
                    if let url = r.url, let id = PlannerDraft.messageId(fromLink: url) {
                        Button { engine.openMessage(messageId: id) } label: { Label("Mail", systemImage: "envelope.open") }
                            .buttonStyle(.link).font(.caption)
                    }
                }
            }
            Spacer()
            Button { editing = planner.reminderInput(for: r) } label: { Image(systemName: "pencil") }
                .buttonStyle(.borderless).help("Bearbeiten").accessibilityLabel("Bearbeiten")
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}

struct ReminderEditorModel: Identifiable {
    var id: String { input.id ?? "neu" }
    var input: Planner.ReminderInput
}

private struct ReminderEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var planner = Planner.shared
    @ViewState private var input: Planner.ReminderInput
    @ViewState private var hasDate: Bool
    @ViewState private var confirmDelete = false

    init(model: ReminderEditorModel) {
        _input = ViewState(initialValue: model.input)
        _hasDate = ViewState(initialValue: model.input.due != nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Eyebrow(text: "Erinnerung bearbeiten")
            Form {
                TextField("Titel", text: $input.title)
                Toggle("Fälligkeit", isOn: $hasDate)
                if hasDate {
                    Toggle("Mit Uhrzeit", isOn: $input.hasTime)
                    DatePicker("Fällig", selection: Binding(get: { input.due ?? PlannerDraft.defaultDate() }, set: { input.due = $0 }),
                               displayedComponents: input.hasTime ? [.date, .hourAndMinute] : .date)
                }
                Picker("Liste", selection: $input.listID) {
                    ForEach(planner.reminderLists.filter(\.writable)) { Text("\($0.title) (\($0.source))").tag($0.id) }
                }
                Picker("Priorität", selection: $input.priority) {
                    Text("Keine").tag(0)
                    Text("Hoch").tag(1)
                    Text("Mittel").tag(5)
                    Text("Niedrig").tag(9)
                }
                TextField("Notizen", text: $input.notes, axis: .vertical).lineLimit(3...8)
            }
            .formStyle(.grouped).scrollContentBackground(.hidden)
            HStack {
                Button(role: .destructive) { confirmDelete = true } label: { Label("Löschen", systemImage: "trash") }.buttonStyle(.ctwSecondary)
                Spacer()
                Button("Abbrechen") { dismiss() }.buttonStyle(.ctwSecondary).keyboardShortcut(.cancelAction)
                Button {
                    var i = input
                    if hasDate { i.due = i.due ?? PlannerDraft.defaultDate() } else { i.due = nil; i.hasTime = false }
                    Task { if await planner.saveReminder(i) { dismiss() } }
                } label: { Label("Sichern", systemImage: "checkmark") }
                    .buttonStyle(.ctwPrimary).keyboardShortcut(.defaultAction)
                    .disabled(input.title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
        .background(CTW.surface)
        .confirmationDialog("Erinnerung löschen?", isPresented: $confirmDelete) {
            Button("Löschen", role: .destructive) {
                if let id = input.id, let r = planner.reminders.first(where: { $0.id == id }) { Task { await planner.deleteReminder(r); dismiss() } }
            }
        }
    }
}

// MARK: - Aus einer Mail

/// „Termin oder Erinnerung aus dieser Mail“ – wird vom Dashboard gezeigt, sobald `Planner.draft` gesetzt ist.
struct PlannerDraftSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var planner = Planner.shared
    @ViewState private var draft: PlannerDraft
    @ViewState private var allDay = false
    @ViewState private var saving = false

    init(draft: PlannerDraft) {
        _draft = ViewState(initialValue: draft)
    }

    private var allowed: Bool { draft.kind == .event ? planner.eventsAllowed : planner.remindersAllowed }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Eyebrow(text: "Aus dieser Mail")
            Picker("", selection: $draft.kind) { ForEach(PlannerDraft.Kind.allCases) { Text($0.label).tag($0) } }
                .pickerStyle(.segmented).labelsHidden()
            if !allowed {
                Label(draft.kind == .event ? "Der Kalender ist noch nicht freigegeben." : "Die Erinnerungen sind noch nicht freigegeben.", systemImage: "lock.fill")
                    .foregroundStyle(CTW.ink)
                Button {
                    Task { if draft.kind == .event { await planner.requestEvents() } else { await planner.requestReminders() } }
                } label: { Label("Zugriff erlauben", systemImage: "checkmark.shield") }.buttonStyle(.ctwPrimary)
            } else {
                Form {
                    TextField("Titel", text: $draft.title)
                    if draft.kind == .event {
                        Toggle("Ganztägig", isOn: $allDay)
                        DatePicker("Beginn", selection: $draft.date, displayedComponents: allDay ? .date : [.date, .hourAndMinute])
                        Picker("Kalender", selection: $draft.listOrCalendarID) {
                            ForEach(planner.calendars.filter(\.writable)) { Text("\($0.title) (\($0.source))").tag($0.id) }
                        }
                    } else {
                        Toggle("Mit Uhrzeit", isOn: $draft.hasTime)
                        DatePicker("Fällig", selection: $draft.date, displayedComponents: draft.hasTime ? [.date, .hourAndMinute] : .date)
                        Picker("Liste", selection: $draft.listOrCalendarID) {
                            ForEach(planner.reminderLists.filter(\.writable)) { Text("\($0.title) (\($0.source))").tag($0.id) }
                        }
                    }
                    TextField("Notizen", text: $draft.notes, axis: .vertical).lineLimit(3...8)
                }
                .formStyle(.grouped).scrollContentBackground(.hidden)
                Text("Der Eintrag enthält einen Verweis, mit dem sich diese Mail aus Kalender oder Erinnerungen wieder öffnen lässt.")
                    .font(.caption).foregroundStyle(CTW.muted)
            }
            if let e = planner.error { Label(e, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(CTW.action) }
            HStack {
                Spacer()
                Button("Abbrechen") { planner.draft = nil; dismiss() }.buttonStyle(.ctwSecondary).keyboardShortcut(.cancelAction)
                Button { save() } label: { Label("Anlegen", systemImage: "checkmark") }
                    .buttonStyle(.ctwPrimary).keyboardShortcut(.defaultAction)
                    .disabled(!allowed || saving || draft.title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 500)
        .background(CTW.surface)
        .task {
            await planner.reload()
            if draft.listOrCalendarID.isEmpty { draft.listOrCalendarID = draft.kind == .event ? planner.defaultCalendarID : planner.defaultListID }
        }
        .onChange(of: draft.kind) { _, k in draft.listOrCalendarID = k == .event ? planner.defaultCalendarID : planner.defaultListID }
    }

    private func save() {
        saving = true
        Task {
            let ok: Bool
            if draft.kind == .event {
                let end = allDay ? draft.date : draft.date.addingTimeInterval(3600)
                ok = await planner.saveEvent(.init(eventID: nil, calendarID: draft.listOrCalendarID, title: draft.title, start: draft.date, end: end,
                                                   allDay: allDay, location: "", notes: draft.notes, url: draft.url))
            } else {
                ok = await planner.saveReminder(.init(id: nil, listID: draft.listOrCalendarID, title: draft.title, notes: draft.notes, due: draft.date,
                                                      hasTime: draft.hasTime, priority: 0, url: draft.url))
            }
            saving = false
            if ok {
                Engine.shared.status = draft.kind == .event ? "Termin angelegt." : "Erinnerung angelegt."
                planner.draft = nil
                dismiss()
            }
        }
    }
}

/// Knöpfe „Termin“ und „Erinnerung“ für eine Mail.
struct PlanMenu: View {
    let subject: String
    let sender: String
    let date: Date
    let messageId: String
    let ownClient: Bool
    var due: String?

    var body: some View {
        Menu {
            Button { Planner.shared.plan(.reminder, subject: subject, sender: sender, date: date, messageId: messageId, ownClient: ownClient, due: due) } label: {
                Label("Erinnerung anlegen …", systemImage: "bell")
            }
            Button { Planner.shared.plan(.event, subject: subject, sender: sender, date: date, messageId: messageId, ownClient: ownClient, due: due) } label: {
                Label("Termin anlegen …", systemImage: "calendar.badge.plus")
            }
        } label: { Image(systemName: "calendar.badge.clock") }
            .menuStyle(.borderlessButton).fixedSize()
            .help("Termin oder Erinnerung aus dieser Mail").accessibilityLabel("Termin oder Erinnerung anlegen")
    }
}

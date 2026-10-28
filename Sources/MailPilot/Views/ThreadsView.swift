import SwiftUI

struct ThreadsView: View {
    @EnvironmentObject var engine: Engine
    let filter: ThreadStatus?
    var snoozedOnly = false
    @ViewState private var selectedKey: String?
    @ViewState private var search = ""
    @ViewState private var hideDone = true

    private var items: [MailThread] {
        engine.threads.filter { t in
            (snoozedOnly ? t.isSnoozed : !t.isSnoozed)
                && (filter == nil || t.status == filter)
                && (filter != nil || snoozedOnly || !hideDone || t.status != .done)
                && (search.isEmpty || t.subject.localizedCaseInsensitiveContains(search)
                    || t.counterpart.localizedCaseInsensitiveContains(search)
                    || t.summary.localizedCaseInsensitiveContains(search))
        }
        .sorted { a, b in
            // Überfällige und dringende zuerst, danach nach Datum.
            let ra = rank(a), rb = rank(b)
            if snoozedOnly { return (a.snoozedUntil ?? .distantFuture) < (b.snoozedUntil ?? .distantFuture) }
            return ra != rb ? ra < rb : a.lastDate > b.lastDate
        }
    }

    private func rank(_ t: MailThread) -> Int {
        if snoozedOnly { return 0 }
        if t.isOverdue(followUpDays: engine.settings.followUpDays) { return 0 }
        if t.priority == .high && t.status != .done { return 1 }
        return 2
    }

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                header
                List(items, selection: $selectedKey) { t in
                    ThreadRow(thread: t, settings: engine.settings).tag(t.threadKey)
                        .listRowSeparatorTint(CTW.lineSoft)
                }
                .scrollContentBackground(.hidden)
                .background(CTW.surface)
                .overlay {
                    if items.isEmpty {
                        ContentUnavailableView(emptyText, systemImage: emptySymbol)
                            .foregroundStyle(CTW.muted)
                    }
                }
            }
            .frame(minWidth: 340, idealWidth: 400)
            .background(CTW.surface)
            .searchable(text: $search, placement: .toolbar, prompt: "Gespräche durchsuchen")
            .toolbar {
                if filter == nil {
                    Toggle(isOn: $hideDone) { Label("Erledigte ausblenden", systemImage: "checkmark.circle") }
                        .help("Erledigte ausblenden")
                }
            }

            Group {
                if let key = selectedKey, let t = engine.threads.first(where: { $0.threadKey == key }) {
                    ThreadDetailView(thread: t).id(t.threadKey)
                } else {
                    ContentUnavailableView("Gespräch auswählen", systemImage: "bubble.left.and.bubble.right",
                                           description: Text("Links ein Gespräch wählen, um Stand, Entwurf und Verlauf zu sehen."))
                        .foregroundStyle(CTW.muted)
                }
            }
            .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
            .background(CTW.bg)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Eyebrow(text: "\(items.count) Gespräche", number: snoozedOnly ? "03" : (filter == nil ? "04" : (filter == .needsReply ? "01" : "02")))
            Text(title).font(.system(size: 20, weight: .bold)).foregroundStyle(CTW.ink)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CTW.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(CTW.lineSoft).frame(height: 1) }
    }

    private var title: String {
        switch filter {
        case .needsReply: "Antwort nötig"
        case .waiting: "Warte auf Antwort"
        default: snoozedOnly ? "Zurückgestellt" : "Alle Gespräche"
        }
    }

    private var emptyText: String {
        switch filter {
        case .needsReply: "Nichts offen – du bist durch."
        case .waiting: "Du wartest auf niemanden."
        default: snoozedOnly ? "Nichts zurückgestellt." : "Noch keine Gespräche"
        }
    }

    private var emptySymbol: String {
        switch filter {
        case .needsReply: "checkmark.seal"
        case .waiting: "hourglass"
        default: snoozedOnly ? "moon.zzz" : "tray"
        }
    }
}

struct ThreadRow: View {
    let thread: MailThread
    let settings: AppSettings

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            IconTile(symbol: thread.status.symbol, color: thread.status.color, size: 30)
                .accessibilityLabel(thread.status.label)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(thread.subject.isEmpty ? "(kein Betreff)" : thread.subject)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(CTW.ink)
                        .lineLimit(1)
                    Spacer()
                    Text(thread.lastDate.formatted(.relative(presentation: .numeric)))
                        .font(.caption).foregroundStyle(CTW.muted)
                }
                Text(thread.counterpart).font(.system(size: 12)).foregroundStyle(CTW.muted).lineLimit(1)
                if !thread.summary.isEmpty {
                    Text(thread.summary).font(.caption).foregroundStyle(CTW.muted).lineLimit(2)
                }
                badges
            }
        }
        .padding(.vertical, 5)
    }

    private var badges: some View {
        HStack(spacing: 5) {
            if thread.isOverdue(followUpDays: settings.followUpDays) {
                Badge(text: "Überfällig", color: CTW.action, symbol: "clock.badge.exclamationmark")
            }
            if let until = thread.snoozedUntil, thread.isSnoozed {
                Badge(text: "bis \(until.formatted(date: .abbreviated, time: .shortened))", color: CTW.accent, symbol: "moon.zzz.fill")
            }
            if thread.priority == .high { Badge(text: "Wichtig", color: CTW.action, symbol: "exclamationmark.2") }
            if let due = thread.dueDate { Badge(text: "Frist \(due)", color: CTW.accent, symbol: "calendar") }
            if let cat = thread.category {
                Badge(text: cat, color: CTW.grey500,
                      symbol: settings.category(named: cat)?.symbolName ?? CategoryRule.guessSymbol(for: cat))
            }
            if thread.draft != nil && thread.status == .needsReply {
                Badge(text: "Entwurf", color: CTW.teal700, symbol: "pencil")
            }
        }
    }
}

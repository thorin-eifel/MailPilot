import SwiftUI

struct ThreadsView: View {
    @EnvironmentObject var engine: Engine
    let filter: ThreadStatus?
    @ViewState private var selectedKey: String?
    @ViewState private var search = ""
    @ViewState private var hideDone = true

    private var items: [MailThread] {
        engine.threads.filter { t in
            (filter == nil || t.status == filter)
                && (filter != nil || !hideDone || t.status != .done)
                && (search.isEmpty || t.subject.localizedCaseInsensitiveContains(search)
                    || t.counterpart.localizedCaseInsensitiveContains(search)
                    || t.summary.localizedCaseInsensitiveContains(search))
        }
        .sorted { a, b in
            // Überfällige und dringende zuerst, danach nach Datum.
            let ra = rank(a), rb = rank(b)
            return ra != rb ? ra < rb : a.lastDate > b.lastDate
        }
    }

    private func rank(_ t: MailThread) -> Int {
        if t.isOverdue(followUpDays: engine.settings.followUpDays) { return 0 }
        if t.priority == .high && t.status != .done { return 1 }
        return 2
    }

    var body: some View {
        HSplitView {
            List(items, selection: $selectedKey) { t in
                ThreadRow(thread: t, followUpDays: engine.settings.followUpDays).tag(t.threadKey)
            }
            .frame(minWidth: 320, idealWidth: 380)
            .searchable(text: $search, placement: .toolbar, prompt: "Gespräche durchsuchen")
            .overlay {
                if items.isEmpty {
                    ContentUnavailableView(emptyText, systemImage: "tray")
                }
            }
            .toolbar {
                if filter == nil {
                    Toggle("Erledigte ausblenden", isOn: $hideDone)
                }
            }

            Group {
                if let key = selectedKey, let t = engine.threads.first(where: { $0.threadKey == key }) {
                    ThreadDetailView(thread: t).id(t.threadKey)
                } else {
                    ContentUnavailableView("Gespräch auswählen", systemImage: "bubble.left.and.bubble.right")
                }
            }
            .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var emptyText: String {
        switch filter {
        case .needsReply: "Nichts offen – du bist durch."
        case .waiting: "Du wartest auf niemanden."
        default: "Noch keine Gespräche"
        }
    }
}

struct ThreadRow: View {
    let thread: MailThread
    let followUpDays: Int

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: thread.status.symbol)
                .foregroundStyle(color(for: thread.status))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(thread.subject.isEmpty ? "(kein Betreff)" : thread.subject).fontWeight(.semibold).lineLimit(1)
                    Spacer()
                    Text(thread.lastDate.formatted(.relative(presentation: .numeric)))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(thread.counterpart).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                if !thread.summary.isEmpty {
                    Text(thread.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                HStack(spacing: 6) {
                    if thread.isOverdue(followUpDays: followUpDays) { Badge(text: "Überfällig", color: .purple) }
                    if thread.priority == .high { Badge(text: "Wichtig", color: .red) }
                    if let due = thread.dueDate { Badge(text: "Frist \(due)", color: .orange) }
                    if let cat = thread.category { Badge(text: cat, color: .gray) }
                    if thread.draft != nil && thread.status == .needsReply { Badge(text: "Entwurf", color: .blue) }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

struct Badge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}

func color(for status: ThreadStatus) -> Color {
    switch status {
    case .needsReply: .red
    case .waiting: .orange
    case .info: .blue
    case .done: .green
    }
}

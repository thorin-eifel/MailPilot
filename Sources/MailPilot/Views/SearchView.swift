import SwiftUI

/// Volltextsuche über alle gespeicherten Gespräche, Zusammenfassungen und Mailtexte.
struct SearchView: View {
    @EnvironmentObject var engine: Engine
    @ViewState private var query = ""
    @ViewState private var hits: [SearchHit] = []
    @ViewState private var selected: String?
    @ViewState private var searching = false
    @ViewState private var milliseconds = 0

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                header
                if hits.isEmpty {
                    ContentUnavailableView(emptyTitle, systemImage: "magnifyingglass", description: Text(emptyText))
                        .foregroundStyle(CTW.muted)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(hits, selection: $selected) { hit in
                        SearchRow(hit: hit, isPrivate: engine.threads.first { $0.threadKey == hit.key }?.isPrivate ?? false)
                            .tag(hit.key)
                            .listRowSeparatorTint(CTW.lineSoft)
                    }
                    .scrollContentBackground(.hidden)
                    .background(CTW.surface)
                }
            }
            .frame(minWidth: 380, idealWidth: 440)
            .background(CTW.surface)

            Group {
                if let key = selected, let t = engine.threads.first(where: { $0.threadKey == key }) {
                    ThreadDetailView(thread: t).id(t.threadKey)
                } else if let key = selected, let hit = hits.first(where: { $0.key == key }) {
                    messageOnly(hit)
                } else {
                    ContentUnavailableView("Treffer auswählen", systemImage: "text.magnifyingglass").foregroundStyle(CTW.muted)
                }
            }
            .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
            .background(CTW.bg)
        }
        .task(id: query) { await run() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow(text: hits.isEmpty ? "Volltext" : "\(hits.count) Gespräche · \(milliseconds) ms", number: "00")
            Text("Suche").font(.system(size: 20, weight: .bold)).foregroundStyle(CTW.ink)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(CTW.muted)
                TextField("Betreff, Absender, Zusammenfassung oder Mailtext", text: $query)
                    .textFieldStyle(.plain)
                    .onSubmit { Task { await run(immediately: true) } }
                if searching { ProgressView().controlSize(.mini) }
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless).foregroundStyle(CTW.muted).accessibilityLabel("Suche leeren")
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(CTW.surfaceSoft, in: RoundedRectangle(cornerRadius: CTW.radius))
            .overlay(RoundedRectangle(cornerRadius: CTW.radius).strokeBorder(CTW.line))
        }
        .padding(16)
        .background(CTW.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(CTW.lineSoft).frame(height: 1) }
    }

    private var emptyTitle: String { query.trimmingCharacters(in: .whitespaces).isEmpty ? "Alles durchsuchen" : "Nichts gefunden" }

    private var emptyText: String {
        query.trimmingCharacters(in: .whitespaces).isEmpty
            ? "Auch Mails, die MailPilot schon einsortiert hat. Mehrere Wörter müssen alle vorkommen, \"in Anführungszeichen\" sucht eine Wortfolge."
            : "Zu „\(query)“ gibt es keinen Treffer. Umlaute und Groß-/Kleinschreibung spielen keine Rolle."
    }

    private func run(immediately: Bool = false) async {
        let q = query
        guard !q.trimmingCharacters(in: .whitespaces).isEmpty else { hits = []; return }
        if !immediately {
            try? await Task.sleep(for: .milliseconds(250))
            if Task.isCancelled { return }
        }
        searching = true
        let store = engine.store
        let start = Date()
        let found = await Task.detached { (try? store.search(q)) ?? [] }.value
        if Task.isCancelled { return }
        let keys = Set(engine.threads.map(\.threadKey))
        hits = found.filter { keys.contains($0.key) || ($0.account.map(engine.settings.isEnabled) ?? false) }
        milliseconds = Int(Date().timeIntervalSince(start) * 1000)
        if let s = selected, !hits.contains(where: { $0.key == s }) { selected = nil }
        searching = false
    }

    @ViewBuilder
    private func messageOnly(_ hit: SearchHit) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(hit.subject.isEmpty ? "(kein Betreff)" : hit.subject).font(.title2.bold()).foregroundStyle(CTW.ink)
            Text(hit.party).foregroundStyle(CTW.muted)
            Text(SearchRow.highlight(hit.snippet)).foregroundStyle(CTW.ink)
            if let id = hit.messageId,
               let url = URL(string: "message://" + ("<\(id)>".addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")) {
                Button { NSWorkspace.shared.open(url) } label: { Label("In Mail öffnen", systemImage: "envelope.open") }
                    .buttonStyle(.ctwPrimary)
            }
            Spacer()
        }
        .padding(24)
    }
}

struct SearchRow: View {
    let hit: SearchHit
    let isPrivate: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(hit.subject.isEmpty ? "(kein Betreff)" : hit.subject).font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(CTW.ink).lineLimit(1)
                Spacer()
                if let d = hit.date { Text(d.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(CTW.muted) }
            }
            Text(MailAddress.parse(hit.party).name ?? hit.party).font(.system(size: 12)).foregroundStyle(CTW.muted).lineLimit(1)
            Text(Self.highlight(hit.snippet)).font(.caption).foregroundStyle(CTW.muted).lineLimit(3)
            HStack(spacing: 5) {
                if hit.matches > 1 { Badge(text: "\(hit.matches) Treffer", color: CTW.accent, symbol: "text.magnifyingglass") }
                if isPrivate { Badge(text: "Vertraulich", color: CTW.teal700, symbol: "lock.shield.fill") }
                if !hit.hasThread { Badge(text: "ohne Gespräch", color: CTW.grey500) }
            }
        }
        .padding(.vertical, 5)
    }

    /// Hebt die mit «…» markierten Fundstellen hervor.
    static func highlight(_ s: String) -> AttributedString {
        var out = AttributedString()
        var bold = false
        var buf = ""
        func flush() {
            guard !buf.isEmpty else { return }
            var a = AttributedString(buf)
            if bold { a.foregroundColor = CTW.action; a.inlinePresentationIntent = .stronglyEmphasized }
            out += a
            buf = ""
        }
        for ch in s {
            if ch == "«" { flush(); bold = true } else if ch == "»" { flush(); bold = false } else { buf.append(ch) }
        }
        flush()
        return out
    }
}

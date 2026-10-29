import SwiftUI

struct BriefingView: View {
    @EnvironmentObject var engine: Engine
    @ObservedObject private var planner = Planner.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                // Breit: Briefing links, Bereiche rechts. Schmal: untereinander.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 24) {
                        briefingCard.frame(minWidth: 560, maxWidth: .infinity, alignment: .topLeading)
                        areas.frame(width: 440)
                    }
                    VStack(alignment: .leading, spacing: 18) {
                        areas
                        briefingCard
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(CTW.bg)
        // Bei jedem Öffnen frisch erstellen (nicht beim Rendern der Vorschau und nicht doppelt).
        .task {
            guard !CommandLine.arguments.contains("--render"), !engine.isBriefing else { return }
            await engine.generateBriefing()
        }
    }

    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                Eyebrow(text: Date().formatted(date: .complete, time: .omitted), number: "00")
                Text(greeting).font(.system(size: 30, weight: .bold)).foregroundStyle(CTW.ink)
                if let b = engine.briefing {
                    Text("Briefing von \(b.date.formatted(date: .abbreviated, time: .shortened))").foregroundStyle(CTW.muted)
                }
            }
            Spacer()
            if engine.isBriefing { ProgressView().controlSize(.small) }
            Button { Task { await engine.generateBriefing() } } label: { Label("Neu erstellen", systemImage: "sparkles") }
                .buttonStyle(.ctwPrimary)
                .disabled(engine.isBriefing)
        }
    }

    @ViewBuilder
    private var briefingCard: some View {
        if let b = engine.briefing {
            // Jeder Abschnitt (Überschrift mit Inhalt) bekommt eine eigene Karte; auf breiten Fenstern stehen sie nebeneinander.
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 520), spacing: 16, alignment: .top)], alignment: .leading, spacing: 16) {
                ForEach(Array(Self.sections(b.text).enumerated()), id: \.offset) { _, part in
                    MarkdownText(part).ctwCard(padding: 20).frame(maxHeight: .infinity, alignment: .top)
                }
            }
        } else {
            ContentUnavailableView("Noch kein Briefing", systemImage: "sun.horizon",
                                   description: Text("Das Briefing wird täglich ab \(engine.settings.briefingHour) Uhr erstellt – oder jetzt über „Neu erstellen“."))
                .foregroundStyle(CTW.muted)
                .ctwCard(padding: 24)
        }
    }

    /// Teilt den Text an den Überschriften („# …“) in Abschnitte; Text vor der ersten Überschrift bleibt ein eigener Abschnitt.
    static func sections(_ text: String) -> [String] {
        var out: [[String]] = [[]]
        for line in text.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("#"), !(out.last ?? []).allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) { out.append([]) }
            out[out.count - 1].append(line)
        }
        return out.map { $0.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    /// Zahlen und Einstiege in die Bereiche – jede Kachel öffnet den Bereich.
    private var areas: some View {
        let cols = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
        return VStack(alignment: .leading, spacing: 12) {
            Eyebrow(text: "Gespräche")
            LazyVGrid(columns: cols, spacing: 12) {
                go(.needsReply) { StatTile(value: engine.needsReply.count, label: "Antwort nötig", symbol: "arrowshape.turn.up.left.fill", color: CTW.action) }
                go(.waiting) { StatTile(value: engine.waiting.count, label: "Warte auf Antwort", symbol: "hourglass", color: CTW.accent) }
                go(.waiting) { StatTile(value: engine.overdue.count, label: "Überfällig", symbol: "clock.badge.exclamationmark.fill", color: CTW.action) }
                go(.all) { StatTile(value: engine.threads.filter { $0.dueDate != nil && $0.status != .done }.count, label: "Mit Frist", symbol: "calendar", color: CTW.teal700) }
            }
            Eyebrow(text: "Bereiche").padding(.top, 6)
            LazyVGrid(columns: cols, spacing: 12) {
                area(.mailbox, nil)
                area(.calendar, nil)
                area(.reminders, planner.overdueCount)
                area(.invoices, engine.invoiceAlertCount)
                area(.invites, engine.newInviteCount)
                area(.newsletter, nil)
                area(.search, nil)
                area(.weekly, nil)
            }
        }
    }

    private func go<Content: View>(_ item: SidebarItem, @ViewBuilder _ content: () -> Content) -> some View {
        Button { engine.requestedSidebar = item } label: { content().frame(maxWidth: .infinity, alignment: .leading) }
            .buttonStyle(.plain)
            .help("\(item.label) öffnen")
    }

    private func area(_ item: SidebarItem, _ count: Int?) -> some View {
        go(item) {
            HStack(spacing: 10) {
                IconTile(symbol: item.symbol, color: CTW.accent, size: 30)
                Text(item.label).fontWeight(.medium).foregroundStyle(CTW.ink)
                Spacer(minLength: 0)
                if let count, count > 0 { Badge(text: "\(count)", color: CTW.action) }
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(CTW.muted)
            }
            .ctwCard(padding: 12)
        }
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<11: "Guten Morgen."
        case 11..<18: "Guten Tag."
        default: "Guten Abend."
        }
    }
}

/// Einfache Markdown-Darstellung: Überschriften, Listen und Inline-Formatierung.
struct MarkdownText: View {
    let source: String
    init(_ source: String) { self.source = source }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(source.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                lineView(line)
            }
        }
        .foregroundStyle(CTW.ink)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func lineView(_ raw: String) -> some View {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("#") {
            let text = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
            HStack(spacing: 8) {
                Rectangle().fill(CTW.action).frame(width: 3, height: 16)
                inline(text).font(.system(size: 15, weight: .bold))
            }
            .padding(.top, 10)
        } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Rectangle().fill(CTW.teal500).frame(width: 5, height: 5).offset(y: -2)
                inline(String(line.dropFirst(2)))
            }
            .padding(.leading, raw.hasPrefix("  ") ? 18 : 0)
        } else if line.isEmpty {
            Spacer().frame(height: 2)
        } else {
            inline(line)
        }
    }

    private func inline(_ s: String) -> Text {
        if let a = try? AttributedString(markdown: s) { return Text(a) }
        return Text(s)
    }
}

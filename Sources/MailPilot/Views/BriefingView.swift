import SwiftUI

struct BriefingView: View {
    @EnvironmentObject var engine: Engine

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        Eyebrow(text: Date().formatted(date: .complete, time: .omitted), number: "00")
                        Text(greeting).font(.system(size: 30, weight: .bold)).foregroundStyle(CTW.ink)
                        if let b = engine.briefing {
                            Text("Briefing von \(b.date.formatted(date: .abbreviated, time: .shortened))")
                                .foregroundStyle(CTW.muted)
                        }
                    }
                    Spacer()
                    if engine.isBriefing { ProgressView().controlSize(.small) }
                    Button { Task { await engine.generateBriefing() } } label: {
                        Label("Neu erstellen", systemImage: "sparkles")
                    }
                    .buttonStyle(.ctwPrimary)
                    .disabled(engine.isBriefing)
                }

                HStack(spacing: 12) {
                    StatTile(value: engine.needsReply.count, label: "Antwort nötig", symbol: "arrowshape.turn.up.left.fill", color: CTW.action)
                    StatTile(value: engine.waiting.count, label: "Warte auf Antwort", symbol: "hourglass", color: CTW.accent)
                    StatTile(value: engine.overdue.count, label: "Überfällig", symbol: "clock.badge.exclamationmark.fill", color: CTW.action)
                    StatTile(value: engine.threads.filter { $0.dueDate != nil && $0.status != .done }.count,
                             label: "Mit Frist", symbol: "calendar", color: CTW.teal700)
                }

                if let b = engine.briefing {
                    MarkdownText(b.text).ctwCard(padding: 20)
                } else {
                    ContentUnavailableView("Noch kein Briefing", systemImage: "sun.horizon",
                                           description: Text("Das Briefing wird täglich ab \(engine.settings.briefingHour) Uhr erstellt – oder jetzt über „Neu erstellen“."))
                        .foregroundStyle(CTW.muted)
                        .ctwCard(padding: 24)
                }
            }
            .padding(24)
            .frame(maxWidth: 860, alignment: .leading)
        }
        .background(CTW.bg)
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

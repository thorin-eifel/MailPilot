import SwiftUI

struct BriefingView: View {
    @EnvironmentObject var engine: Engine

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading) {
                        Text("Briefing").font(.largeTitle.bold())
                        if let b = engine.briefing {
                            Text("Erstellt \(b.date.formatted(date: .complete, time: .shortened))").foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if engine.isBriefing { ProgressView().controlSize(.small) }
                    Button("Neu erstellen") { Task { await engine.generateBriefing() } }
                        .disabled(engine.isBriefing)
                }

                HStack(spacing: 12) {
                    StatTile(value: engine.needsReply.count, label: "Antwort nötig", color: .red)
                    StatTile(value: engine.waiting.count, label: "Warte auf Antwort", color: .orange)
                    StatTile(value: engine.overdue.count, label: "Überfällig", color: .purple)
                    StatTile(value: engine.threads.filter { $0.dueDate != nil && $0.status != .done }.count, label: "Mit Frist", color: .blue)
                }

                if let b = engine.briefing {
                    MarkdownText(b.text)
                } else {
                    ContentUnavailableView("Noch kein Briefing", systemImage: "sun.max",
                                           description: Text("Das Briefing wird täglich ab \(engine.settings.briefingHour) Uhr erstellt – oder jetzt über „Neu erstellen“."))
                }
            }
            .padding(24)
            .frame(maxWidth: 820, alignment: .leading)
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
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func lineView(_ raw: String) -> some View {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("#") {
            let text = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
            inline(text).font(.title3.bold()).padding(.top, 8)
        } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•")
                inline(String(line.dropFirst(2)))
            }
            .padding(.leading, raw.hasPrefix("  ") ? 16 : 0)
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

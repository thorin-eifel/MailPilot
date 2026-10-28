import SwiftUI

struct ActivityView: View {
    @EnvironmentObject var engine: Engine

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    Eyebrow(text: "\(engine.activity.count) Einträge", number: "04")
                    Text("Aktivität").font(.system(size: 20, weight: .bold)).foregroundStyle(CTW.ink)
                }
                Spacer()
                summary
            }

            Table(engine.activity) {
                TableColumn("Zeit") { e in
                    Text(e.date.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(CTW.muted)
                }
                .width(min: 110, ideal: 130)
                TableColumn("Aktion") { e in
                    HStack(spacing: 6) {
                        Image(systemName: symbol(for: e)).foregroundStyle(color(for: e)).frame(width: 16)
                        if e.dryRun { Badge(text: "Probe", color: CTW.accent, symbol: "testtube.2") }
                        Text(e.detail).strikethrough(e.undone).foregroundStyle(CTW.ink)
                    }
                }
                .width(min: 180, ideal: 260)
                TableColumn("Betreff") { e in Text(e.subject).lineLimit(1).foregroundStyle(CTW.ink) }
                TableColumn("Konto") { e in Text(e.account).foregroundStyle(CTW.muted).lineLimit(1) }
                    .width(min: 80, ideal: 140)
                TableColumn("") { e in
                    if e.canUndo {
                        Button { Task { await engine.undo(e) } } label: {
                            Label("Rückgängig", systemImage: "arrow.uturn.backward")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(CTW.accent)
                    }
                }
                .width(110)
            }
            .scrollContentBackground(.hidden)
            .background(CTW.surface)
            .clipShape(RoundedRectangle(cornerRadius: CTW.radius))
            .overlay(RoundedRectangle(cornerRadius: CTW.radius).strokeBorder(CTW.lineSoft))
            .overlay {
                if engine.activity.isEmpty {
                    ContentUnavailableView("Noch keine automatischen Aktionen", systemImage: "list.bullet.rectangle")
                        .foregroundStyle(CTW.muted)
                }
            }
        }
        .padding(20)
        .background(CTW.bg)
    }

    private var summary: some View {
        let moves = engine.activity.filter { $0.kind == "move" && !$0.undone && !$0.dryRun }.count
        let flags = engine.activity.filter { $0.kind == "flag" && !$0.dryRun }.count
        let errors = engine.activity.filter { $0.kind == "error" && !$0.undone }.count
        return HStack(spacing: 6) {
            Badge(text: "\(moves) verschoben", color: CTW.teal700, symbol: "folder.fill")
            Badge(text: "\(flags) markiert", color: CTW.accent, symbol: "flag.fill")
            if errors > 0 { Badge(text: "\(errors) Fehler", color: CTW.action, symbol: "exclamationmark.triangle.fill") }
        }
    }

    private func symbol(for e: ActivityEntry) -> String {
        switch e.kind {
        case "move": "folder.fill"
        case "flag": "flag.fill"
        case "undo": "arrow.uturn.backward"
        case "correction": "graduationcap.fill"
        case "deadline": "calendar.badge.plus"
        case "error": "exclamationmark.triangle.fill"
        default: "circle.fill"
        }
    }

    private func color(for e: ActivityEntry) -> Color {
        switch e.kind {
        case "error": CTW.action
        case "flag", "correction", "deadline": CTW.accent
        default: CTW.teal700
        }
    }
}

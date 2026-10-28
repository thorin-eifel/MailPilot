import SwiftUI

struct ActivityView: View {
    @EnvironmentObject var engine: Engine

    var body: some View {
        Table(engine.activity) {
            TableColumn("Zeit") { e in
                Text(e.date.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary)
            }
            .width(min: 110, ideal: 130)
            TableColumn("Betreff") { e in Text(e.subject).lineLimit(1) }
            TableColumn("Aktion") { e in
                HStack {
                    if e.dryRun { Badge(text: "Probe", color: .orange) }
                    Text(e.detail).strikethrough(e.undone)
                }
            }
            TableColumn("Konto") { e in Text(e.account).foregroundStyle(.secondary).lineLimit(1) }
                .width(min: 80, ideal: 140)
            TableColumn("") { e in
                if e.canUndo {
                    Button("Rückgängig") { Task { await engine.undo(e) } }
                        .buttonStyle(.borderless)
                }
            }
            .width(90)
        }
        .overlay {
            if engine.activity.isEmpty {
                ContentUnavailableView("Noch keine automatischen Aktionen", systemImage: "list.bullet.rectangle")
            }
        }
        .navigationTitle("Aktivität")
    }
}

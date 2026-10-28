import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var engine: Engine
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("MailPilot").font(.headline)
                Spacer()
                if engine.isRunning { ProgressView().controlSize(.small) }
            }
            Text(engine.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            if let err = engine.lastError {
                Text(err).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                StatTile(value: engine.needsReply.count, label: "Antworten", color: .red)
                StatTile(value: engine.waiting.count, label: "Warten", color: .orange)
                StatTile(value: engine.overdue.count, label: "Überfällig", color: .purple)
            }

            if !engine.needsReply.isEmpty {
                Divider()
                Text("Ich bin am Zug").font(.caption.bold()).foregroundStyle(.secondary)
                ForEach(engine.needsReply.prefix(6)) { t in
                    Button { openDashboard() } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                if t.priority == .high { Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red) }
                                Text(t.subject).lineLimit(1).fontWeight(.medium)
                            }
                            Text("\(t.counterpart) · \(t.nextStep)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
            }

            Divider()
            HStack {
                Button("Jetzt prüfen") { Task { await engine.runCycle() } }.disabled(engine.isRunning)
                Button("Dashboard") { openDashboard() }
                Spacer()
                Button(engine.paused ? "Fortsetzen" : "Pause") { engine.paused.toggle() }
            }
            HStack {
                if let last = engine.lastRun {
                    Text("Zuletzt \(last.formatted(.relative(presentation: .named)))").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Beenden") { NSApp.terminate(nil) }.font(.caption)
            }
        }
        .padding(14)
        .frame(width: 340)
    }

    private func openDashboard() {
        openWindow(id: "dashboard")
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct StatTile: View {
    let value: Int
    let label: String
    let color: Color

    var body: some View {
        VStack(spacing: 2) {
            Text("\(value)").font(.title2.bold()).foregroundStyle(value > 0 ? color : .secondary)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

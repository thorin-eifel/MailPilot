import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var engine: Engine
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                CTWLogo(height: 18)
                Spacer()
                Eyebrow(text: "MailPilot")
            }

            statusLine

            HStack(spacing: 8) {
                StatTile(value: engine.needsReply.count, label: "Antworten", symbol: "arrowshape.turn.up.left.fill", color: CTW.action)
                StatTile(value: engine.waiting.count, label: "Warten", symbol: "hourglass", color: CTW.accent)
                StatTile(value: engine.overdue.count, label: "Überfällig", symbol: "clock.badge.exclamationmark.fill", color: CTW.action)
            }

            if !engine.needsReply.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Eyebrow(text: "Ich bin am Zug")
                        .padding(.bottom, 4)
                    ForEach(engine.needsReply.prefix(6)) { t in
                        Button { openDashboard() } label: {
                            HStack(alignment: .top, spacing: 8) {
                                IconTile(symbol: t.priority == .high ? "exclamationmark.2" : "arrowshape.turn.up.left.fill",
                                         color: CTW.action, size: 22)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(t.subject).lineLimit(1).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(CTW.ink)
                                    Text(t.nextStep.isEmpty ? t.counterpart : "\(t.counterpart) · \(t.nextStep)")
                                        .font(.caption).foregroundStyle(CTW.muted).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .ctwCard(padding: 8)
            }

            HStack(spacing: 8) {
                Button { openDashboard() } label: { Label("Dashboard", systemImage: "rectangle.grid.2x2") }
                    .buttonStyle(.ctwPrimary)
                Button { Task { await engine.runCycle() } } label: { Label("Prüfen", systemImage: "arrow.clockwise") }
                    .buttonStyle(.ctwSecondary)
                    .disabled(engine.isRunning)
                Spacer()
                Button { engine.paused.toggle() } label: {
                    Image(systemName: engine.paused ? "play.fill" : "pause.fill")
                }
                .buttonStyle(.ctwSecondary)
                .help(engine.paused ? "Fortsetzen" : "Pausieren")
                .accessibilityLabel(engine.paused ? "Fortsetzen" : "Pausieren")
            }

            HStack {
                if let last = engine.lastRun {
                    Text("Zuletzt \(last.formatted(.relative(presentation: .named)))")
                }
                Spacer()
                Button("Beenden") { NSApp.terminate(nil) }.buttonStyle(.link)
            }
            .font(.caption2)
            .foregroundStyle(CTW.muted)
        }
        .padding(14)
        .frame(width: 360)
        .tint(CTW.accent)
    }

    @ViewBuilder
    private var statusLine: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let p = engine.initialProgress {
                HStack {
                    Image(systemName: "tray.full.fill").foregroundStyle(CTW.accent)
                    Text("Erstscan läuft").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(CTW.ink)
                    Spacer()
                    Text("\(Int(p.fraction * 100)) %").monospacedDigit().foregroundStyle(CTW.muted)
                }
                ProgressView(value: p.fraction).tint(CTW.accent)
                Text("\(p.analyzed) von \(p.total) analysiert · \(p.moved) einsortiert")
                    .font(.caption).foregroundStyle(CTW.muted)
            } else {
                HStack(spacing: 6) {
                    if engine.isRunning {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: engine.paused ? "pause.circle.fill" : "checkmark.circle.fill")
                            .foregroundStyle(engine.paused ? CTW.grey500 : CTW.teal700)
                    }
                    Text(engine.status).font(.caption).foregroundStyle(CTW.muted).lineLimit(1)
                }
            }
            if let reason = engine.usageBlock {
                Label(reason, systemImage: "pause.circle.fill").font(.caption).foregroundStyle(CTW.action)
            } else if let l = engine.planLimits, let w = l.fiveHour, w.isCurrent {
                Label("Claude 5 h: \(w.percent) %" + (l.sevenDay.map { " · 7 Tage: \($0.percent) %" } ?? ""), systemImage: "gauge.with.dots.needle.50percent")
                    .font(.caption).foregroundStyle(CTW.muted)
            }
            if let err = engine.lastError {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(CTW.action)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ctwGlass()
    }

    private func openDashboard() {
        openWindow(id: "dashboard")
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct StatTile: View {
    let value: Int
    let label: String
    let symbol: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(value > 0 ? color : CTW.grey500)
            Text("\(value)")
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(value > 0 ? CTW.ink : CTW.grey500)
            Text(label).font(.system(size: 10.5, weight: .medium)).foregroundStyle(CTW.muted).lineLimit(1)
        }
        .ctwCard(padding: 10)
        .accessibilityElement(children: .combine)
    }
}

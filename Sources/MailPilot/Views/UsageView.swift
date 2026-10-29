import SwiftUI

/// Claude-Nutzung: Abo-Auslastung, Aufrufe von MailPilot und Schutz vor Überlastung.
struct UsageView: View {
    @EnvironmentObject var engine: Engine
    @ViewState private var week = UsageSummary()
    @ViewState private var byPurpose: [UsageByPurpose] = []
    @ViewState private var byDay: [UsageByDay] = []
    @ViewState private var refreshing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if let reason = engine.usageBlock {
                    Label(reason, systemImage: "pause.circle.fill")
                        .foregroundStyle(CTW.action).fontWeight(.semibold)
                        .ctwCard()
                }
                limitsCard
                HStack(alignment: .top, spacing: 12) {
                    SummaryTile(title: "Heute", symbol: "sun.max.fill", summary: engine.usageToday)
                    SummaryTile(title: "Letzte 7 Tage", symbol: "calendar", summary: week)
                }
                chartCard
                savingsCard
                guardCard
            }
            .padding(24)
            .frame(maxWidth: 1500, alignment: .leading)
        }
        .background(CTW.bg)
        .onAppear(perform: load)
        .onChange(of: engine.usageToday) { _, _ in load() }
    }

    private func load() {
        let since = Calendar.current.date(byAdding: .day, value: -6, to: Calendar.current.startOfDay(for: Date())) ?? Date()
        week = engine.store.usageSummary(since: since)
        byPurpose = engine.store.usageByPurpose(since: since)
        byDay = engine.store.usageByDay(days: 7)
    }

    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                Eyebrow(text: "System", number: "07")
                Text("Claude-Nutzung").font(.system(size: 28, weight: .bold)).foregroundStyle(CTW.ink)
                Text("Wie viel MailPilot verbraucht – und wie nah dein Abo am Limit ist.").foregroundStyle(CTW.muted)
            }
            Spacer()
            if refreshing { ProgressView().controlSize(.small) }
            Button {
                refreshing = true
                Task { await engine.refreshPlanLimits(); load(); refreshing = false }
            } label: { Label("Jetzt abfragen", systemImage: "arrow.clockwise") }
                .buttonStyle(.ctwSecondary)
                .disabled(refreshing)
        }
    }

    private var limitsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow(text: "Abo-Limit", number: "01")
            if let l = engine.planLimits, l.fiveHour != nil || l.sevenDay != nil {
                HStack(alignment: .top, spacing: 18) {
                    if let w = l.fiveHour { LimitGauge(title: "5-Stunden-Fenster", window: w, pause: engine.settings.fiveHourPause, guardOn: engine.settings.limitGuardEnabled, long: false) }
                    if let w = l.sevenDay { LimitGauge(title: "7-Tage-Fenster", window: w, pause: engine.settings.sevenDayPause, guardOn: engine.settings.limitGuardEnabled, long: true) }
                }
                Text("Stand \(l.updatedAt.formatted(date: .omitted, time: .shortened)) – aus dem letzten Claude-Aufruf. Die Werte gelten für dein gesamtes Claude-Abo (auch Chat und Claude Code), nicht nur für MailPilot.")
                    .font(.caption).foregroundStyle(CTW.muted)
            } else {
                Label("Noch keine Messung. Sie erscheint nach dem nächsten Claude-Aufruf – oder mit „Jetzt abfragen“ (ein winziger Aufruf).",
                      systemImage: "gauge.with.dots.needle.0percent")
                    .foregroundStyle(CTW.muted)
            }
        }
        .ctwCard()
    }

    private var chartCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow(text: "Aufrufe", number: "02")
            let maxCalls = max(1, byDay.map(\.calls).max() ?? 1)
            HStack(alignment: .bottom, spacing: 10) {
                ForEach(byDay) { d in
                    VStack(spacing: 4) {
                        Text("\(d.calls)").font(.caption2).monospacedDigit().foregroundStyle(CTW.muted)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Calendar.current.isDateInToday(d.day) ? CTW.action : CTW.accent)
                            .frame(height: max(3, CGFloat(d.calls) / CGFloat(maxCalls) * 90))
                        Text(d.day.formatted(.dateTime.weekday(.abbreviated))).font(.caption2).foregroundStyle(CTW.muted)
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(d.day.formatted(.dateTime.weekday(.wide))): \(d.calls) Aufrufe")
                }
            }
            .frame(height: 130, alignment: .bottom)
            if !byPurpose.isEmpty {
                Divider().overlay(CTW.lineSoft)
                ForEach(byPurpose) { p in
                    HStack {
                        Text(p.purpose).foregroundStyle(CTW.ink)
                        Spacer()
                        Text("\(p.calls) Aufrufe").monospacedDigit().foregroundStyle(CTW.muted)
                        Text("\(p.tokens.formatted()) Token").monospacedDigit().foregroundStyle(CTW.muted).frame(width: 130, alignment: .trailing)
                    }
                    .font(.callout)
                }
            }
        }
        .ctwCard()
    }

    private var savingsCard: some View {
        let since = Calendar.current.date(byAdding: .day, value: -6, to: Calendar.current.startOfDay(for: Date())) ?? Date()
        let local = engine.store.locallyClassifiedCount(since: since)
        let all = engine.store.classifiedCount(since: since)
        return VStack(alignment: .leading, spacing: 8) {
            Eyebrow(text: "Ohne Claude", number: "03")
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(local)").font(.system(size: 26, weight: .bold, design: .rounded)).monospacedDigit().foregroundStyle(CTW.ink)
                Text(all > 0 ? "von \(all) Mails der letzten 7 Tage (\(Int((Double(local) / Double(all) * 100).rounded())) %) ohne Claude einsortiert" : "Mails ohne Claude einsortiert")
                    .foregroundStyle(CTW.muted)
            }
            Text("Newsletter und Systemmeldungen erkennt MailPilot an den Mail-Headern, wiederkehrende Absender an ihrer Vorgeschichte. Rechnungen, Bestellungen, Termine und laufende Gespräche gehen immer an Claude.")
                .font(.caption).foregroundStyle(CTW.muted)
        }
        .ctwCard()
    }

    private var guardCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow(text: "Schutz", number: "04")
            Toggle("Automatische Claude-Arbeit pausieren, wenn das Limit fast erreicht ist", isOn: $engine.settings.limitGuardEnabled)
                .toggleStyle(.switch)
            if engine.settings.limitGuardEnabled {
                HStack {
                    Text("5-Stunden-Fenster ab \(Int(engine.settings.fiveHourPause * 100)) %").frame(width: 230, alignment: .leading)
                    Slider(value: $engine.settings.fiveHourPause, in: 0.5...1, step: 0.05)
                }
                HStack {
                    Text("7-Tage-Fenster ab \(Int(engine.settings.sevenDayPause * 100)) %").frame(width: 230, alignment: .leading)
                    Slider(value: $engine.settings.sevenDayPause, in: 0.5...1, step: 0.05)
                }
            }
            Stepper(engine.settings.maxCallsPerDay == 0 ? "Keine Obergrenze für automatische Aufrufe pro Tag"
                    : "Höchstens \(engine.settings.maxCallsPerDay) automatische Aufrufe pro Tag",
                    value: $engine.settings.maxCallsPerDay, in: 0...2000, step: 25)
            Text("Pausiert werden nur Aufrufe, die MailPilot selbst auslöst (Analyse, Nachfass-Entwürfe, Rechnungen, Briefing). Was du per Knopfdruck startest – etwa einen Entwurf neu schreiben – läuft immer. Eingehende Mails werden weiter gelesen und mit deinen Regeln sortiert; die Analyse holt MailPilot nach.")
                .font(.caption).foregroundStyle(CTW.muted)
        }
        .ctwCard()
    }
}

struct LimitGauge: View {
    let title: String
    let window: PlanWindow
    let pause: Double
    let guardOn: Bool
    let long: Bool

    private var color: Color {
        guard window.isCurrent else { return CTW.grey500 }
        if guardOn && window.utilization >= pause { return CTW.action }
        return window.utilization >= 0.75 ? CTW.action.opacity(0.75) : CTW.accent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(CTW.muted)
            Text(window.isCurrent ? "\(window.percent) %" : "zurückgesetzt")
                .font(.system(size: 30, weight: .bold, design: .rounded)).monospacedDigit().foregroundStyle(CTW.ink)
            ProgressView(value: window.isCurrent ? min(1, window.utilization) : 0).tint(color)
            if let r = window.resetsAt, window.isCurrent {
                Text("Zurück auf 0 \(long ? r.formatted(date: .abbreviated, time: .shortened) : r.formatted(date: .omitted, time: .shortened))")
                    .font(.caption).foregroundStyle(CTW.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

struct SummaryTile: View {
    let title: String
    let symbol: String
    let summary: UsageSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: symbol).foregroundStyle(CTW.accent)
                Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(CTW.muted)
            }
            Text("\(summary.calls) Aufrufe").font(.system(size: 22, weight: .bold, design: .rounded)).foregroundStyle(CTW.ink).monospacedDigit()
            Text("\(summary.totalTokens.formatted()) Token (\(summary.cacheReadTokens.formatted()) aus dem Zwischenspeicher)")
                .font(.caption).foregroundStyle(CTW.muted)
            HStack(spacing: 12) {
                Label(String(format: "Ø %.1f s", summary.avgSeconds), systemImage: "timer")
                Label("\(summary.failures) Fehler", systemImage: summary.failures > 0 ? "exclamationmark.triangle.fill" : "checkmark.circle")
                    .foregroundStyle(summary.failures > 0 ? CTW.action : CTW.muted)
            }
            .font(.caption).foregroundStyle(CTW.muted)
            Text("API-Gegenwert ca. \(Money.format(summary.costUSD, currency: "USD")) – im Abo nicht abgerechnet")
                .font(.caption2).foregroundStyle(CTW.muted)
        }
        .ctwCard()
        .accessibilityElement(children: .combine)
    }
}

import SwiftUI

/// Wochenbericht: Zahlen im Vergleich zur Vorwoche, wo du säumig bist, worauf du wartest.
struct WeeklyView: View {
    @EnvironmentObject var engine: Engine

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if let r = engine.weeklyReport {
                    tiles(r.stats)
                    categoriesCard(r.stats)
                    HStack(alignment: .top, spacing: 12) {
                        ageList(title: "Hier bist du säumig", symbol: "arrowshape.turn.up.left.fill", color: CTW.action,
                                empty: "Nichts überfällig.", items: r.stats.lateReplies)
                        ageList(title: "Hier wartest du", symbol: "hourglass", color: CTW.accent,
                                empty: "Niemand lässt dich warten.", items: r.stats.overdueWaiting)
                    }
                    if r.stats.invoicesNew > 0 || r.stats.invoicesOverdue > 0 {
                        Label("Rechnungen: \(r.stats.invoicesNew) neu (\(Money.summary(r.stats.invoicesNewTotal))), \(r.stats.invoicesOverdue) überfällig (\(Money.summary(r.stats.invoicesOverdueTotal)))",
                              systemImage: "eurosign.circle.fill")
                            .foregroundStyle(CTW.ink)
                            .ctwCard()
                    }
                    if !r.text.isEmpty {
                        MarkdownText(r.text).ctwCard(padding: 20)
                    }
                } else {
                    ContentUnavailableView("Noch kein Wochenbericht", systemImage: "chart.bar.doc.horizontal",
                                           description: Text("Montags ab \(engine.settings.briefingHour) Uhr erstellt MailPilot ihn automatisch – oder jetzt über „Neu erstellen“."))
                        .foregroundStyle(CTW.muted)
                        .ctwCard(padding: 24)
                }
            }
            .padding(24)
            .frame(maxWidth: 900, alignment: .leading)
        }
        .background(CTW.bg)
    }

    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                Eyebrow(text: engine.weeklyReport.map { "\($0.stats.from.formatted(date: .abbreviated, time: .omitted)) – \($0.stats.to.formatted(date: .abbreviated, time: .omitted))" } ?? "Auswertung", number: "08")
                Text("Wochenbericht").font(.system(size: 28, weight: .bold)).foregroundStyle(CTW.ink)
                if let r = engine.weeklyReport {
                    Text("Erstellt \(r.date.formatted(date: .complete, time: .shortened))").foregroundStyle(CTW.muted)
                }
            }
            Spacer()
            if engine.weeklyBusy { ProgressView().controlSize(.small) }
            Button { Task { await engine.generateWeeklyReport(manual: true) } } label: { Label("Neu erstellen", systemImage: "sparkles") }
                .buttonStyle(.ctwPrimary)
                .disabled(engine.weeklyBusy)
        }
    }

    private func tiles(_ s: WeeklyStats) -> some View {
        HStack(spacing: 12) {
            DeltaTile(title: "Eingegangen", value: "\(s.received)", delta: s.received - s.receivedPrevious, symbol: "tray.and.arrow.down.fill")
            DeltaTile(title: "Gesendet", value: "\(s.sent)", delta: s.sent - s.sentPrevious, symbol: "paperplane.fill")
            VStack(alignment: .leading, spacing: 4) {
                Image(systemName: "timer").foregroundStyle(CTW.accent)
                Text(s.medianReplyHours.map { Self.hours($0) } ?? "–")
                    .font(.system(size: 22, weight: .bold, design: .rounded)).monospacedDigit().foregroundStyle(CTW.ink)
                Text(s.replySamples > 0 ? "Antwortzeit (Median, \(s.replySamples))" : "Antwortzeit").font(.system(size: 10.5, weight: .medium)).foregroundStyle(CTW.muted)
            }
            .ctwCard(padding: 12)
            StatTile(value: s.openNeedsReply, label: "warten auf dich", symbol: "arrowshape.turn.up.left.fill", color: CTW.action)
        }
    }

    private func categoriesCard(_ s: WeeklyStats) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow(text: "Kategorien – diese Woche gegen Vorwoche", number: "01")
            if s.categories.isEmpty {
                Text("Keine kategorisierten Mails in diesem Zeitraum.").foregroundStyle(CTW.muted)
            }
            let maxValue = max(1, s.categories.map { max($0.now, $0.previous) }.max() ?? 1)
            ForEach(s.categories.prefix(9)) { c in
                HStack(spacing: 10) {
                    Text(c.name).frame(width: 150, alignment: .leading).foregroundStyle(CTW.ink)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 3).fill(CTW.lineSoft).frame(width: geo.size.width * CGFloat(c.previous) / CGFloat(maxValue), height: 5)
                                .offset(y: 7)
                            RoundedRectangle(cornerRadius: 3).fill(CTW.accent).frame(width: geo.size.width * CGFloat(c.now) / CGFloat(maxValue), height: 8)
                                .offset(y: -3)
                        }
                    }
                    .frame(height: 16)
                    Text("\(c.now)").monospacedDigit().frame(width: 36, alignment: .trailing).foregroundStyle(CTW.ink)
                    Text(Self.deltaText(c.delta)).monospacedDigit().frame(width: 40, alignment: .trailing)
                        .foregroundStyle(c.delta > 0 ? CTW.action : CTW.muted)
                }
                .font(.callout)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(c.name): \(c.now), Vorwoche \(c.previous)")
            }
        }
        .ctwCard()
    }

    private func ageList(title: String, symbol: String, color: Color, empty: String, items: [ThreadAge]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                IconTile(symbol: symbol, color: color, size: 24)
                Eyebrow(text: title)
            }
            if items.isEmpty { Text(empty).font(.callout).foregroundStyle(CTW.muted) }
            ForEach(items) { t in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(t.subject.isEmpty ? "(kein Betreff)" : t.subject).fontWeight(.medium).foregroundStyle(CTW.ink).lineLimit(1)
                        Text(t.counterpart).font(.caption).foregroundStyle(CTW.muted).lineLimit(1)
                    }
                    Spacer()
                    Badge(text: "\(t.days) Tage", color: color)
                }
            }
        }
        .ctwCard()
    }

    static func deltaText(_ d: Int) -> String { d == 0 ? "±0" : (d > 0 ? "+\(d)" : "−\(abs(d))") }

    /// „45 Min.“, „5,4 Std.“, „2,5 Tage“ (Dezimalkomma nur in der Zahl).
    static func hours(_ h: Double) -> String {
        func num(_ v: Double) -> String { String(format: "%.1f", v).replacingOccurrences(of: ".", with: ",") }
        if h < 1 { return "\(Int(h * 60)) Min." }
        return h < 48 ? "\(num(h)) Std." : "\(num(h / 24)) Tage"
    }
}

struct DeltaTile: View {
    let title: String
    let value: String
    let delta: Int
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: symbol).foregroundStyle(CTW.accent)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(value).font(.system(size: 22, weight: .bold, design: .rounded)).monospacedDigit().foregroundStyle(CTW.ink)
                Text(WeeklyView.deltaText(delta)).font(.caption.weight(.semibold)).monospacedDigit().foregroundStyle(CTW.muted)
            }
            Text(title).font(.system(size: 10.5, weight: .medium)).foregroundStyle(CTW.muted)
        }
        .ctwCard(padding: 12)
        .accessibilityElement(children: .combine)
    }
}

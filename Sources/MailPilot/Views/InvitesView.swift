import SwiftUI

enum InviteTab: String, CaseIterable, Identifiable {
    case new, added, dismissed
    var id: String { rawValue }
    var label: String {
        switch self {
        case .new: "Neu"
        case .added: "Eingetragen"
        case .dismissed: "Ignoriert"
        }
    }
}

/// Einladungen aus Mails – mit einem Klick in den Kalender.
struct InvitesView: View {
    @EnvironmentObject var engine: Engine
    @ViewState private var tab: InviteTab = .new
    @ViewState private var scanning = false

    private var rows: [Invite] {
        engine.invites.filter { i in
            switch tab {
            case .new: i.status == "new" && i.event.end > Date()
            case .added: i.status == "added"
            case .dismissed: i.status == "dismissed" || (i.status == "new" && i.event.end <= Date())
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        Eyebrow(text: "Aufräumen", number: "10")
                        Text("Einladungen").font(.system(size: 28, weight: .bold)).foregroundStyle(CTW.ink)
                        Text("Termine aus Kalendereinladungen in deinen Mails.").foregroundStyle(CTW.muted)
                    }
                    Spacer()
                    if scanning { ProgressView().controlSize(.small) }
                    Button { Task { scanning = true; await engine.scanInvites(limit: 25); scanning = false } } label: {
                        Label("Jetzt suchen", systemImage: "magnifyingglass")
                    }
                    .buttonStyle(.ctwSecondary)
                    .disabled(scanning)
                }
                Picker("", selection: $tab) { ForEach(InviteTab.allCases) { Text($0.label).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 360)
                if engine.settings.calendarID.isEmpty {
                    Label("Wähle unter Einstellungen → Fristen einen Kalender, damit sich Termine eintragen lassen.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(CTW.action).ctwCard(padding: 12)
                }
                if rows.isEmpty {
                    ContentUnavailableView(tab == .new ? "Keine neuen Einladungen" : "Nichts hier", systemImage: "calendar.badge.plus",
                                           description: Text("MailPilot sucht in Mails der letzten 30 Tage mit einladungstypischem Betreff nach Kalenderanhängen."))
                        .foregroundStyle(CTW.muted).ctwCard(padding: 24)
                }
                ForEach(rows) { inv in row(inv) }
            }
            .padding(24)
            .frame(maxWidth: 1500, alignment: .leading)
        }
        .background(CTW.bg)
    }

    private func clash(_ i: Invite) -> Bool {
        guard i.status == "new", !i.event.allDay, CalendarAvailability.shared.isAuthorized else { return false }
        return !CalendarAvailability.shared.busy(from: i.event.start, to: i.event.end, calendarIDs: []).isEmpty
    }

    private func when(_ e: InviteEvent) -> String {
        if e.allDay { return e.start.formatted(date: .complete, time: .omitted) + " (ganztägig)" }
        return e.start.formatted(date: .complete, time: .shortened) + " – " + e.end.formatted(date: .omitted, time: .shortened)
    }

    private func row(_ i: Invite) -> some View {
        HStack(alignment: .top, spacing: 12) {
            IconTile(symbol: i.event.cancelled ? "calendar.badge.minus" : "calendar", color: i.event.cancelled ? CTW.action : CTW.accent, size: 34)
            VStack(alignment: .leading, spacing: 4) {
                Text(i.event.summary).fontWeight(.semibold).foregroundStyle(CTW.ink)
                Text(when(i.event)).foregroundStyle(CTW.ink)
                if !i.event.location.isEmpty { Label(i.event.location, systemImage: "mappin.and.ellipse").font(.caption).foregroundStyle(CTW.muted) }
                if !i.event.organizer.isEmpty { Label(i.event.organizer, systemImage: "person.fill").font(.caption).foregroundStyle(CTW.muted) }
                HStack(spacing: 6) {
                    if i.event.cancelled { Badge(text: "Abgesagt", color: CTW.action, symbol: "xmark.circle.fill") }
                    if i.event.recurring { Badge(text: "wiederkehrend – nur der erste Termin", color: CTW.grey500, symbol: "repeat") }
                    if clash(i) { Badge(text: "Überschneidet sich mit einem Termin", color: CTW.action, symbol: "exclamationmark.triangle.fill") }
                    if i.status == "added" { Badge(text: "im Kalender", color: CTW.teal700, symbol: "checkmark") }
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                if i.status == "new" && !i.event.cancelled {
                    Button { Task { await engine.addInvite(i) } } label: { Label("In Kalender eintragen", systemImage: "calendar.badge.plus") }
                        .buttonStyle(.ctwPrimary)
                        .disabled(engine.settings.calendarID.isEmpty)
                    Button("Ignorieren") { engine.dismissInvite(i) }.buttonStyle(.ctwSecondary)
                } else if i.status == "dismissed" {
                    Button("Wieder anzeigen") { engine.dismissInvite(i, restore: true) }.buttonStyle(.ctwSecondary)
                } else if i.event.cancelled && i.status == "new" {
                    Button("Ausblenden") { engine.dismissInvite(i) }.buttonStyle(.ctwSecondary)
                }
                do {
                    Button { engine.openMessage(messageId: i.messageId) } label: { Label("Mail", systemImage: "envelope.open") }.buttonStyle(.borderless).foregroundStyle(CTW.accent)
                }
            }
        }
        .ctwCard()
    }
}

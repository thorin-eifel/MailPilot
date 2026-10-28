import SwiftUI

enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
    case briefing, needsReply, waiting, snoozed, all, invoices, rules, activity, settings

    var id: String { rawValue }

    var label: String {
        switch self {
        case .briefing: "Briefing"
        case .needsReply: "Antwort nötig"
        case .waiting: "Warte auf Antwort"
        case .snoozed: "Zurückgestellt"
        case .all: "Alle Gespräche"
        case .invoices: "Rechnungen"
        case .rules: "Regeln & VIP"
        case .activity: "Aktivität"
        case .settings: "Einstellungen"
        }
    }

    var symbol: String {
        switch self {
        case .briefing: "sun.horizon.fill"
        case .needsReply: "arrowshape.turn.up.left.fill"
        case .waiting: "hourglass"
        case .snoozed: "moon.zzz.fill"
        case .all: "bubble.left.and.bubble.right.fill"
        case .invoices: "eurosign.circle.fill"
        case .rules: "slider.horizontal.3"
        case .activity: "list.bullet.rectangle.fill"
        case .settings: "gearshape.fill"
        }
    }
}

struct DashboardView: View {
    @EnvironmentObject var engine: Engine
    @ViewState private var selection: SidebarItem?

    init(initial: SidebarItem = .needsReply) {
        _selection = ViewState(initialValue: initial)
    }

    var body: some View {
        NavigationSplitView {
            // Navigation = Glas (System-Seitenleiste), Inhalte = deckende Flächen.
            List(selection: $selection) {
                Section {
                    row(.briefing, count: nil)
                }
                Section {
                    row(.needsReply, count: engine.needsReply.count)
                    row(.waiting, count: engine.waiting.count)
                    row(.snoozed, count: engine.snoozed.count)
                    row(.all, count: nil)
                } header: {
                    Eyebrow(text: "Gespräche")
                }
                Section {
                    row(.invoices, count: engine.invoiceAlertCount)
                } header: {
                    Eyebrow(text: "Belege")
                }
                Section {
                    row(.rules, count: engine.suggestions.count)
                    row(.activity, count: nil)
                    row(.settings, count: nil)
                } header: {
                    Eyebrow(text: "System")
                }
            }
            .navigationSplitViewColumnWidth(min: 210, ideal: 230)
            .safeAreaInset(edge: .top) {
                HStack(spacing: 8) {
                    CTWLogo(height: 20)
                    Text("MailPilot").font(.system(size: 13, weight: .semibold)).foregroundStyle(CTW.ink)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .safeAreaInset(edge: .bottom) { statusPanel }
        } detail: {
            ZStack {
                CTW.bg.ignoresSafeArea()
                switch selection ?? .needsReply {
                case .briefing: BriefingView()
                case .needsReply: ThreadsView(filter: .needsReply)
                case .waiting: ThreadsView(filter: .waiting)
                case .snoozed: ThreadsView(filter: nil, snoozedOnly: true)
                case .all: ThreadsView(filter: nil)
                case .invoices: InvoicesView()
                case .rules: RulesView()
                case .activity: ActivityView()
                case .settings: SettingsView()
                }
            }
        }
        .tint(CTW.accent)
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await engine.runCycle() }
                } label: {
                    Label("Jetzt prüfen", systemImage: "arrow.clockwise")
                }
                .disabled(engine.isRunning)
                .help("Jetzt prüfen")
            }
        }
    }

    private func row(_ item: SidebarItem, count: Int?) -> some View {
        Label {
            Text(item.label)
        } icon: {
            Image(systemName: item.symbol).foregroundStyle(item == .needsReply ? CTW.action : CTW.accent)
        }
        .badge(count ?? 0)
        .tag(item)
    }

    private var statusPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let p = engine.initialProgress {
                HStack {
                    Image(systemName: "tray.full.fill").foregroundStyle(CTW.accent)
                    Text("Erstscan").fontWeight(.semibold).foregroundStyle(CTW.ink)
                    Spacer()
                    Text("\(Int(p.fraction * 100)) %").monospacedDigit().foregroundStyle(CTW.muted)
                }
                ProgressView(value: p.fraction).tint(CTW.accent)
                Text("\(p.analyzed)/\(p.total) analysiert · \(p.moved) einsortiert").foregroundStyle(CTW.muted)
            } else {
                HStack(spacing: 6) {
                    if engine.isRunning {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: engine.paused ? "pause.circle.fill" : "checkmark.circle.fill")
                            .foregroundStyle(engine.paused ? CTW.grey500 : CTW.teal700)
                    }
                    Text(engine.status).lineLimit(2).foregroundStyle(CTW.muted)
                }
            }
            if let err = engine.lastError {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(CTW.action).lineLimit(4)
            }
            if engine.settings.dryRun {
                Badge(text: "Probelauf aktiv", color: CTW.accent, symbol: "testtube.2")
            }
        }
        .font(.caption)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ctwGlass()
        .padding(10)
    }
}

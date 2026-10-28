import SwiftUI

enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
    case briefing, needsReply, waiting, all, activity, settings

    var id: String { rawValue }

    var label: String {
        switch self {
        case .briefing: "Briefing"
        case .needsReply: "Antwort nötig"
        case .waiting: "Warte auf Antwort"
        case .all: "Alle Gespräche"
        case .activity: "Aktivität"
        case .settings: "Einstellungen"
        }
    }

    var symbol: String {
        switch self {
        case .briefing: "sun.max"
        case .needsReply: "arrowshape.turn.up.left"
        case .waiting: "hourglass"
        case .all: "bubble.left.and.bubble.right"
        case .activity: "list.bullet.rectangle"
        case .settings: "gearshape"
        }
    }
}

struct DashboardView: View {
    @EnvironmentObject var engine: Engine
    @ViewState private var selection: SidebarItem? = .needsReply

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section {
                    row(.briefing, count: nil)
                }
                Section("Gespräche") {
                    row(.needsReply, count: engine.needsReply.count)
                    row(.waiting, count: engine.waiting.count)
                    row(.all, count: nil)
                }
                Section {
                    row(.activity, count: nil)
                    row(.settings, count: nil)
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
            .safeAreaInset(edge: .bottom) { statusBar }
        } detail: {
            switch selection ?? .needsReply {
            case .briefing: BriefingView()
            case .needsReply: ThreadsView(filter: .needsReply)
            case .waiting: ThreadsView(filter: .waiting)
            case .all: ThreadsView(filter: nil)
            case .activity: ActivityView()
            case .settings: SettingsView()
            }
        }
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await engine.runCycle() }
                } label: {
                    Label("Jetzt prüfen", systemImage: "arrow.clockwise")
                }
                .disabled(engine.isRunning)
            }
        }
    }

    private func row(_ item: SidebarItem, count: Int?) -> some View {
        Label(item.label, systemImage: item.symbol)
            .badge(count ?? 0)
            .tag(item)
    }

    private var statusBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if engine.isRunning { ProgressView().controlSize(.mini) }
                Text(engine.status).lineLimit(2)
            }
            if let err = engine.lastError {
                Text(err).foregroundStyle(.red).lineLimit(4)
            }
            if engine.settings.dryRun {
                Label("Probelauf aktiv", systemImage: "testtube.2").foregroundStyle(.orange)
            }
        }
        .font(.caption)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

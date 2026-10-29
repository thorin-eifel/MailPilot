import SwiftUI

enum NewsletterTab: String, CaseIterable, Identifiable {
    case open, done, dismissed
    var id: String { rawValue }
    var label: String {
        switch self {
        case .open: "Vorschläge"
        case .done: "Abbestellt"
        case .dismissed: "Behalten"
        }
    }
}

/// Newsletter, die du nie öffnest – Abbestellen mit einem Klick.
struct NewsletterView: View {
    @EnvironmentObject var engine: Engine
    @ViewState private var tab: NewsletterTab = .open
    @ViewState private var rows: [NewsletterCandidate] = []
    @ViewState private var loading = false
    @ViewState private var confirming: NewsletterCandidate?
    @ViewState private var message: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                Picker("", selection: $tab) {
                    ForEach(NewsletterTab.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 360)
                if let message {
                    Label(message, systemImage: "info.circle.fill").foregroundStyle(CTW.accent).ctwCard(padding: 12)
                }
                if rows.isEmpty {
                    ContentUnavailableView(emptyTitle, systemImage: "envelope.badge", description: Text(emptyText))
                        .foregroundStyle(CTW.muted)
                        .ctwCard(padding: 24)
                }
                ForEach(rows) { c in row(c) }
                Text("Als „gelesen“ gilt, was in Apple Mail als gelesen markiert ist (auch durch die Vorschau). MailPilot meldet nie von sich aus ab – erst auf deinen Klick.")
                    .font(.caption).foregroundStyle(CTW.muted)
            }
            .padding(24)
            .frame(maxWidth: 1500, alignment: .leading)
        }
        .background(CTW.bg)
        .task(id: tab) { await load() }
        .confirmationDialog(confirming.map { "„\($0.name)“ abbestellen?" } ?? "", isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
                            titleVisibility: .visible) {
            if let c = confirming {
                Button(confirmLabel(c), role: .destructive) { Task { await run(c) } }
            }
            Button("Abbrechen", role: .cancel) { confirming = nil }
        } message: {
            if let c = confirming { Text(confirmText(c)) }
        }
    }

    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                Eyebrow(text: "Aufräumen", number: "09")
                Text("Newsletter").font(.system(size: 28, weight: .bold)).foregroundStyle(CTW.ink)
                Text("Absender, die in 90 Tagen mehrfach schrieben und von dir nie (oder fast nie) geöffnet wurden.").foregroundStyle(CTW.muted)
            }
            Spacer()
            if loading { ProgressView().controlSize(.small) }
            Button { Task { await load(sync: true) } } label: { Label("Lesestatus abgleichen", systemImage: "arrow.triangle.2.circlepath") }
                .buttonStyle(.ctwSecondary)
                .disabled(loading)
        }
    }

    private func row(_ c: NewsletterCandidate) -> some View {
        HStack(alignment: .top, spacing: 12) {
            IconTile(symbol: tab == .done ? "checkmark.circle.fill" : "envelope.badge.fill", color: tab == .done ? CTW.teal700 : CTW.accent, size: 34)
            VStack(alignment: .leading, spacing: 4) {
                Text(c.name).fontWeight(.semibold).foregroundStyle(CTW.ink)
                Text(c.email).font(.caption).foregroundStyle(CTW.muted)
                HStack(spacing: 6) {
                    if tab == .open {
                        Badge(text: "\(c.total) Mails · \(c.read) geöffnet", color: CTW.accent, symbol: "envelope.open")
                        Badge(text: String(format: "%.0f pro Monat", c.perMonth), color: CTW.grey500, symbol: "calendar")
                    }
                    if let d = c.doneDate { Badge(text: "abbestellt \(d.formatted(date: .abbreviated, time: .omitted))", color: CTW.teal700, symbol: "checkmark") }
                    if c.afterDone > 0 { Badge(text: "\(c.afterDone) Mails danach", color: CTW.action, symbol: "exclamationmark.triangle.fill") }
                    methodBadge(c.option)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                if tab == .open {
                    Button { confirming = c } label: { Label("Abbestellen …", systemImage: "xmark.bin") }
                        .buttonStyle(.ctwPrimary)
                        .disabled((c.option?.method ?? UnsubOption.Method.none) == UnsubOption.Method.none)
                    Button("Behalten") { engine.dismissNewsletter(c); Task { await load() } }.buttonStyle(.ctwSecondary)
                } else if tab == .dismissed {
                    Button("Wieder vorschlagen") { engine.restoreNewsletter(c); Task { await load() } }.buttonStyle(.ctwSecondary)
                }
            }
        }
        .ctwCard()
    }

    @ViewBuilder
    private func methodBadge(_ o: UnsubOption?) -> some View {
        if let method = o?.method {
            switch method {
            case .oneClick: Badge(text: "Ein-Klick", color: CTW.teal700, symbol: "hand.tap.fill")
            case .link: Badge(text: "Über Webseite", color: CTW.teal700, symbol: "safari")
            case .mailto: Badge(text: "Per E-Mail", color: CTW.teal700, symbol: "envelope")
            case .none: Badge(text: "Keine Abmeldung gefunden", color: CTW.grey500, symbol: "questionmark.circle")
            }
        } else {
            Badge(text: "wird ermittelt …", color: CTW.grey500, symbol: "hourglass")
        }
    }

    private func confirmLabel(_ c: NewsletterCandidate) -> String {
        switch c.option?.method {
        case .oneClick: "Jetzt abbestellen"
        case .link: "Abmelde-Seite öffnen"
        case .mailto: "Abmelde-Mail vorbereiten"
        default: "OK"
        }
    }

    private func confirmText(_ c: NewsletterCandidate) -> String {
        let host = c.option.flatMap { URL(string: $0.target)?.host } ?? ""
        switch c.option?.method {
        case .oneClick: return "MailPilot sendet eine Abmelde-Anfrage (ohne Cookies und ohne deine Daten) an \(host). Das lässt sich nicht zurücknehmen."
        case .link: return "Die Abmelde-Seite von \(host) öffnet sich im Browser; dort bestätigst du selbst."
        case .mailto: return "In Mail öffnet sich eine Nachricht an \(c.option.flatMap { UnsubOption.parseMailto($0.target)?.address } ?? "den Absender"). Gesendet wird erst, wenn du auf Senden klickst."
        default: return ""
        }
    }

    private var emptyTitle: String {
        switch tab {
        case .open: "Keine Vorschläge"
        case .done: "Noch nichts abbestellt"
        case .dismissed: "Nichts ausgeblendet"
        }
    }

    private var emptyText: String {
        tab == .open ? "Vorschläge entstehen, wenn ein Absender in 90 Tagen mindestens 4 Mails schickte und du sie nicht geöffnet hast. Der Lesestatus wird stündlich abgeglichen."
            : "Hier erscheinen die Absender, die du \(tab == .done ? "abbestellt" : "behalten") hast."
    }

    private func load(sync: Bool = false) async {
        loading = true
        if sync { await engine.syncReadState() }
        let status = tab.rawValue
        rows = engine.newsletterCandidates(status: status)
        if tab == .open { await engine.resolveUnsubscribeOptions(for: rows); rows = engine.newsletterCandidates(status: status) }
        loading = false
    }

    private func run(_ c: NewsletterCandidate) async {
        confirming = nil
        switch await engine.unsubscribe(c) {
        case .done(let m), .opened(let m): message = m
        case .failed(let m): message = m
        }
        await load()
    }
}

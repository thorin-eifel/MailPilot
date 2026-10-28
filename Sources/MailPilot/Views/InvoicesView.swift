import SwiftUI
import UniformTypeIdentifiers

enum InvoiceFilter: String, CaseIterable, Identifiable {
    case open, paid, all, check

    var id: String { rawValue }

    var label: String {
        switch self {
        case .open: "Offen"
        case .paid: "Bezahlt"
        case .all: "Alle"
        case .check: "Prüfen"
        }
    }

    func includes(_ i: Invoice) -> Bool {
        switch self {
        case .open: i.isOpen
        case .paid: i.status == "ok" && i.paid
        case .all: i.status == "ok"
        case .check: i.status != "ok"
        }
    }
}

/// Aus Mails und PDF-Anhängen ausgelesene Rechnungen – mit CSV-Export für die Buchhaltung.
struct InvoicesView: View {
    @EnvironmentObject var engine: Engine
    @ViewState private var filter: InvoiceFilter = .open
    @ViewState private var search = ""
    @ViewState private var selection = Set<String>()
    @ViewState private var editing: Invoice?
    @ViewState private var confirmRemove = false

    private var rows: [Invoice] {
        engine.invoices.filter { i in
            filter.includes(i) && (search.isEmpty
                || i.vendor.localizedCaseInsensitiveContains(search) || i.subject.localizedCaseInsensitiveContains(search)
                || (i.number ?? "").localizedCaseInsensitiveContains(search) || i.description.localizedCaseInsensitiveContains(search))
        }
    }

    private var ok: [Invoice] { engine.invoices.filter { $0.status == "ok" } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            tiles
            controls
            table
            if !selection.isEmpty { selectionBar }
        }
        .padding(20)
        .background(CTW.bg)
        .sheet(item: $editing) { InvoiceEditSheet(invoice: $0).environmentObject(engine) }
        .confirmationDialog("\(selection.count) Einträge entfernen?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Entfernen", role: .destructive) { engine.removeInvoices(Array(selection)); selection = [] }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Die Mails bleiben unverändert; nur die ausgelesenen Daten werden gelöscht. MailPilot liest diese Mails nicht erneut aus.")
        }
    }

    // MARK: Kopf und Kennzahlen

    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                Eyebrow(text: "Belege", number: "06")
                Text("Rechnungen").font(.system(size: 28, weight: .bold)).foregroundStyle(CTW.ink)
                Text("Betrag, Fälligkeit und Aussteller aus Mails der Kategorie „\(engine.settings.invoiceCategory)“ und ihren PDF-Anhängen.")
                    .foregroundStyle(CTW.muted)
            }
            Spacer()
            if engine.invoiceBusy { ProgressView().controlSize(.small) }
            if engine.invoiceQueue > 0 {
                Button { Task { await engine.extractAllInvoices() } } label: {
                    Label("\(engine.invoiceQueue) auslesen", systemImage: "doc.text.magnifyingglass")
                }
                .buttonStyle(.ctwPrimary)
                .disabled(engine.invoiceBusy)
            }
            Button(action: exportCSV) { Label("CSV exportieren …", systemImage: "square.and.arrow.up") }
                .buttonStyle(.ctwSecondary)
                .disabled(filter == .check || rows.isEmpty)
        }
    }

    private var tiles: some View {
        let open = ok.filter(\.isOpen)
        let overdue = open.filter { $0.isOverdue() }
        let soon = open.filter { $0.isDue(within: 7) }
        let month = ok.filter { i in
            let d = Deadlines.parse(i.issueDate) ?? i.mailDate
            return Calendar.current.isDate(d, equalTo: Date(), toGranularity: .month)
        }
        return HStack(spacing: 12) {
            MoneyTile(title: "Offen", amount: Money.summary(Money.totals(open)), detail: "\(open.count) Rechnungen",
                      symbol: "tray.full.fill", color: CTW.accent)
            MoneyTile(title: "Überfällig", amount: Money.summary(Money.totals(overdue)), detail: "\(overdue.count) Rechnungen",
                      symbol: "clock.badge.exclamationmark.fill", color: CTW.action)
            MoneyTile(title: "Fällig in 7 Tagen", amount: Money.summary(Money.totals(soon)), detail: "\(soon.count) Rechnungen",
                      symbol: "calendar.badge.clock", color: CTW.teal700)
            MoneyTile(title: "Dieser Monat", amount: Money.summary(Money.totals(month)), detail: "\(month.count) Rechnungen",
                      symbol: "eurosign.circle.fill", color: CTW.teal700)
        }
    }

    private var controls: some View {
        HStack {
            Picker("", selection: $filter) {
                ForEach(InvoiceFilter.allCases) { f in
                    Text(f == .check && engine.invoices.contains { $0.status != "ok" }
                         ? "Prüfen (\(engine.invoices.filter { $0.status != "ok" }.count))" : f.label).tag(f)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 360)
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(CTW.muted)
                TextField("Aussteller, Nummer oder Betreff", text: $search).textFieldStyle(.plain).frame(width: 240)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(CTW.surface, in: RoundedRectangle(cornerRadius: CTW.radius))
            .overlay(RoundedRectangle(cornerRadius: CTW.radius).strokeBorder(CTW.line))
        }
    }

    // MARK: Tabelle

    private var table: some View {
        Table(rows, selection: $selection) {
            TableColumn("Fällig") { i in
                HStack(spacing: 4) {
                    if i.isOverdue() { Image(systemName: "exclamationmark.circle.fill").foregroundStyle(CTW.action) }
                    Text(Self.date(i.dueDate)).foregroundStyle(i.isOverdue() ? CTW.action : CTW.ink)
                }
            }
            .width(min: 90, ideal: 100)
            TableColumn("Aussteller") { i in
                VStack(alignment: .leading, spacing: 1) {
                    Text(i.vendor).fontWeight(.semibold).foregroundStyle(CTW.ink).lineLimit(1)
                    if !i.description.isEmpty { Text(i.description).font(.caption).foregroundStyle(CTW.muted).lineLimit(1) }
                }
            }
            .width(min: 160, ideal: 260)
            TableColumn("Betrag") { i in
                Text(i.amount.map { Money.format($0, currency: i.currency) } ?? "–")
                    .monospacedDigit().fontWeight(.medium).foregroundStyle(CTW.ink)
            }
            .width(min: 90, ideal: 110)
            TableColumn("Nr.") { i in Text(i.number ?? "–").foregroundStyle(CTW.muted).lineLimit(1) }
                .width(min: 70, ideal: 100)
            TableColumn("Datum") { i in Text(Self.date(i.issueDate)).foregroundStyle(CTW.muted) }
                .width(min: 80, ideal: 90)
            TableColumn("Status") { i in statusBadge(i) }
                .width(min: 110, ideal: 130)
            TableColumn("Quelle") { i in
                Image(systemName: i.source == "pdf" ? "doc.richtext.fill" : "envelope.fill")
                    .foregroundStyle(CTW.accent)
                    .help(i.source == "pdf" ? "Aus dem PDF-Anhang gelesen" : "Nur aus dem Mailtext gelesen")
            }
            .width(50)
        }
        .scrollContentBackground(.hidden)
        .background(CTW.surface)
        .clipShape(RoundedRectangle(cornerRadius: CTW.radius))
        .overlay(RoundedRectangle(cornerRadius: CTW.radius).strokeBorder(CTW.lineSoft))
        .overlay {
            if rows.isEmpty {
                ContentUnavailableView(emptyText, systemImage: "doc.text.magnifyingglass").foregroundStyle(CTW.muted)
            }
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if !ids.isEmpty { actions(for: Array(ids)) }
        } primaryAction: { ids in
            if let id = ids.first, let i = engine.invoices.first(where: { $0.id == id }) { editing = i }
        }
    }

    private var emptyText: String {
        if engine.invoices.isEmpty {
            return engine.invoiceQueue > 0 ? "Noch nichts ausgelesen – oben auf „auslesen“ klicken." : "Noch keine Rechnungen erkannt."
        }
        return filter == .open ? "Keine offenen Rechnungen." : "Keine Einträge."
    }

    @ViewBuilder
    private func statusBadge(_ i: Invoice) -> some View {
        switch i.status {
        case "failed": Badge(text: "Fehler", color: CTW.action, symbol: "exclamationmark.triangle.fill")
        case "not_invoice": Badge(text: "Keine Rechnung", color: CTW.grey500, symbol: "questionmark.circle")
        default:
            if i.paid { Badge(text: "Bezahlt", color: CTW.teal700, symbol: "checkmark.circle.fill") }
            else if i.isOverdue() { Badge(text: "Überfällig", color: CTW.action, symbol: "clock.badge.exclamationmark") }
            else { Badge(text: "Offen", color: CTW.accent, symbol: "circle") }
        }
    }

    // MARK: Aktionen

    @ViewBuilder
    private func actions(for ids: [String]) -> some View {
        let list = engine.invoices.filter { ids.contains($0.id) }
        if list.contains(where: { $0.status == "ok" && !$0.paid }) {
            Button { engine.setInvoicePaid(ids, paid: true) } label: { Label("Als bezahlt markieren", systemImage: "checkmark.circle") }
        }
        if list.contains(where: \.paid) {
            Button { engine.setInvoicePaid(ids, paid: false) } label: { Label("Wieder auf offen setzen", systemImage: "arrow.uturn.backward") }
        }
        if ids.count == 1, let i = list.first {
            Button { editing = i } label: { Label("Bearbeiten …", systemImage: "pencil") }
            do {
                Button { engine.openMessage(messageId: i.messageId) } label: { Label("Mail öffnen", systemImage: "envelope.open") }
            }
            Button { Task { await engine.reextractInvoice(i.id) } } label: { Label("Neu auslesen", systemImage: "arrow.clockwise") }
        }
        Divider()
        Button(role: .destructive) { selection = Set(ids); confirmRemove = true } label: { Label("Entfernen", systemImage: "trash") }
    }

    private var selectionBar: some View {
        HStack(spacing: 10) {
            Text("\(selection.count) ausgewählt").foregroundStyle(CTW.muted)
            Spacer()
            let list = engine.invoices.filter { selection.contains($0.id) }
            if list.contains(where: { $0.status == "ok" && !$0.paid }) {
                Button { engine.setInvoicePaid(Array(selection), paid: true) } label: { Label("Bezahlt", systemImage: "checkmark.circle") }
                    .buttonStyle(.ctwPrimary)
            }
            if list.contains(where: \.paid) {
                Button { engine.setInvoicePaid(Array(selection), paid: false) } label: { Label("Offen", systemImage: "arrow.uturn.backward") }
                    .buttonStyle(.ctwSecondary)
            }
            if selection.count == 1, let i = list.first {
                Button { editing = i } label: { Label("Bearbeiten", systemImage: "pencil") }.buttonStyle(.ctwSecondary)
                Button { Task { await engine.reextractInvoice(i.id) } } label: { Label("Neu auslesen", systemImage: "arrow.clockwise") }
                    .buttonStyle(.ctwSecondary)
            }
            Button(role: .destructive) { confirmRemove = true } label: { Label("Entfernen", systemImage: "trash") }
                .buttonStyle(.ctwSecondary)
        }
        .padding(10)
        .ctwGlass()
    }

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "Rechnungen-\(Deadlines.format(Date())).csv"
        panel.message = "Exportiert die aktuell angezeigten Rechnungen (Semikolon-getrennt, für Excel und Buchhaltungsprogramme)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try InvoiceCSV.make(rows).write(to: url, atomically: true, encoding: .utf8)
            engine.status = "\(rows.count) Rechnungen exportiert: \(url.lastPathComponent)"
        } catch {
            engine.lastError = "CSV konnte nicht gespeichert werden: \(error.localizedDescription)"
        }
    }

    private static func date(_ iso: String?) -> String {
        Deadlines.parse(iso).map { $0.formatted(date: .numeric, time: .omitted) } ?? "–"
    }
}

struct MoneyTile: View {
    let title: String
    let amount: String
    let detail: String
    let symbol: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: symbol).foregroundStyle(color)
                Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(CTW.muted)
            }
            Text(amount).font(.system(size: 20, weight: .bold, design: .rounded)).monospacedDigit().foregroundStyle(CTW.ink)
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(detail).font(.caption).foregroundStyle(CTW.muted)
        }
        .ctwCard(padding: 12)
        .accessibilityElement(children: .combine)
    }
}

/// Ausgelesene Werte prüfen und korrigieren.
struct InvoiceEditSheet: View {
    @EnvironmentObject var engine: Engine
    @Environment(\.dismiss) private var dismiss
    @ViewState private var inv: Invoice
    @ViewState private var amountText: String
    @ViewState private var vatText: String
    @ViewState private var hasIssue: Bool
    @ViewState private var hasDue: Bool
    @ViewState private var issue: Date
    @ViewState private var due: Date

    init(invoice: Invoice) {
        _inv = ViewState(initialValue: invoice)
        _amountText = ViewState(initialValue: invoice.amount.map { String(format: "%.2f", $0).replacingOccurrences(of: ".", with: ",") } ?? "")
        _vatText = ViewState(initialValue: invoice.vat.map { String(format: "%.2f", $0).replacingOccurrences(of: ".", with: ",") } ?? "")
        _hasIssue = ViewState(initialValue: Deadlines.parse(invoice.issueDate) != nil)
        _hasDue = ViewState(initialValue: Deadlines.parse(invoice.dueDate) != nil)
        _issue = ViewState(initialValue: Deadlines.parse(invoice.issueDate) ?? Date())
        _due = ViewState(initialValue: Deadlines.parse(invoice.dueDate) ?? Date())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Eyebrow(text: "Rechnung prüfen")
            Text(inv.subject).font(.caption).foregroundStyle(CTW.muted).lineLimit(2)
            Form {
                TextField("Aussteller", text: $inv.vendor)
                TextField("Rechnungsnummer", text: Binding(get: { inv.number ?? "" }, set: { inv.number = $0.isEmpty ? nil : $0 }))
                HStack {
                    TextField("Betrag brutto", text: $amountText)
                    TextField("Währung", text: $inv.currency).frame(width: 70)
                }
                TextField("davon USt", text: $vatText)
                Toggle("Rechnungsdatum", isOn: $hasIssue)
                if hasIssue { DatePicker("", selection: $issue, displayedComponents: .date).labelsHidden() }
                Toggle("Fälligkeit", isOn: $hasDue)
                if hasDue { DatePicker("", selection: $due, displayedComponents: .date).labelsHidden() }
                TextField("Beschreibung", text: $inv.description)
                Toggle("Bezahlt", isOn: $inv.paid)
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            HStack {
                Spacer()
                Button("Abbrechen") { dismiss() }.buttonStyle(.ctwSecondary).keyboardShortcut(.cancelAction)
                Button {
                    inv.amount = Money.parse(amountText)
                    inv.vat = Money.parse(vatText)
                    inv.currency = inv.currency.isEmpty ? "EUR" : inv.currency.uppercased()
                    inv.issueDate = hasIssue ? Deadlines.format(issue) : nil
                    inv.dueDate = hasDue ? Deadlines.format(due) : nil
                    engine.updateInvoice(inv)
                    dismiss()
                } label: { Label("Speichern", systemImage: "checkmark") }
                    .buttonStyle(.ctwPrimary)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .background(CTW.surface)
    }
}

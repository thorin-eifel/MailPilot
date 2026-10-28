import Foundation

/// Rechnungen aus Mails und PDF-Anhängen auslesen.
extension Engine {
    /// Rechnungen, die überfällig oder in den nächsten 7 Tagen fällig sind.
    var invoiceAlertCount: Int {
        invoices.filter { $0.isOverdue() || $0.isDue(within: 7) }.count
    }

    /// Liest eine Mail aus: PDF-Anhänge speichern, Text ziehen (bei Scans per OCR), Claude extrahiert die Felder.
    /// Wirft nur bei Problemen, die jeden weiteren Aufruf treffen würden (Login, Limit); sonst wird `failed` gespeichert.
    private func buildInvoice(for m: StoredMessage, claude: ClaudeClient) async throws -> Invoice {
        var inv = Invoice(messageId: m.messageId, threadKey: m.threadKey, account: m.account, sender: m.sender,
                          senderEmail: m.senderEmail, subject: m.subject, mailDate: m.date, vendor: m.senderName, number: nil,
                          amount: nil, vat: nil, currency: "EUR", issueDate: nil, dueDate: nil, description: "", source: "mail",
                          fileName: nil, paid: false, status: "ok", error: nil)

        let tmp = Paths.appSupport.appendingPathComponent("tmp/\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        var pdfs: [(name: String, text: String)] = []
        // Lässt sich die Mail oder der Anhang nicht lesen (z. B. Ordner nicht zurücklesbar), bleibt der Mailtext als Quelle.
        if let infos = try? await bridge.attachments(account: m.account, mailbox: m.mailbox, id: m.mailId, messageId: m.messageId, saveTo: tmp) {
            for a in infos.prefix(3) {
                guard let path = a.saved else { continue }
                let url = URL(fileURLWithPath: path)
                let text = await Task.detached { PDFText.extract(url) }.value
                if !text.isEmpty {
                    pdfs.append((a.name, text))
                    if inv.fileName == nil { inv.fileName = a.name }
                }
            }
        }

        do {
            let x = try await claude.extractInvoice(message: m, pdfs: pdfs)
            guard x.is_invoice else { inv.status = "not_invoice"; return inv }
            if let v = x.vendor?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty { inv.vendor = v }
            inv.number = x.invoice_number?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            inv.amount = x.amount_gross.flatMap { $0 >= 0 ? $0 : nil }
            inv.vat = x.vat_amount
            if let c = x.currency?.uppercased(), c.count == 3 { inv.currency = c }
            inv.issueDate = Deadlines.parse(x.issue_date) != nil ? x.issue_date : nil
            inv.dueDate = Deadlines.parse(x.due_date) != nil ? x.due_date : nil
            inv.description = String((x.description ?? "").prefix(120))
            inv.paid = x.already_paid ?? false
            inv.source = pdfs.isEmpty ? "mail" : "pdf"
        } catch let e as ClaudeError where e.isBlocking {
            throw e
        } catch {
            inv.status = "failed"
            inv.error = error.localizedDescription
        }
        return inv
    }

    private func saveInvoice(_ inv: Invoice) {
        try? store.saveInvoice(inv)
        // Die Fälligkeit wird zur Frist des Gesprächs – so landet sie bei Bedarf in Erinnerungen/Kalender.
        guard inv.status == "ok", !inv.paid, let due = inv.dueDate, let key = inv.threadKey,
              var t = try? store.thread(key), t.dueDate == nil else { return }
        t.dueDate = due
        try? store.upsert(t)
    }

    /// Verarbeitet die nächsten Mails der Rechnungs-Kategorie (je Durchlauf nur wenige).
    func extractInvoices(limit: Int = 6) async {
        guard settings.extractInvoices, initialComplete, !invoiceBusy, let claude, UsageMonitor.shared.blockReason() == nil else { return }
        let queue = (try? store.invoiceQueue(category: settings.invoiceCategory, accounts: enabledAccountNames, limit: limit)) ?? []
        guard !queue.isEmpty else { return }
        invoiceBusy = true
        defer { invoiceBusy = false; reload() }
        for (i, m) in queue.enumerated() {
            status = "Rechnung auslesen \(i + 1)/\(queue.count): \(m.subject.prefix(40))"
            do {
                saveInvoice(try await buildInvoice(for: m, claude: claude))
            } catch {
                lastError = error.localizedDescription
                return
            }
        }
    }

    /// Liest alle noch offenen Rechnungs-Mails aus (Knopf in der Rechnungsansicht).
    func extractAllInvoices() async {
        guard !invoiceBusy, let claude = claudeInteractive else { if claude == nil { lastError = ClaudeError.notFound.localizedDescription }; return }
        invoiceBusy = true
        defer { invoiceBusy = false; reload() }
        while true {
            let queue = (try? store.invoiceQueue(category: settings.invoiceCategory, accounts: enabledAccountNames, limit: 1)) ?? []
            guard let m = queue.first else { break }
            status = "Rechnung auslesen (noch \(invoiceQueue)): \(m.subject.prefix(40))"
            do {
                saveInvoice(try await buildInvoice(for: m, claude: claude))
            } catch {
                lastError = error.localizedDescription
                return
            }
            reload()
        }
        status = "Alle Rechnungen ausgelesen"
    }

    func reextractInvoice(_ id: String) async {
        guard !invoiceBusy, let claude = claudeInteractive, let m = try? store.message(id: id), !m.isPrivate else { return }
        invoiceBusy = true
        defer { invoiceBusy = false; reload() }
        try? store.deleteInvoice(id)
        do { saveInvoice(try await buildInvoice(for: m, claude: claude)) } catch { lastError = error.localizedDescription }
    }

    func setInvoicePaid(_ ids: [String], paid: Bool) {
        for id in ids { try? store.setInvoicePaid(id, paid: paid) }
        reload()
    }

    func updateInvoice(_ inv: Invoice) {
        var i = inv
        i.status = "ok"
        i.error = nil
        try? store.saveInvoice(i)
        reload()
    }

    func removeInvoices(_ ids: [String]) {
        for id in ids { try? store.deleteInvoice(id) }
        reload()
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

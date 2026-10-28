import Foundation

extension Store {
    func saveInvoice(_ i: Invoice) throws {
        try db.exec("""
            INSERT OR REPLACE INTO invoices (message_id, thread_key, account, sender, sender_email, subject, mail_date, vendor, number,
                amount, vat, currency, issue_date, due_date, description, source, file_name, paid, status, error, ts)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [i.messageId, i.threadKey, i.account, i.sender, i.senderEmail, i.subject, i.mailDate, i.vendor, i.number,
                  i.amount, i.vat, i.currency, i.issueDate, i.dueDate, i.description, i.source, i.fileName, i.paid, i.status,
                  i.error, Date()])
    }

    private func invoice(_ r: Row) -> Invoice {
        Invoice(messageId: r.string("message_id") ?? "", threadKey: r.string("thread_key"), account: r.string("account") ?? "",
                sender: r.string("sender") ?? "", senderEmail: r.string("sender_email") ?? "", subject: r.string("subject") ?? "",
                mailDate: r.date("mail_date"), vendor: r.string("vendor") ?? "", number: r.string("number"),
                amount: hasValue(r, "amount") ? r.double("amount") : nil,
                vat: hasValue(r, "vat") ? r.double("vat") : nil, currency: r.string("currency") ?? "EUR",
                issueDate: r.string("issue_date"), dueDate: r.string("due_date"), description: r.string("description") ?? "",
                source: r.string("source") ?? "mail", fileName: r.string("file_name"), paid: r.bool("paid"),
                status: r.string("status") ?? "ok", error: r.string("error"))
    }

    /// Spalte ist nicht NULL? (Row liefert für NULL keinen Eintrag.)
    private func hasValue(_ r: Row, _ key: String) -> Bool { r.hasKey(key) }

    func invoices(accounts: [String], limit: Int = 5000) throws -> [Invoice] {
        try db.query("""
            SELECT * FROM invoices WHERE account IN \(inList(accounts))
            ORDER BY COALESCE(due_date, issue_date, '9999') ASC, mail_date DESC LIMIT ?
            """, accounts + [limit]).map(invoice)
    }

    func invoice(id: String) throws -> Invoice? {
        try db.query("SELECT * FROM invoices WHERE message_id = ?", [id]).first.map(invoice)
    }

    func deleteInvoice(_ id: String) throws {
        try db.exec("DELETE FROM invoices WHERE message_id = ?", [id])
    }

    func setInvoicePaid(_ id: String, paid: Bool) throws {
        try db.exec("UPDATE invoices SET paid = ? WHERE message_id = ?", [paid, id])
    }

    /// Vom Nutzer entfernt: Die Mail wird nicht erneut ausgelesen.
    func skipInvoice(_ id: String) throws {
        try db.exec("INSERT OR IGNORE INTO invoice_skip (message_id, ts) VALUES (?, ?)", [id, Date()])
    }

    func unskipInvoice(_ id: String) throws {
        try db.exec("DELETE FROM invoice_skip WHERE message_id = ?", [id])
    }

    /// Eingegangene Mails der Rechnungs-Kategorie, die noch nicht ausgelesen wurden.
    func invoiceQueue(category: String, accounts: [String], limit: Int) throws -> [StoredMessage] {
        try db.query("""
            SELECT m.* FROM messages m LEFT JOIN invoices i ON i.message_id = m.message_id
            WHERE i.message_id IS NULL AND m.processed = 1 AND m.is_from_me = 0 AND m.is_private = 0 AND m.category = ? AND m.account IN \(inList(accounts))
            AND m.message_id NOT IN (SELECT message_id FROM invoice_skip)
            ORDER BY m.date DESC LIMIT ?
            """, [category] + accounts + [limit]).map(message)
    }

    func invoiceQueueCount(category: String, accounts: [String]) -> Int {
        ((try? db.query("""
            SELECT COUNT(*) AS n FROM messages m LEFT JOIN invoices i ON i.message_id = m.message_id
            WHERE i.message_id IS NULL AND m.processed = 1 AND m.is_from_me = 0 AND m.is_private = 0 AND m.category = ? AND m.account IN \(inList(accounts))
            AND m.message_id NOT IN (SELECT message_id FROM invoice_skip)
            """, [category] + accounts))?.first?.int("n")) ?? 0
    }
}

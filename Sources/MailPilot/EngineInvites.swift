import Foundation

/// Einladungen aus Mails (iCalendar-Anhänge) in den Kalender übernehmen.
extension Engine {
    var newInviteCount: Int { invites.filter { $0.status == "new" && !$0.event.cancelled && $0.event.end > Date() }.count }

    /// Sucht in jüngeren Mails mit einladungstypischem Betreff nach .ics-Anhängen. (nur lesend)
    func scanInvites(limit: Int = 5) async {
        guard initialComplete else { return }
        let since = Date().addingTimeInterval(-30 * 86400)
        guard let candidates = try? store.inviteCandidates(accounts: enabledAccountNames, since: since, limit: limit), !candidates.isEmpty else { return }
        for m in candidates {
            status = "Einladungen suchen: \(m.subject.prefix(40))"
            let tmp = Paths.appSupport.appendingPathComponent("tmp/\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tmp) }
            if let infos = try? await bridge.attachments(account: m.account, mailbox: m.mailbox, id: m.mailId, messageId: m.messageId, saveTo: tmp, ics: true) {
                for path in infos.compactMap(\.saved) where !path.lowercased().hasSuffix(".pdf") {
                    guard let data = FileManager.default.contents(atPath: path),
                          let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1), text.contains("BEGIN:VCALENDAR") else { continue }
                    for e in ICSParser.parse(text) {
                        try? store.saveInvite(e, messageId: m.messageId, account: m.account, subject: m.subject, mailDate: m.date)
                    }
                }
            }
            try? store.markInviteScanned(m.messageId)
        }
        reload()
        if settings.autoAddInvites, !settings.calendarID.isEmpty {
            for inv in invites where inv.status == "new" && !inv.event.cancelled && inv.event.start > Date() { _ = await addInvite(inv) }
        }
    }

    /// Trägt den Termin in den gewählten Kalender ein (jeden Termin nur einmal).
    @discardableResult
    func addInvite(_ inv: Invite) async -> Bool {
        guard !settings.calendarID.isEmpty else { lastError = "Kein Kalender gewählt (Einstellungen → Fristen)."; return false }
        let key = "invite:\(inv.event.uid)"
        let iso = ISO8601DateFormatter().string(from: inv.event.start)
        if store.hasExport(key, due: iso, kind: "calendar") {
            try? store.setInviteStatus(inv.event.uid, "added")
            reload()
            return true
        }
        do {
            let url = URL(string: "message://" + ("<\(inv.messageId)>".addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""))?.absoluteString
            let id = try await bridge.createInviteEvent(inv.event, calendarID: settings.calendarID, url: url)
            try store.addExport(key, due: iso, kind: "calendar", extId: id)
            try store.setInviteStatus(inv.event.uid, "added")
            status = "„\(inv.event.summary.prefix(40))“ in den Kalender eingetragen."
            reload()
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func dismissInvite(_ inv: Invite, restore: Bool = false) {
        try? store.setInviteStatus(inv.event.uid, restore ? "new" : "dismissed")
        reload()
    }
}

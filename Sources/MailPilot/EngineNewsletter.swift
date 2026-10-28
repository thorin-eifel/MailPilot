import AppKit
import Foundation

/// Newsletter, die du nie öffnest – mit Vorschlag zum Abbestellen.
extension Engine {
    private var newsletterCategory: String { "Newsletter" }

    /// Gleicht den Lesestatus der Newsletter-Mails der letzten 90 Tage mit Apple Mail ab (nur lesend).
    func syncReadState() async {
        let since = Date().addingTimeInterval(-Double(Newsletter.windowDays) * 86400)
        guard let msgs = try? store.newsletterMessages(category: newsletterCategory, accounts: enabledAccountNames, since: since), !msgs.isEmpty else { return }
        // Ordner, in denen die Mails jetzt liegen (Claude-Ordner oder Posteingang)
        let groups = Dictionary(grouping: msgs.filter { $0.mailbox != "(entfernt)" }, by: { MailBridge.FolderRef(account: $0.account, path: $0.mailbox) })
        let refs = Array(groups.keys)
        guard !refs.isEmpty else { return }
        for chunk in stride(from: 0, to: refs.count, by: 8).map({ Array(refs[$0..<min($0 + 8, refs.count)]) }) {
            guard let states = try? await readStatesAny(chunk) else { continue }
            for (ref, byId) in states where !byId.isEmpty {
                for m in groups[ref] ?? [] {
                    if let read = byId[m.messageId] { try? store.setRead(read, messageId: m.messageId) }
                }
            }
        }
        store.setValue(String(Date().timeIntervalSince1970), for: "readSyncDate")
    }

    /// Absender, die in 90 Tagen mehrfach schrieben und nie (oder fast nie) gelesen wurden.
    func newsletterCandidates(status: String = "open") -> [NewsletterCandidate] {
        let since = Date().addingTimeInterval(-Double(Newsletter.windowDays) * 86400)
        let stats = (try? store.newsletterStats(category: newsletterCategory, accounts: enabledAccountNames, since: since)) ?? []
        var out: [NewsletterCandidate] = []
        if status == "open" {
            for var c in stats where Newsletter.isCandidate(total: c.total, known: c.known, read: c.read) {
                if let rec = store.unsubRecord(c.email), rec.status != "open" { continue }
                if isVIP(c.email) || store.iEverWroteTo(c.email) { continue }
                c.option = store.unsubRecord(c.email)?.option ?? store.latestUnsubHeader(email: c.email).map { UnsubOption.parse(header: $0.header, post: $0.post) }
                out.append(c)
            }
            return out.sorted { $0.total != $1.total ? $0.total > $1.total : $0.lastDate > $1.lastDate }
        }
        for email in store.unsubEmails(status: status) {
            guard let rec = store.unsubRecord(email) else { continue }
            let s = stats.first { $0.email == email }
            var c = s ?? NewsletterCandidate(email: email, name: email, total: 0, read: 0, known: 0, lastDate: rec.done ?? Date(), firstDate: rec.done ?? Date(), option: nil, status: status)
            c.status = status
            c.option = rec.option
            c.doneDate = rec.done
            if let d = rec.done { c.afterDone = store.messagesSince(from: email, since: d.addingTimeInterval(7 * 86400)) }
            out.append(c)
        }
        return out
    }

    /// Ermittelt für die Vorschläge die Abmelde-Methode (aus gespeicherten Headern, sonst durch Nachlesen in Mail).
    func resolveUnsubscribeOptions(for list: [NewsletterCandidate], limit: Int = 12) async {
        var done = 0
        for c in list where c.option == nil || c.option?.method == UnsubOption.Method.none {
            if done >= limit { break }
            guard let m = store.latestMessage(from: c.email) else { continue }
            done += 1
            var option = UnsubOption.none
            if let h = store.latestUnsubHeader(email: c.email) {
                option = UnsubOption.parse(header: h.header, post: h.post)
            } else if !isClientAccount(m.account), let info = try? await bridge.unsubscribeHeader(account: m.account, mailbox: m.mailbox, id: m.mailId, messageId: m.messageId) {
                option = UnsubOption.parse(header: info.unsub, post: info.post)
            }
            try? store.saveUnsub(c.email, name: c.name, option: option)
        }
    }

    func dismissNewsletter(_ c: NewsletterCandidate) {
        try? store.saveUnsub(c.email, name: c.name, status: "dismissed")
        objectWillChange.send()
    }

    func restoreNewsletter(_ c: NewsletterCandidate) {
        try? store.saveUnsub(c.email, name: c.name, status: "open")
        objectWillChange.send()
    }

    enum UnsubResult {
        case done(String)
        case opened(String)
        case failed(String)
    }

    /// Meldet den Absender ab – auf ausdrücklichen Klick: Ein-Klick-Anfrage, E-Mail-Fenster (nicht gesendet) oder Link im Browser.
    func unsubscribe(_ c: NewsletterCandidate) async -> UnsubResult {
        guard let option = c.option, option.method != .none else { return .failed("Keine Abmelde-Möglichkeit gefunden – bitte in der Mail selbst abbestellen.") }
        switch option.method {
        case .oneClick:
            guard let url = URL(string: option.target), UnsubOption.isSafe(url) else { return .failed("Die Abmelde-Adresse wurde aus Sicherheitsgründen abgelehnt.") }
            let status = await Self.postOneClick(url)
            guard (200..<300).contains(status) else {
                return .failed(status == 0 ? "Keine Antwort vom Absender-Server." : "Der Server antwortete mit Status \(status). Bitte über den Link in der Mail abbestellen.")
            }
            try? store.saveUnsub(c.email, name: c.name, status: "done", done: Date())
            objectWillChange.send()
            return .done("Abgemeldet (Server-Antwort \(status)).")
        case .link:
            guard let url = URL(string: option.target), UnsubOption.isSafe(url) else { return .failed("Die Abmelde-Adresse wurde aus Sicherheitsgründen abgelehnt.") }
            NSWorkspace.shared.open(url)
            try? store.saveUnsub(c.email, name: c.name, status: "done", done: Date())
            objectWillChange.send()
            return .opened("Abmelde-Seite im Browser geöffnet – dort bitte bestätigen.")
        case .mailto:
            guard let mt = UnsubOption.parseMailto(option.target) else { return .failed("Die Abmelde-Adresse ist ungültig.") }
            let msg = store.latestMessage(from: c.email)
            let own = msg?.recipients.map { MailAddress.parse($0).email }.first { myAddresses.contains($0) }
            if let msg, let account = clientAccount(named: msg.account) {
                var draft = ComposeDraft(accountID: account.id)
                draft.to = mt.address; draft.subject = mt.subject; draft.body = mt.body
                await deliver(draft, save: false)
                try? store.saveUnsub(c.email, name: c.name, status: "done", done: Date())
                objectWillChange.send()
                return .opened("Abmelde-Mail vorbereitet – bitte im Postfach auf Senden klicken.")
            }
            do {
                try await bridge.compose(sender: own, to: [mt.address], subject: mt.subject, content: mt.body)
            } catch {
                return .failed(error.localizedDescription)
            }
            try? store.saveUnsub(c.email, name: c.name, status: "done", done: Date())
            objectWillChange.send()
            return .opened("Abmelde-Mail vorbereitet – bitte in Mail auf Senden klicken.")
        case .none:
            return .failed("Keine Abmelde-Möglichkeit.")
        }
    }

    /// RFC 8058: POST mit `List-Unsubscribe=One-Click`, ohne Cookies, ohne Weiterleitungen.
    private static func postOneClick(_ url: URL) async -> Int {
        final class NoRedirect: NSObject, URLSessionTaskDelegate {
            func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                            newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
        }
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.timeoutIntervalForRequest = 15
        let session = URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("List-Unsubscribe=One-Click".utf8)
        do {
            let (_, response) = try await session.data(for: req)
            return (response as? HTTPURLResponse)?.statusCode ?? 0
        } catch {
            return 0
        }
    }
}

extension Engine {
    /// Höchstens einmal pro Stunde.
    func syncReadStateIfDue() async {
        if let t = store.value("readSyncDate").flatMap(Double.init), Date().timeIntervalSince(Date(timeIntervalSince1970: t)) < 3600 { return }
        await syncReadState()
    }
}

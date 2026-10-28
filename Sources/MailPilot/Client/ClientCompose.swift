import Foundation

/// Verweis auf die Nachricht, auf die geantwortet oder die weitergeleitet wird.
struct MessageRef: Hashable {
    var account: String
    var folder: String
    var uid: UInt32
}

/// Eine Nachricht im Entstehen: Neu, Antwort, Allen antworten oder Weiterleitung.
struct ComposeDraft: Identifiable {
    enum Kind { case new, reply, forward }

    var id = UUID()
    var accountID: UUID
    var kind: Kind = .new
    var to = ""
    var cc = ""
    var bcc = ""
    var subject = ""
    var body = ""
    var attachments: [OutgoingAttachment] = []
    var inReplyTo: String?
    var references: [String] = []
    var origin: MessageRef?
    /// UID des auf dem Server gespeicherten Entwurfs (wird beim erneuten Speichern ersetzt).
    var draftUID: UInt32?

    // MARK: Fabriken

    static func prefixed(_ subject: String, with prefix: String) -> String {
        let s = subject.trimmingCharacters(in: .whitespaces)
        let lower = s.lowercased()
        if prefix == "Re:", lower.hasPrefix("re:") || lower.hasPrefix("aw:") { return s }
        if prefix == "Fwd:", lower.hasPrefix("fwd:") || lower.hasPrefix("wg:") || lower.hasPrefix("fw:") { return s }
        return s.isEmpty ? prefix : "\(prefix) \(s)"
    }

    static func quote(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map { "> \($0)" }.joined(separator: "\n")
    }

    /// Antwort: an Reply-To bzw. Absender; bei „allen“ zusätzlich alle anderen Empfänger außer dir selbst.
    static func reply(to m: ClientMessage, header: MailHeaderInfo, parsed: ParsedMessage, accountID: UUID, ownEmail: String, all: Bool) -> ComposeDraft {
        let senderRaw = header.fromName.isEmpty ? header.fromEmail : "\(header.fromName) <\(header.fromEmail)>"
        let target = header.replyTo.first ?? senderRaw
        var d = ComposeDraft(accountID: accountID, kind: .reply)
        d.to = target
        if all {
            let targetEmail = MailAddress.parse(target).email
            var seen: Set<String> = [ownEmail.lowercased(), targetEmail]
            var others: [String] = []
            for a in header.to + header.cc {
                let e = MailAddress.parse(a).email
                if e.isEmpty || seen.contains(e) { continue }
                seen.insert(e)
                others.append(a)
            }
            d.cc = others.joined(separator: ", ")
        }
        d.subject = prefixed(m.subject, with: "Re:")
        let who = header.fromName.isEmpty ? header.fromEmail : header.fromName
        d.body = "\n\nAm \(m.date.formatted(date: .long, time: .shortened)) schrieb \(who):\n" + quote(parsed.plainText)
        d.inReplyTo = header.messageId.isEmpty ? nil : header.messageId
        d.references = header.references + (header.messageId.isEmpty ? [] : [header.messageId])
        d.origin = MessageRef(account: m.account, folder: m.folder, uid: m.uid)
        return d
    }

    static func forward(_ m: ClientMessage, header: MailHeaderInfo, parsed: ParsedMessage, accountID: UUID) -> ComposeDraft {
        var d = ComposeDraft(accountID: accountID, kind: .forward)
        d.subject = prefixed(m.subject, with: "Fwd:")
        let from = header.fromName.isEmpty ? header.fromEmail : "\(header.fromName) <\(header.fromEmail)>"
        d.body = "\n\n-------- Weitergeleitete Nachricht --------\nVon: \(from)\nDatum: \(m.date.formatted(date: .long, time: .shortened))\n"
            + "Betreff: \(m.subject)\nAn: \(header.to.joined(separator: ", "))\n\n" + parsed.plainText
        d.attachments = parsed.attachments.filter { !($0.isInline && $0.mime.hasPrefix("image/") && $0.contentID != nil) }
            .map { OutgoingAttachment(name: $0.name, mime: $0.mime, data: $0.data) }
        d.origin = MessageRef(account: m.account, folder: m.folder, uid: m.uid)
        return d
    }

    func outgoing(from account: ClientAccount) -> OutgoingMessage {
        OutgoingMessage(fromName: account.displayName, fromEmail: account.email,
                        to: to.isEmpty ? [] : [to], cc: cc.isEmpty ? [] : [cc], bcc: bcc.isEmpty ? [] : [bcc],
                        subject: subject, body: body, inReplyTo: inReplyTo, references: references, attachments: attachments)
    }
}

extension ClientModel {
    func account(_ id: UUID) -> ClientAccount? { accounts.first { $0.id == id } }

    func folderPath(special: String, account: ClientAccount) -> String? {
        Engine.shared.store.clientFolders(account: account.id.uuidString).first { $0.special == special }?.path
    }

    /// Nachricht senden. Rückgabe: Fehlertext, sonst `nil`. Danach wird eine Kopie in „Gesendet“ abgelegt,
    /// das Original als beantwortet markiert und ein gespeicherter Entwurf gelöscht (nur Hinweis, falls das scheitert).
    func send(_ draft: ComposeDraft) async -> String? {
        guard let account = account(draft.accountID) else { return "Konto nicht gefunden." }
        guard let password = Keychain.password(for: account) else { return "Kein Passwort im Schlüsselbund. Konto bitte neu hinzufügen." }
        let built: MessageBuilder.Built
        do { built = try MessageBuilder.build(draft.outgoing(from: account)) } catch { return error.localizedDescription }
        do {
            // iCloud erwartet für SMTP die volle Adresse als Benutzernamen.
            try await SMTPClient.send(account.smtpConfig, user: account.email, password: password, from: account.email,
                                      recipients: built.recipients, message: built.data)
        } catch {
            return error.localizedDescription
        }
        var warnings: [String] = []
        do {
            let c = try await connectedClient(account)
            if let sent = folderPath(special: "sent", account: account) {
                do { try await c.append(sent, flags: ["\\Seen"], message: built.data) } catch { warnings.append("Kopie in „Gesendet“ nicht gespeichert (\(error.localizedDescription))") }
            } else {
                warnings.append("Kein Ordner „Gesendet“ gefunden")
            }
            if let o = draft.origin, draft.kind == .reply {
                try? await c.setFlag(o.folder, uid: o.uid, flag: "\\Answered", on: true)
            }
            if let uid = draft.draftUID, let drafts = folderPath(special: "drafts", account: account) {
                try? await c.deleteMessage(drafts, uid: uid)
            }
        } catch {
            warnings.append(error.localizedDescription)
        }
        status = warnings.isEmpty ? "Nachricht gesendet." : "Gesendet. Hinweis: " + warnings.joined(separator: "; ")
        Task { await syncSelected() }
        return nil
    }

    /// Entwurf im Ordner „Entwürfe“ speichern und eine frühere Fassung ersetzen. Rückgabe: Fehlertext oder `nil`.
    func saveDraft(_ draft: inout ComposeDraft) async -> String? {
        guard let account = account(draft.accountID) else { return "Konto nicht gefunden." }
        guard let drafts = folderPath(special: "drafts", account: account) else { return "Kein Ordner „Entwürfe“ gefunden." }
        do {
            let built = try MessageBuilder.build(draft.outgoing(from: account), requireRecipients: false)
            let c = try await connectedClient(account)
            let uid = try await c.append(drafts, flags: ["\\Draft", "\\Seen"], message: built.data)
            if let old = draft.draftUID { try? await c.deleteMessage(drafts, uid: old) }
            draft.draftUID = uid
            status = "Entwurf gespeichert."
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

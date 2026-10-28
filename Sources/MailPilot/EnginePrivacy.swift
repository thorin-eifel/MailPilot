import Foundation

/// Datenschutz-Ausnahmen: Inhalt dieser Mails geht nie an Claude.
extension Engine {
    static let privateSummary = "Vertraulich – Inhalt wird nicht an Claude gesendet."

    /// Prüft eine noch nicht analysierte Nachricht. Trifft eine Ausnahme zu – oder gehört die Mail zu einem vertraulichen
    /// Gespräch –, wird sie lokal einsortiert und nie an Claude gesendet. Rückgabe `true` = erledigt.
    func routeIfPrivate(_ m: StoredMessage, key: String) -> Bool {
        let rule = PrivacyPolicy.rule(for: m, settings: settings)
        let inherited = store.isThreadPrivate(key)
        guard rule != nil || inherited else { return false }

        // Eigene Regeln und VIP-Liste wirken weiter – sie arbeiten lokal.
        let effect = RuleEngine.evaluate(m, settings: settings)
        try? store.markPrivate(m.messageId, threadKey: key, keepBody: rule?.keepBody ?? false,
                               category: effect.category, priority: effect.priority ?? .normal, decidedBy: effect.decidedBy ?? "Datenschutz")

        let counterpart = m.isFromMe ? (m.recipients.first.map { MailAddress.parse($0).name ?? MailAddress.parse($0).email } ?? "") : m.senderName
        var t = (try? store.thread(key)) ?? MailThread(
            threadKey: key, subject: m.subject, normSubject: MailAddress.normalizeSubject(m.subject), counterpart: counterpart,
            lastDate: m.date, lastFromMe: m.isFromMe, messageCount: 0, status: .info, summary: Self.privateSummary, nextStep: "",
            dueDate: nil, priority: effect.priority ?? .normal, category: nil, draft: nil, draftFor: nil, followupNotified: false)
        t.messageCount += 1
        t.isPrivate = true
        t.summary = Self.privateSummary
        t.nextStep = ""
        t.dueDate = nil
        t.draft = nil
        t.draftFor = nil
        t.draftKind = nil
        if m.date >= t.lastDate {
            t.subject = m.subject
            t.lastDate = m.date
            t.lastFromMe = m.isFromMe
            if !counterpart.isEmpty { t.counterpart = counterpart }
        }
        if !m.isFromMe {
            t.snoozedUntil = nil
            if let c = effect.category { t.category = c }
        }
        try? store.upsert(t)
        return true
    }

    // MARK: Nachträglich anwenden

    struct PrivacyPreview {
        var messages: [StoredMessage]
        var threadKeys: Set<String>
        var rules: [UUID: PrivacyRule]
    }

    /// Bereits gespeicherte Mails, auf die inzwischen eine Ausnahme zutrifft.
    func privacyPreview() -> PrivacyPreview {
        let all = (try? store.allMessages(accounts: enabledAccountNames)) ?? []
        var hit: [StoredMessage] = []
        var keys = Set<String>()
        var rules: [UUID: PrivacyRule] = [:]
        for m in all where !m.isPrivate {
            guard let r = PrivacyPolicy.rule(for: m, settings: settings) else { continue }
            hit.append(m)
            rules[r.id] = r
            if let k = m.threadKey { keys.insert(k) }
        }
        return PrivacyPreview(messages: hit, threadKeys: keys, rules: rules)
    }

    /// Entfernt Mailtext und Zusammenfassungen bereits gespeicherter Mails, auf die eine Ausnahme zutrifft.
    func applyPrivacyRetroactively() {
        let p = privacyPreview()
        for m in p.messages {
            let rule = PrivacyPolicy.rule(for: m, settings: settings)
            try? store.markPrivate(m.messageId, threadKey: m.threadKey ?? m.messageId, keepBody: rule?.keepBody ?? false,
                                   category: m.category, priority: m.priority, decidedBy: m.decidedBy)
            try? store.deleteInvoice(m.messageId)
        }
        for key in p.threadKeys { try? store.markThreadPrivate(key) }
        reload()
        status = "Datenschutz angewendet: \(p.messages.count) Mails in \(p.threadKeys.count) Gesprächen bereinigt"
    }

    /// Schließt einen Absender dauerhaft von Claude aus und bereinigt bereits gespeicherte Mails.
    func excludeSender(_ email: String, name: String) {
        guard !email.isEmpty, !settings.privacyRules.contains(where: { $0.conditions.contains { $0.field == .sender && $0.value.lowercased() == email.lowercased() } }) else { return }
        var r = PrivacyRule()
        r.name = name.isEmpty ? email : name
        r.conditions = [RuleCondition(field: .sender, value: email)]
        settings.privacyRules.append(r)
        applyPrivacyRetroactively()
    }
}

import Foundation

/// Mögliche Änderung durch eine (neue) Regel an einer bereits gespeicherten Mail.
struct RetroChange: Identifiable {
    var message: StoredMessage
    var effect: RuleEffect
    var id: String { message.messageId }
}

/// Regeln, VIP-Liste und Lernen aus Korrekturen.
extension Engine {
    // MARK: Verschiebe-Schutz

    /// Darf MailPilot in diesem Konto Mails verschieben? Entscheidet nach gespeichertem Ergebnis, sonst anhand der
    /// bisher einsortierten Mails (lesend) und zuletzt per Probe-Mail.
    func moveGate(_ account: String) async -> MoveGate {
        // Eigener IMAP-Client: verschiebt per UID und liest Ordner zuverlässig zurück.
        if isClientAccount(account) { return .allowed }
        switch store.value("moveCheck.\(account)") {
        case "ok": return .allowed
        case "blocked": return .blocked
        default: break
        }
        if let verdict = await MoveGate.verdict(account: account, store: store, bridge: bridge, settings: settings) {
            setMoveStatus(account, verdict, detail: verdict == "ok" ? nil : "Bereits einsortierte Mails sind im Zielordner nicht zurücklesbar")
            return verdict == "ok" ? .allowed : .blocked
        }
        // Ohne Vorgeschichte wird nur nach ausdrücklicher Erlaubnis probeweise verschoben. Manche Konten (z. B. Exchange)
        // nehmen Mails in neu angelegte Ordner an, zeigen sie aber nicht an – dort würde schon die Probe eine Mail „verstecken“.
        return settings.probeMoveAccounts.contains(account) ? .canary : .blocked
    }

    func setMoveStatus(_ account: String, _ value: String?, detail: String?) {
        store.setValue(value, for: "moveCheck.\(account)")
        moveStatus[account] = value
        if value == "blocked" {
            lastError = "Konto „\(account)“: Zielordner lassen sich nicht zurücklesen – dort wird nur noch markiert, nicht verschoben."
            notify(title: "MailPilot verschiebt in „\(account)“ nicht mehr",
                   body: (detail ?? "Zielordner nicht zurücklesbar") + ". Mails werden dort nur noch markiert.", id: "movegate-\(account)")
        }
    }

    /// Prüfung zurücksetzen und neu auswerten (z. B. nach einer Änderung am Konto oder Ordner).
    func recheckMoveGate(_ account: String) async {
        store.setValue(nil, for: "moveCheck.\(account)")
        moveStatus[account] = nil
        let gate = await moveGate(account)
        status = gate == .allowed ? "„\(account)“: Zielordner zurücklesbar – Verschieben erlaubt"
            : gate == .blocked ? "„\(account)“: Zielordner nicht zurücklesbar – nur Markieren"
            : "„\(account)“: noch ungeprüft – die erste Verschiebung dient als Probe"
    }

    // MARK: Regeln verwalten

    func addRule(_ rule: UserRule) {
        settings.rules.append(rule)
    }

    func moveRule(_ id: UUID, by offset: Int) {
        guard let i = settings.rules.firstIndex(where: { $0.id == id }) else { return }
        let j = i + offset
        guard settings.rules.indices.contains(j) else { return }
        settings.rules.swapAt(i, j)
    }

    func isVIP(_ email: String) -> Bool {
        settings.vips.contains { $0.matches(email) }
    }

    func toggleVIP(email: String, name: String) {
        if let i = settings.vips.firstIndex(where: { $0.matches(email) }) {
            settings.vips.remove(at: i)
        } else {
            settings.vips.append(VIPEntry(name: name, match: email))
        }
    }

    func acceptSuggestion(_ s: RuleSuggestion) {
        settings.rules.append(s.rule)
        try? store.setSuggestionStatus(s.id, "accepted")
        reload()
    }

    func dismissSuggestion(_ s: RuleSuggestion) {
        try? store.setSuggestionStatus(s.id, "dismissed")
        reload()
    }

    /// Wie viele gespeicherte Mails würde die Regel treffen? (unabhängig vom Schalter „aktiv“)
    func testRule(_ rule: UserRule) -> (count: Int, examples: [String]) {
        let msgs = (try? store.incomingMessages(accounts: enabledAccountNames, limit: 6000)) ?? []
        let hits = msgs.filter { RuleEngine.matches(rule, $0, ignoreEnabled: true) }
        return (hits.count, hits.prefix(3).map { "\($0.senderName): \($0.subject)" })
    }

    // MARK: Regeln auf vorhandene Mails anwenden

    /// Mails, bei denen die aktuellen Regeln oder die VIP-Liste Kategorie, Priorität oder Ordner ändern würden.
    func retroChanges() -> [RetroChange] {
        let msgs = (try? store.incomingMessages(accounts: enabledAccountNames, limit: 6000)) ?? []
        var out: [RetroChange] = []
        for m in msgs {
            let e = RuleEngine.evaluate(m, settings: settings)
            guard e.decidedBy != nil else { continue }
            var changed = false
            if let c = e.category, c != m.category { changed = true }
            if let p = e.priority, p != m.priority { changed = true }
            if e.keepInInbox {
                if !settings.folderPrefix.isEmpty, m.mailbox.hasPrefix(settings.folderPrefix) { changed = true }
            } else {
                var want: String?
                if let f = e.folder {
                    want = settings.folderPrefix + f
                } else if let r = settings.category(named: e.category ?? m.category) {
                    want = settings.folderPath(for: r)
                }
                if let want, want != m.mailbox { changed = true }
            }
            if changed { out.append(RetroChange(message: m, effect: e)) }
        }
        return out
    }

    func applyRulesRetroactively() async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false; reload() }

        let changes = retroChanges()
        for c in changes {
            let m = c.message
            try? store.updateCategory(m.messageId, category: c.effect.category ?? m.category, decidedBy: c.effect.decidedBy)
            if let p = c.effect.priority { try? store.updatePriority(m.messageId, priority: p) }
            if let cat = c.effect.category { setThreadCategory(of: m, to: cat) }
        }
        try? store.resetActioned(changes.map(\.message.messageId))
        do {
            try await applyPendingActions(initial: false, retro: true)
            status = "Regeln angewendet: \(changes.count) Mails geprüft"
        } catch {
            lastError = error.localizedDescription
        }
    }

    fileprivate func setThreadCategory(of m: StoredMessage, to category: String?) {
        guard let key = m.threadKey, var t = try? store.thread(key) else { return }
        t.category = category
        try? store.upsert(t)
    }

    // MARK: Kategorie im Dashboard ändern

    /// Ändert die Kategorie der letzten eingegangenen Mail eines Gesprächs, legt sie um und merkt sich die Korrektur.
    func changeCategory(of thread: MailThread, to name: String) async {
        guard let m = messages(in: thread).last(where: { !$0.isFromMe }) else { return }
        let old = m.category ?? thread.category
        guard old != name else { return }

        try? store.addCorrection(m, from: old, to: name, toInbox: false, source: "app")
        try? store.updateCategory(m.messageId, category: name, decidedBy: "Korrektur")
        setThreadCategory(of: m, to: name)
        store.log(m, kind: "correction", detail: "Kategorie geändert: \(old ?? "–") → \(name)", dryRun: false)

        let gmailAllMail = ["alle nachrichten", "all mail", "[gmail]/alle nachrichten", "[gmail]/all mail"].contains(m.mailbox.lowercased())
        let canMove = moveStatus[m.account] == "ok"
        if settings.autoMove, !settings.dryRun, !gmailAllMail, settings.isEnabled(m.account), !canMove {
            status = "In „\(m.account)“ wird nicht verschoben (Zielordner ungeprüft oder nicht lesbar) – Kategorie nur gespeichert."
        }
        if settings.autoMove, !settings.dryRun, !gmailAllMail, settings.isEnabled(m.account), canMove {
            var target = settings.category(named: name).flatMap { settings.folderPath(for: $0) }
            if target == nil, !settings.folderPrefix.isEmpty, m.mailbox.hasPrefix(settings.folderPrefix) {
                target = MailBridge.inboxToken
            }
            if let target, target != m.mailbox {
                let item = MailBridge.BatchItem(messageId: m.messageId,
                                                location: .init(account: m.account, mailbox: m.mailbox, mailId: m.mailId),
                                                target: target, flag: nil)
                do {
                    if let r = try await runBatch([item]).first, r.ok {
                        let isInbox = target == MailBridge.inboxToken
                        try? store.updateLocation(m.messageId, mailbox: r.mailbox ?? (isInbox ? "Posteingang" : target), mailId: r.newId ?? 0)
                        store.log(m, kind: "move", detail: isInbox ? "Zurück in den Posteingang gelegt" : "Nach „\(target)“ verschoben",
                                  from: m.mailbox, to: isInbox ? nil : target, dryRun: false)
                    } else {
                        lastError = "Mail konnte nicht umsortiert werden."
                    }
                } catch {
                    lastError = error.localizedDescription
                }
            }
        }
        Learner.refreshSuggestions(store: store, settings: settings)
        reload()
    }

    // MARK: Korrekturen in Apple Mail erkennen

    /// Vergleicht, wo die von MailPilot einsortierten Mails jetzt liegen. Wurde eine Mail in einen anderen
    /// Kategorie-Ordner oder zurück in den Posteingang gelegt, gilt das als Korrektur. (Nur lesend.)
    func syncCorrections() async {
        guard settings.learnFromCorrections, initialComplete, !settings.folderPrefix.isEmpty else { return }
        let catFolders: [(name: String, path: String)] = settings.categories.compactMap { r in
            settings.folderPath(for: r).map { (r.name, $0) }
        }
        let paths = Array(Set(catFolders.map(\.path)))
        guard !paths.isEmpty else { return }

        // Frisch verschobene Mails ausnehmen: Der Server braucht etwas, bis der Zielordner sie listet.
        guard let tracked = try? store.trackedMessages(
            accounts: enabledAccountNames, prefix: settings.folderPrefix,
            since: Date().addingTimeInterval(-60 * 86400), movedBefore: Date().addingTimeInterval(-15 * 60), limit: 1500
        ).filter({ paths.contains($0.mailbox) }), !tracked.isEmpty else { return }

        let accounts = Set(tracked.map(\.account))
        let refs = accounts.flatMap { a in paths.map { MailBridge.FolderRef(account: a, path: $0) } }
        guard let listing = try? await folderListing(refs) else { return }
        let sets = listing.mapValues { Set($0) }
        func ids(_ account: String, _ path: String) -> Set<String>? { sets[.init(account: account, path: path)] }

        // Ein leerer Ordner kann „noch nicht synchronisiert“ bedeuten – dann nichts ableiten.
        let missing = tracked.filter { m in
            guard let here = ids(m.account, m.mailbox), !here.isEmpty else { return false }
            return !here.contains(m.messageId)
        }
        guard !missing.isEmpty else { return }

        let elsewhere: (StoredMessage) -> String? = { m in
            paths.first { $0 != m.mailbox && self.sets(sets, m.account, $0)?.contains(m.messageId) == true }
        }
        var inbox: [String: (inbox: String, found: Set<String>)] = [:]
        let lost = Dictionary(grouping: missing.filter { elsewhere($0) == nil }, by: \.account)
        for (account, ms) in lost {
            if let r = try? await inboxMembershipAny(account: account, ids: ms.map(\.messageId)) { inbox[account] = r }
        }

        var learned = false
        for m in missing {
            let old = m.category
            if let newPath = elsewhere(m) {
                let newCat = catFolders.first { $0.path == newPath }?.name
                try? store.addCorrection(m, from: old, to: newCat, toInbox: false, source: "mail")
                try? store.updateCategory(m.messageId, category: newCat, decidedBy: "Korrektur")
                try? store.updateLocation(m.messageId, mailbox: newPath, mailId: 0)
                setThreadCategory(of: m, to: newCat)
                store.log(m, kind: "correction", detail: "Korrektur erkannt: \(old ?? "–") → \(newCat ?? newPath)",
                          from: m.mailbox, to: newPath, dryRun: false)
                learned = true
            } else if let hit = inbox[m.account], hit.found.contains(m.messageId) {
                try? store.addCorrection(m, from: old, to: nil, toInbox: true, source: "mail")
                try? store.updateLocation(m.messageId, mailbox: hit.inbox, mailId: 0)
                store.log(m, kind: "correction", detail: "Korrektur erkannt: \(old ?? "–") → Posteingang",
                          from: m.mailbox, to: nil, dryRun: false)
                learned = true
            } else {
                // Gelöscht oder anderswo abgelegt – kein Lernsignal, aber nicht erneut prüfen.
                try? store.updateLocation(m.messageId, mailbox: "(entfernt)", mailId: 0)
            }
        }
        if learned {
            Learner.refreshSuggestions(store: store, settings: settings)
            reload()
        }
    }

    private func sets(_ all: [MailBridge.FolderRef: Set<String>], _ account: String, _ path: String) -> Set<String>? {
        all[.init(account: account, path: path)]
    }
}

/// Rückgängig für Flaggen
extension Engine {
    /// Einträge, deren Flagge sich zurücknehmen lässt (Zustand vor dem Setzen ist bekannt).
    var undoableFlags: [ActivityEntry] { activity.filter(\.canUndoFlag) }

    /// Setzt die Flaggen auf ihren früheren Zustand zurück – in einem Rutsch.
    func undoFlags(_ entries: [ActivityEntry]) async {
        let todo = entries.filter(\.canUndoFlag)
        guard !todo.isEmpty else { return }
        var items: [MailBridge.BatchItem] = []
        var byId: [String: ActivityEntry] = [:]
        for e in todo {
            guard let prev = e.previousFlag, let m = try? store.message(id: e.messageId) else { continue }
            items.append(.init(messageId: m.messageId, location: .init(account: m.account, mailbox: m.mailbox, mailId: m.mailId),
                               target: nil, flag: nil, restoreFlag: prev))
            byId[m.messageId] = e
        }
        guard !items.isEmpty else { return }
        do {
            var restored = 0
            for chunk in stride(from: 0, to: items.count, by: 50).map({ Array(items[$0..<min($0 + 50, items.count)]) }) {
                status = "Flaggen zurücknehmen: \(restored)/\(items.count)"
                for (item, r) in zip(chunk, try await runBatch(chunk)) {
                    guard r.ok, let e = byId[item.messageId], let m = try? store.message(id: e.messageId) else { continue }
                    try store.markUndone(e.id)
                    store.log(m, kind: "undo", detail: item.restoreFlag?.flagged == true ? "Flagge auf früheren Stand zurückgesetzt" : "Flagge entfernt", dryRun: false)
                    restored += 1
                }
            }
            status = "\(restored) Flaggen zurückgenommen"
            reload()
        } catch {
            lastError = error.localizedDescription
        }
    }
}

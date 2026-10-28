import Foundation

/// Archivierung gealterter Mails
extension Engine {
    /// Beim Einsortieren archiviert MailPilot nur Mails, die dabei schon alt genug sind. Damit auch Mails ins Archiv kommen,
    /// die erst später altern, werden sie hier erneut zur Auswertung vorgemerkt (jede Mail nur einmal, höchstens 200 je Durchlauf).
    /// Nur in Konten mit geprüftem Verschieben; Mails jünger als 15 Tage bleiben außen vor, damit keine Flaggen erneuert werden.
    /// Rückgabe: Zahl der vorgemerkten Mails.
    @discardableResult
    func queueAgedForArchive() -> Int {
        guard settings.autoMove, !settings.dryRun, settings.archiveAfterDays > 0, !settings.archiveFolder.isEmpty else { return 0 }
        let accounts = enabledAccountNames.filter { moveStatus[$0] == "ok" }
        guard !accounts.isEmpty else { return 0 }
        let cutoff = Date().addingTimeInterval(-Double(max(settings.archiveAfterDays, 15)) * 86400)
        guard let found = try? store.archiveCandidates(accounts: accounts, archivePath: settings.folderPrefix + settings.archiveFolder,
                                                       prefix: settings.folderPrefix, before: cutoff, limit: 200), !found.isEmpty else { return 0 }
        let ids = found.filter { m in
            let effect = RuleEngine.evaluate(m, settings: settings)
            if effect.keepInInbox || effect.folder != nil { return false }
            // Mails mit eigenem Kategorie-Ordner gehören dorthin, nicht ins Archiv.
            if let rule = settings.category(named: m.category), settings.folderPath(for: rule) != nil { return false }
            return true
        }.map(\.messageId)
        store.markArchiveTried(found.map(\.messageId))
        try? store.resetActioned(ids)
        return ids.count
    }
}

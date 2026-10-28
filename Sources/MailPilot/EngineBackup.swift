import AppKit
import Foundation

/// Sicherung, Wiederherstellung und Export.
extension Engine {
    var databaseSizeText: String {
        let size = ((try? FileManager.default.attributesOfItem(atPath: Paths.database.path)[.size]) as? Int64) ?? 0
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    var lastBackupText: String {
        guard let e = Backups.list().first else { return "Noch keine Sicherung." }
        return "Letzte Sicherung \(e.date.formatted(date: .abbreviated, time: .shortened)) (\(ByteCountFormatter.string(fromByteCount: e.size, countStyle: .file)))"
    }

    /// Sichert die Datenbank in den Sicherungsordner (oder `url`).
    @discardableResult
    func backupNow(to url: URL? = nil) -> URL? {
        let target = url ?? Backups.folder.appendingPathComponent(Backups.fileName())
        do {
            try Backups.create(store: store, at: target)
            if url == nil { Backups.prune(keep: settings.backupKeep) }
            status = "Sicherung erstellt: \(target.lastPathComponent)"
            objectWillChange.send()
            return target
        } catch {
            lastError = "Sicherung fehlgeschlagen: \(error.localizedDescription)"
            return nil
        }
    }

    /// Täglich eine Sicherung, die letzten `backupKeep` bleiben.
    func backupIfDue() {
        guard settings.autoBackup else { return }
        let today = Deadlines.format(Date())
        guard store.value("lastBackupDay") != today else { return }
        if backupNow() != nil { store.setValue(today, for: "lastBackupDay") }
    }

    /// Legt eine Sicherung für den nächsten Start bereit und beendet MailPilot danach.
    func restoreBackup(from url: URL) -> String? {
        if let problem = Backups.validate(url) { return problem }
        do {
            try Backups.stageRestore(from: url)
            return nil
        } catch {
            return "Wiederherstellung konnte nicht vorbereitet werden: \(error.localizedDescription)"
        }
    }

    func exportJSON(to url: URL, includeBodies: Bool) {
        do {
            let data = try DataExport.json(store: store, accounts: enabledAccountNames, settings: settings, includeBodies: includeBodies)
            try data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            status = "Daten exportiert: \(url.lastPathComponent) (\(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)))"
        } catch {
            lastError = "Export fehlgeschlagen: \(error.localizedDescription)"
        }
    }

    func exportThreadsCSV(to url: URL) {
        do {
            try DataExport.threadsCSV(threads).write(to: url, atomically: true, encoding: .utf8)
            status = "\(threads.filter { !$0.isPrivate }.count) Gespräche exportiert: \(url.lastPathComponent)"
        } catch {
            lastError = "Export fehlgeschlagen: \(error.localizedDescription)"
        }
    }

    func exportSettings(to url: URL) {
        settings.save(to: url)
        status = "Einstellungen exportiert: \(url.lastPathComponent)"
    }

    /// Ersetzt die Einstellungen durch die Datei; unbekannte oder fehlende Felder nehmen Standardwerte an.
    func importSettings(from url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url), let s = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            lastError = "Die Datei ist keine gültige MailPilot-Einstellungsdatei."
            return false
        }
        settings = s
        reload()
        status = "Einstellungen importiert"
        return true
    }
}

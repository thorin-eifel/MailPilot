# MailPilot – Verwaltung für Administratoren

Für den Einsatz im Unternehmen lassen sich Einstellungen zentral vorgeben. Was vorgegeben ist, kann der Nutzer in MailPilot nicht ändern (Schloss-Symbol in den Einstellungen, Bereich „Vorgaben der Organisation“). Nur macOS.

## Wie die Vorgaben ankommen

MailPilot liest beim Start, in dieser Reihenfolge:

1. **Konfigurationsprofil (MDM)** für die Domain `de.thorin.mailpilot`, Schlüssel `Policy` (Dictionary). macOS meldet den Schlüssel dabei als „verwaltet“; ein vom Nutzer selbst per `defaults write` gesetzter Wert zählt nicht.
2. **Datei** `/Library/Application Support/MailPilot/policy.json` – nur wenn sie **root** gehört und für niemand sonst beschreibbar ist (`sudo chown root:wheel` und `chmod 644`). Eine Datei, die der Nutzer ändern könnte, wird ignoriert. Geeignet für Jamf, Skripte oder Rechner ohne MDM.

Änderungen gelten nach einem Neustart oder über *Einstellungen → Vorgaben der Organisation → Vorgaben neu laden*.

## Schlüssel

Alle Schlüssel sind optional; nicht gesetzte Werte bleiben beim Nutzer.

| Schlüssel | Wirkung |
|---|---|
| `organization`, `supportContact` | Name und Ansprechpartner in den Einstellungen |
| `claude.enabled` | `false`: Claude komplett aus – nichts geht an Claude, MailPilot ist ein reiner Mail-Client. Briefing, Analyse, Entwürfe, Rechnungen entfallen. |
| `claude.model`, `claude.modelBulk` | Modell für Einzelanalyse und Massenanalyse (`sonnet`, `haiku`, `opus`) |
| `claude.executablePath` | Pfad zur `claude`-CLI |
| `claude.environment` | Zusätzliche Umgebungsvariablen für jeden Claude-Aufruf (z. B. Gateway-Adresse). **Keine Geheimnisse** – Profile sind für den Nutzer lesbar. |
| `features.appleMail` / `calendar` / `contacts` / `notifications` | Apple Mail, Kalender und Erinnerungen, Kontakte, Mitteilungen erlauben (`true`) oder abschalten (`false`). Ausgeschaltete Funktionen fragen auch keine macOS-Berechtigung an. |
| `folderPrefix`, `archiveFolder` | Ordner-Präfix für Kategorie-Ordner („Claude/“), Archivordner |
| `dryRun` | `true`: nur protokollieren, nichts in Postfächern verändern |
| `privacyRules` | Datenschutz-Ausnahmen der Organisation (Absender, Domains, Betreff-Stichworte), deren Inhalt nie an Claude geht. Kommen zu den eigenen des Nutzers hinzu, sind nicht entfernbar und werden nicht in seiner Datei gespeichert. |
| `providers`, `onlyListedProviders` | Mail-Anbieter-Vorlagen im „Konto hinzufügen“-Dialog (IMAP-/SMTP-Server, Ports, Hinweis). Mit `onlyListedProviders: true` gibt es nur diese, ohne „Anderes IMAP/SMTP“. |
| `maxAccounts` | Höchstzahl eigener Konten (1–16) |

### Beispiel `policy.json`

```json
{
  "organization": "CTW",
  "supportContact": "it@ctw.example",
  "claude": { "enabled": true, "model": "sonnet", "modelBulk": "haiku" },
  "features": { "appleMail": false, "contacts": false },
  "folderPrefix": "CTW/",
  "privacyRules": [
    { "name": "Betriebsrat", "conditions": [ { "field": "domain", "value": "betriebsrat.ctw.example" } ] },
    { "name": "Personal", "conditions": [ { "field": "subject", "value": "Personalakte" } ] }
  ],
  "providers": [
    { "name": "CTW Mail", "imapHost": "imap.ctw.example", "smtpHost": "smtp.ctw.example",
      "smtpPort": 465, "smtpSecurity": "tls", "hint": "Anmeldung mit dem Domänenpasswort." }
  ],
  "onlyListedProviders": true,
  "maxAccounts": 4
}
```

`field` für Bedingungen: `sender`, `domain`, `subject`, `body`, `recipient`. Mehrere Bedingungen einer Ausnahme genügen einzeln (oder alle, mit `"matchAll": true`). Mit `"keepBody": true` bleibt der Mailtext lokal gespeichert, geht aber nie an Claude; sonst wird er gar nicht gespeichert.

### Beispiel Konfigurationsprofil (Ausschnitt)

Payload `com.apple.ManagedClient.preferences`, Domain `de.thorin.mailpilot`, Einstellung „Forced“:

```xml
<key>Policy</key>
<dict>
  <key>organization</key><string>CTW</string>
  <key>claude</key><dict><key>enabled</key><true/></dict>
  <key>folderPrefix</key><string>CTW/</string>
</dict>
```

## Verteilung

- **Programm:** `MailPilot.app` nach `/Applications`. Für den Firmeneinsatz braucht es eine Signatur mit Developer-ID und Notarisierung (die mitgelieferte Signatur ist nur ad-hoc; Gatekeeper warnt, und macOS fragt für den Schlüsselbund öfter nach).
- **Standard-Mailprogramm:** Jeder Nutzer legt es unter *Einstellungen → Standard-Mailprogramm* fest; macOS fragt selbst nach Bestätigung. Zentral setzen lässt es sich mit MDM (Standard-App-Zuordnung) oder dem Werkzeug `duti`.
- **Passwörter** liegen im Schlüsselbund des jeweiligen Nutzers, nie in den Vorgaben.

## Was die Vorgaben nicht leisten

- Keine zentralen Konten: Jeder Nutzer verbindet seine Postfächer selbst (Server aus den Vorlagen, Passwort eingeben).
- Keine Anmeldung per OAuth (Microsoft 365, Gmail); nur Benutzername und Passwort/App-Passwort.
- Keine Fernwartung: Die Vorgaben werden nur beim Start und bei „Neu laden“ gelesen.

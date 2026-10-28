# MailPilot – Claude für Apple Mail

Menüleisten-App mit Dashboard, die Apple Mail mit Claude automatisiert:

- **Auto-Sortierung** – jede neue Mail wird von Claude kategorisiert, bei Bedarf in `Claude/<Kategorie>` im selben Konto verschoben und mit einer Flagge markiert.
- **Gesprächs-Tracking** – Mails werden über `References`/`In-Reply-To` (oder Betreff + Gegenseite) zu Gesprächen gruppiert. Pro Gespräch pflegt Claude Status (*Antwort nötig*, *Wartet auf Antwort*, *Info*, *Erledigt*), Zusammenfassung, nächsten Schritt und Frist.
- **Follow-ups** – Gespräche, in denen du seit X Tagen auf Antwort wartest, werden als überfällig markiert und gemeldet.
- **Tägliches Briefing** – ab einer einstellbaren Uhrzeit fasst Claude den Tag zusammen.
- **Antwortentwürfe** – werden automatisch vorbereitet, lassen sich mit einer Anweisung neu schreiben und öffnen sich als Antwortfenster in Mail. **Gesendet wird nie automatisch.**
- **Aktivitätsprotokoll** mit Rückgängig für Verschiebungen, plus Probelauf-Modus.

## Voraussetzungen

- macOS 15 oder neuer, Apple Mail mit eingerichteten Konten
- Claude Code CLI (`claude`), angemeldet (`claude` → `/login`)
- Swift-Toolchain (Command Line Tools reichen, Xcode ist nicht nötig)

## Bauen & Starten

```bash
./scripts/build-app.sh
open build/MailPilot.app
```

Beim ersten Start fragt macOS, ob MailPilot Mail steuern darf → **Erlauben**. (Nach jedem Neubau kann die Abfrage erneut kommen, weil die App nur ad-hoc signiert ist.)

Selbsttest ohne Änderungen an Mail:

```bash
.build/release/MailPilot --selftest --analyze
```

## Wie es funktioniert

| Baustein | Datei |
|---|---|
| Mail-Zugriff per JXA (`osascript`) | `Sources/MailPilot/MailBridge.swift` |
| SQLite: Nachrichten, Gespräche, Aktivität, Briefings | `Sources/MailPilot/Store.swift` |
| Claude über `claude -p` mit JSON-Schema, ohne Tools | `Sources/MailPilot/ClaudeClient.swift` |
| Zyklus, Regeln, Follow-ups, Briefing | `Sources/MailPilot/Engine.swift` |
| Menüleiste & Dashboard (SwiftUI) | `Sources/MailPilot/Views/` |

Daten liegen lokal in `~/Library/Application Support/MailPilot/`. Mailinhalte werden zur Analyse an Claude übergeben; Claude hat dabei keine Tools und kann nur das vorgegebene JSON zurückgeben – die Aktionen (Ordner, Flaggen) bestimmt die App anhand deiner Kategorien.

## Sicherheitsgrenzen

- Mails, die **vor dem ersten Start** eingegangen sind, werden analysiert, aber nicht verschoben.
- Gmail-Mails (Ordner „Alle Nachrichten“) werden nur markiert, nicht verschoben.
- Ordner werden nie gelöscht, Mails nie gelöscht oder gesendet.

## Bekannte Grenzen / Ideen

- Apple-Mail-Skripting kann keine Postfächer löschen.
- Optional später: MailKit-Extension (benötigt Xcode) für Färbung direkt beim Eingang und einen Compose-Button; MCP-Server, um aus Claude Desktop/Code mit dem Postfach zu arbeiten.

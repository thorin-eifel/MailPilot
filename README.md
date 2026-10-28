# MailPilot – Claude für Apple Mail

Menüleisten-App mit Dashboard, die Apple Mail mit Claude automatisiert:

- **Auto-Sortierung** – jede neue Mail wird von Claude kategorisiert, bei Bedarf in `Claude/<Kategorie>` im selben Konto verschoben und mit einer Flagge markiert.
- **Eigene Regeln & VIP** – Absender, Domain, Betreff-/Text-Stichwort oder Empfänger → Kategorie, Ordner, Priorität, Flagge oder „im Posteingang lassen“. Regeln gehen vor Claude (erste Regel gewinnt je Feld); die VIP-Liste hebt die Priorität immer auf „hoch“, markiert und meldet. Per Knopfdruck auch auf vorhandene Mails anwendbar.
- **Lernen aus Korrekturen** – Legst du eine einsortierte Mail in Mail in einen anderen Kategorie-Ordner oder zurück in den Posteingang (oder änderst die Kategorie im Gespräch), erkennt MailPilot das, gibt Claude die Korrektur als Hinweis und schlägt nach wiederholten Korrekturen eine Regel vor (2× je Absender, 3 Absender je Domain).
- **Verschiebe-Schutz** – Nach jedem Verschieben prüft MailPilot, ob die Mail im Zielordner angekommen ist. Konten, deren Zielordner sich nicht zurücklesen lassen (z. B. manche Exchange/IMAP-Konten mit Unterordnern), werden nur noch markiert, nicht verschoben. Neue Konten starten mit einer Probe-Mail; bereits einsortierte Mails dienen als Stichprobe. In den Einstellungen zeigt jedes Konto seinen Status, „Erneut prüfen“ wiederholt den Test.
- **Zurückstellen** – Gespräche ausblenden und später wieder zeigen (heute Abend, morgen früh, Montag, in einer Woche oder frei wählbar). Eine neue Nachricht im Gespräch holt es sofort zurück; abgelaufene Zeiten melden sich per Mitteilung.
- **Nachfass-Entwürfe** – Wird ein „wartet auf Antwort“-Gespräch überfällig, schreibt Claude automatisch eine freundliche Nachfrage. „In Mail öffnen“ legt eine neue Nachricht an dieselben Empfänger an (mit Zitat deiner letzten Mail); gesendet wird nichts.
- **Fristen in Erinnerungen und Kalender** – Fristen aus Gesprächen (von Claude erkannt oder selbst gesetzt) landen auf Wunsch automatisch als Erinnerung (9 Uhr am Fristtag) und/oder ganztägiger Termin; jede Frist nur einmal, ohne Werbung und Newsletter. Pro Gespräch auch von Hand.
- **Rechnungen** – Mails der Kategorie „Rechnungen“ werden samt PDF-Anhang ausgelesen (eingebetteter Text, bei Scans per Texterkennung): Aussteller, Nummer, Betrag brutto, USt, Datum, Fälligkeit. Übersicht mit Summen, offen/bezahlt/überfällig, Korrekturformular und **CSV-Export** für die Buchhaltung (Semikolon, Dezimalkomma, UTF-8). Fälligkeiten werden zur Frist des Gesprächs.
- **Datenschutz-Ausnahmen** – Absender, Domains oder Stichworte (bei gesendeten Mails: Empfänger), deren Inhalt **nie** an Claude geht: keine Analyse, kein Entwurf, kein Briefing, keine Rechnungsauslesung, weder Mailtext noch Betreff. Auf Wunsch wird der Mailtext gar nicht gespeichert; bereits gespeicherte Inhalte lassen sich nachträglich entfernen. Alle Gespräche, die eine solche Mail enthalten, gelten als vertraulich.
- **Claude-Nutzung** – Aufrufe, Token und Dauer je Tag und Zweck, dazu die echte Abo-Auslastung (5-Stunden- und 7-Tage-Fenster, aus der Claude-CLI). Automatische Aufrufe pausieren, wenn das Limit fast erreicht ist (einstellbar, plus Tageslimit); was du per Knopfdruck startest, läuft immer.
- **Volltextsuche** – über Betreff, Absender, Zusammenfassungen und Mailtexte aller gespeicherten Gespräche, auch bereits verschobener Mails (SQLite FTS5, Umlaute egal, Phrasen mit Anführungszeichen).
- **Antwortstil** – MailPilot lernt aus deinen gesendeten Mails (ohne Zitate) einen Stilleitfaden; Entwürfe nutzen ihn plus frühere Mails an dieselbe Person als Beispiel.
- **Wochenbericht** – Zahlen gegen die Vorwoche, Kategorien-Wachstum, mediane Antwortzeit, wo du säumig bist und worauf du wartest; Text von Claude, montags automatisch.
- **Newsletter abbestellen** – erkennt Absender, deren Mails du nie öffnest, und meldet sie auf deinen Klick ab (Ein-Klick nach RFC 8058, Link oder vorbereitete E-Mail). Unsichere Ziele (http, IP-Adressen, lokale Hosts) werden nie angesprochen.
- **Rückgängig für Flaggen** – MailPilot merkt sich den Zustand vor dem Markieren; einzeln oder für alle zurücknehmbar.
- **Sicherung und Export** – tägliche Sicherung der Datenbank (7 behalten), Wiederherstellung beim nächsten Start (mit Sicherheitskopie des alten Stands), Export als JSON (Mailtexte nur auf Wunsch, vertrauliche nie) und Gespräche als CSV, Einstellungen übertragbar.
- **Weniger Claude-Aufrufe** – Newsletter und Systemmeldungen erkennt MailPilot an den Mail-Headern (`List-Unsubscribe`, `Auto-Submitted`, `Precedence`), wiederkehrende Absender an ihrer Vorgeschichte; Rechnungen, Bestellungen, Termine und laufende Gespräche gehen immer an Claude. Ältere Mails laufen im Paket mit Haiku, der Erstscan beginnt mit den neuesten und kann auf die letzten X Tage beschränkt werden. Regeln können Mails „ohne Claude“ einordnen.
- **Einladungen → Kalender** – Kalenderanhänge (.ics) aus Mails werden gelesen (Zeitzonen, ganztägig, Absagen, Änderungen) und auf Klick oder automatisch in den gewählten Kalender eingetragen; Überschneidungen werden angezeigt.
- **Freie Zeiten in Entwürfen** – fragt eine Mail nach einem Termin, nennt der Entwurf freie Zeiten aus dem Kalender (nur Zeiträume gehen an Claude, nie Titel oder Orte).
- **Kontakte** – Namen aus der Kontakte-App und eine Kontaktgruppe als VIP-Liste.
- **Mitteilungen mit Knöpfen** („Antworten“, „Morgen früh wieder zeigen“, „Erledigt“) und **Tastenkürzel** (⌘F Suche, ⌘J / ⇧⌘J Zurückstellen, ⌘E erledigt, ⌘R antworten, ⌘0–4 Bereiche).
- **Entwurf direkt in „Entwürfe“** – legt Antwort oder Nachfrage still im Entwürfe-Ordner des Mail-Kontos ab; gesendet wird nichts.
- **Verschieben nur nach Erlaubnis** – In Konten ohne nachgewiesene, lesbare Zielordner (z. B. Exchange) wird nie verschoben; eine Probe-Verschiebung muss ausdrücklich erlaubt werden.
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

Optional: Das CTW-Logo als `Resources/ctw-logo.png` ablegen – es ist nicht im Repository enthalten. Ohne Datei zeigt die App einen Schriftzug.

Beim ersten Start fragt macOS, ob MailPilot Mail steuern darf → **Erlauben**. (Nach jedem Neubau kann die Abfrage erneut kommen, weil die App nur ad-hoc signiert ist.)

Tests ohne Änderungen an Mail:

```bash
.build/release/MailPilot --selftest-rules        # Regeln, VIP, Lernen (39 Prüfungen)
.build/release/MailPilot --selftest-sync --all   # liest Ordner/Posteingang, Trockenlauf der Korrekturerkennung
```

```bash
.build/release/MailPilot --selftest-features     # Zurückstellen, Nachfassen, Fristen, Rechnungen, CSV, PDF/OCR (40 Prüfungen)
.build/release/MailPilot --selftest-live --claude --compose --attach   # echte Anbindungen (Claude-Aufrufe, Mail-Fenster unsichtbar, Anhänge)
.build/release/MailPilot --selftest-live --export  # legt Erinnerung und Termin an und löscht sie sofort wieder
```

```bash
.build/release/MailPilot --selftest-more         # Datenschutz, Nutzung, Suche, Stil, Wochenbericht, Newsletter, Flaggen, Sicherung, Export
.build/release/MailPilot --selftest-live --newsletter --flagrestore   # lesende Mail-Tests
```

Selbsttest der Mail- und Claude-Anbindung:

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

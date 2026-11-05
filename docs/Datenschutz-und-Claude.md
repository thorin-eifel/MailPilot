# MailPilot und Claude – Unterlage für Datenschutz und Freigabe

Stand: Beschreibung des tatsächlichen Verhaltens der Software. Sie ersetzt keine Rechtsberatung; Bewertung, Auftragsverarbeitung und Beteiligung des Betriebsrats liegen bei CTW.

## 1. Was MailPilot ist

Ein Mail-Programm für macOS (Lesen und Senden per IMAP/SMTP). Zusätzlich kann es Mails mit **Claude** auswerten (Kategorien, Zusammenfassungen, Antwortentwürfe, Fristen, Rechnungen, Briefing). Die Auswertung ist **abschaltbar**, auch zentral (`claude.enabled: false`, siehe `Verwaltung.md`). Ohne Claude geht nichts an Anthropic.

## 2. Wohin gehen welche Daten

| Daten | Wohin | Wann |
|---|---|---|
| Mail-Zugangsdaten (Passwort) | nur Schlüsselbund des Nutzers; Verbindung direkt zum Mailserver (TLS) | immer |
| Mails, Anhänge, Kontakte, Kalender | lokal auf dem Rechner (die Mailkopie des Postfachs, auch der Rohtext geöffneter Mails, liegt unabhängig von Datenschutz-Ausnahmen lokal; die Ausnahmen betreffen die Auswertung und die Analyse-Ablage) (SQLite in `~/Library/Application Support/MailPilot`), nicht auf einem MailPilot-Server – **es gibt keinen** | immer |
| Mailinhalt für die Auswertung | an Claude, über die lokal installierte `claude`-CLI | nur wenn Claude an ist, das Konto freigegeben ist und die Mail nicht unter eine Datenschutz-Ausnahme fällt |

MailPilot selbst sendet nichts an CTW, den Entwickler oder Dritte (keine Telemetrie, keine Absturzberichte). Einzige Netzverbindungen: IMAP/SMTP zu den eingetragenen Servern, die `claude`-CLI und optional von der Mail angeforderte externe Bilder (standardmäßig blockiert).

## 3. Was an Claude geht

Je nach Funktion, als Text im Aufruf der CLI (ohne Werkzeuge, ohne Dateizugriff, ohne gespeicherte Sitzung):

- **Einzelanalyse und Entwürfe:** Absender, Empfänger, Datum, Betreff, Konto/Ordner, Mailtext (bis 6.000 Zeichen), bisheriger Verlauf des Gesprächs (gekürzt), Namen/Hinweise zum Absender, Stil-Hinweise.
- **Massenanalyse älterer Mails:** Absender, Betreff, Textauszug (1.500 Zeichen) in Paketen.
- **Rechnungen:** Mailtext (2.500 Zeichen) und der Text eingebetteter PDF-Anhänge (bei Scans per lokaler Texterkennung gewonnen). Nur Mails der Rechnungs-Kategorie.
- **Briefing/Wochenbericht:** Betreff, Gesprächspartner, Status und Zusammenfassungen offener Gespräche, offene Rechnungen.
- **Freie Zeiten:** Nur Zeiträume als Text, **keine Termintitel**.
- **Antwortstil:** Auszüge eigener gesendeter Mails.

Anhänge als Dateien, Kontaktdaten und Kalendertitel gehen nicht an Claude.

## 4. Schutzmaßnahmen in der Software

- **Datenschutz-Ausnahmen:** Mails nach Absender, Domain, Betreff oder Text ausnehmen. Sie gehen weder in die Analyse noch ins Briefing; ihr Text wird auf Wunsch nicht einmal gespeichert. Die Organisation kann Ausnahmen verbindlich vorgeben (z. B. Betriebsrat, Personal, Rechtsabteilung).
- **Claude je Konto:** Ein neu verbundenes Konto (Postfach) hat Claude zunächst **aus**; der Nutzer schaltet es ausdrücklich ein, nach Rückfrage. Achtung: Konten aus Apple Mail sind in einer Neuinstallation standardmäßig freigegeben (Einstellungen → Konten). Für den Firmeneinsatz Apple Mail per Vorgabe abschalten (`features.appleMail: false`) oder Claude zentral sperren.
- **Globaler Aus-Schalter** und zentrale Sperre.
- **Probelauf:** protokolliert nur, ändert keine Postfächer.
- **Nachvollziehbarkeit:** Jede automatische Verschiebung steht in „Aktivität“ und ist rückgängig zu machen. MailPilot **sendet nie selbstständig**: Entwürfe werden vorbereitet, gesendet wird nur per Klick des Nutzers.
- **Begrenzung:** Tages- und Abo-Limits für Claude-Aufrufe einstellbar; Nutzungsübersicht.
- **Lokal:** Vollständiges Löschen eines Kontos entfernt die lokale Mailkopie und das Passwort.

## 5. Wie Claude angebunden wird – Entscheidung für CTW

MailPilot ruft die auf dem Rechner installierte `claude`-CLI auf. Wer die Rechnung trägt und wer sich anmeldet, entscheidet die Art des Zugangs:

| Variante | Zugang | Bemerkung |
|---|---|---|
| **A: Jeder Nutzer eigenes Konto** | Nutzer meldet sich selbst an (`claude`, `/login`) | einfach, aber keine zentrale Kontrolle über Vertrag, Datenhaltung, Kosten; privates Konto wäre für Firmenmails ungeeignet |
| **B: Zentraler Firmenzugang** | Claude for Work/Enterprise mit SSO, oder Cloud-Zugang (Bedrock/Vertex) mit zentralen Zugangsdaten | Vertrag und Auftragsverarbeitung mit Anthropic bzw. dem Cloud-Anbieter, zentrale Verwaltung, Datenhaltung in der gewünschten Region wählbar |

Technisch: Zentrale Vorgaben für die CLI lassen sich über deren eigene Verwaltungseinstellungen (Managed Settings) und über `claude.environment` verteilen. MailPilot startet die CLI ohne Benutzer-, Projekt- oder lokale Einstellungen (`--setting-sources ""`); **ob die zentralen Verwaltungseinstellungen dabei gelten, ist vor dem Rollout mit einem Testrechner zu prüfen** und gehört in den Pilotplan. Geheimnisse (API-Schlüssel) gehören nicht in `claude.environment`.

## 6. Checkliste vor der Freigabe

- [ ] Zugangsvariante A oder B festlegen und vertraglich absichern (Auftragsverarbeitung mit Anthropic bzw. Cloud-Anbieter; Drittlandübermittlung prüfen, Datenspeicherung/Aufbewahrung beim Anbieter klären, Nutzung für Training ausschließen lassen).
- [ ] Verzeichnis der Verarbeitungstätigkeiten ergänzen; Datenschutz-Folgenabschätzung prüfen (systematische Auswertung von Mailinhalten, auch von Dritten).
- [ ] Datenschutz-Ausnahmen für besondere Kategorien festlegen (Betriebsrat, Personal, Gesundheit, Rechtsberatung, Mandantendaten) und per `privacyRules` verbindlich vorgeben.
- [ ] Betriebsrat beteiligen, falls vorhanden: Das Programm kann Verhalten und Leistung auswerten (Antwortzeiten im Wochenbericht, Aktivität). Zweckbindung und Verbot von Leistungskontrolle regeln.
- [ ] Transparenz gegenüber Beschäftigten und Mailpartnern (Hinweis in der Datenschutzerklärung bzw. Signatur, wenn Dritte betroffen sind).
- [ ] Pilot mit wenigen Nutzern, Claude zunächst aus oder nur für ein Konto, Probelauf an.
- [ ] Löschkonzept: lokale Datenbank, Sicherungen (täglich, 7 Stück, im Programmordner), Entfernen eines Kontos.
- [ ] Technische Prüfung: Festplattenverschlüsselung (FileVault) auf allen Rechnern; Signatur und Notarisierung der App.

## 7. Bekannte Grenzen

- Die Auswertung kann Fehler machen; Kategorien, Zusammenfassungen und Entwürfe sind Vorschläge und vor Verwendung zu prüfen.
- Lokale Daten (Mailkopie, Auswertung) liegen unverschlüsselt in der Datenbank des Nutzers; Schutz ist die Festplattenverschlüsselung.
- Nicht geprüft: Verhalten mit echten Firmenservern und mit zentral verwalteter Claude-CLI.

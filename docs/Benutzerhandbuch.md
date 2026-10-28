# MailPilot – Benutzerhandbuch

MailPilot ist eine Menüleisten-App für macOS, die Apple Mail mit Claude automatisiert: Sie sortiert neue Mails ein, verfolgt Gespräche, bereitet Antwortentwürfe vor und erinnert an offene Punkte. **Gesendet wird nie automatisch** – Mails verlässt du immer selbst in Apple Mail.

## Inhalt

1. [Erste Schritte](#1-erste-schritte)
2. [Die Oberfläche](#2-die-oberfläche)
3. [Täglich arbeiten](#3-täglich-arbeiten)
4. [Mails sortieren: Kategorien, Regeln und VIP](#4-mails-sortieren-kategorien-regeln-und-vip)
5. [Rechnungen, Einladungen, Newsletter](#5-rechnungen-einladungen-newsletter)
6. [Berichte und Suche](#6-berichte-und-suche)
7. [Datenschutz](#7-datenschutz)
8. [Claude-Nutzung und Limits](#8-claude-nutzung-und-limits)
9. [Sicherung und Export](#9-sicherung-und-export)
10. [Einstellungen im Überblick](#10-einstellungen-im-überblick)
11. [Tastenkürzel](#11-tastenkürzel)
12. [Fehlerbehebung](#12-fehlerbehebung)

---

## 1. Erste Schritte

### Voraussetzungen

- macOS 15 oder neuer
- Apple Mail mit eingerichteten Konten
- Die Claude Code CLI (`claude`), im Terminal angemeldet (`claude` starten, dann `/login`)
- Zum Selbstbauen: eine Swift-Toolchain (die Command Line Tools genügen, Xcode ist nicht nötig)

### Installieren und starten

```bash
./scripts/build-app.sh
open build/MailPilot.app
```

Beim ersten Start fragt macOS, ob MailPilot Mail steuern darf → **Erlauben**. Da die App nur ad-hoc signiert ist, kann die Frage nach jedem Neubau erneut erscheinen. Fehlt die Berechtigung, findest du sie unter *Systemeinstellungen → Datenschutz & Sicherheit → Automation*.

Weitere Berechtigungen werden erst abgefragt, wenn du die jeweilige Funktion nutzt: Erinnerungen und Kalender (Fristen, Einladungen, freie Zeiten) sowie Kontakte.

### Der Erstscan

Beim ersten Start katalogisiert MailPilot den kompletten Posteingang jedes aktivierten Kontos, lässt die Mails von Claude kategorisieren und sortiert sie ein. Das kann bei großen Postfächern dauern.

- Der Fortschritt steht in der Seitenleiste und im Menüleisten-Fenster („Erstscan: 120 von 800 analysiert“).
- Die neuesten Mails kommen zuerst dran. Unter *Einstellungen → Claude* kannst du den Erstscan auf die letzten X Tage begrenzen (Standard: 180 Tage). Das spart Claude-Aufrufe.
- Wird der Scan unterbrochen (Limit erreicht, Mail nicht erreichbar), setzt MailPilot nach 5 Minuten fort, auch nach einem Neustart.
- Der Erstscan sortiert auch alte Mails ein, **aber nur in Konten, in denen Verschieben freigegeben ist** (siehe [Verschiebe-Schutz](#verschiebe-schutz)). In einem frischen Konto wird zunächst gar nichts verschoben, nur markiert. Flaggen setzt der Erstscan nur bei Mails der letzten 14 Tage.
- Erst wenn der Erstscan eines Kontos fertig ist, beginnt der reguläre Zeitplan.

**Verschieben freigeben:** Unter *Einstellungen → Konten* steht bei jedem Konto „Verschieben aus – ungeprüft“. Mit **Verschieben testen …** erlaubst du eine einzelne Probe-Verschiebung; klappt sie, gilt das Konto als geprüft.

**Vorsicht beim Probelauf:** Der **Probelauf** (*Einstellungen → Automatik*) protokolliert nur („Würde nach Claude/Rechnungen verschieben“) und ändert nichts in Mail. MailPilot merkt sich aber, dass diese Mails abgearbeitet sind. Schaltest du den Probelauf später aus, werden sie **nicht nachträglich** verschoben oder markiert; nur neue Mails sind betroffen. In Konten ohne Verschiebe-Freigabe zeigt der Probelauf zudem keine Verschiebungen. Nutze ihn deshalb am besten für ein Konto, das du ohnehin erst später freischaltest, oder für einen kurzen Blick auf neue Mails.

### Konten auswählen

Unter *Einstellungen → Konten* schaltest du ein, auf welchen Konten MailPilot arbeiten darf. Ein neu aktiviertes Konto wird zuerst komplett gescannt. Deaktivierte Konten bleiben unverändert.

---

## 2. Die Oberfläche

### Menüleiste

Das MailPilot-Symbol in der Menüleiste zeigt neben sich die Zahl der Gespräche, in denen du antworten musst. Ein Klick öffnet ein kleines Fenster mit:

- **Status** (Erstscan-Fortschritt, „Aktuell“, Fehler, Pause-Grund) und der Claude-Auslastung
- drei Zählern: **Antworten**, **Warten**, **Überfällig**
- den bis zu sechs wichtigsten Gesprächen „Ich bin am Zug“
- den Knöpfen **Dashboard** (öffnet das Hauptfenster), **Prüfen** (sofort einen Durchlauf starten) und **Pause/Fortsetzen**
- **Beenden**

### Dashboard

Die Seitenleiste ist in vier Gruppen gegliedert:

| Gruppe | Bereich | Wofür |
|---|---|---|
| (oben) | **Suche** | Volltextsuche über alle gespeicherten Gespräche |
| | **Briefing** | Tägliche Zusammenfassung von Claude |
| | **Wochenbericht** | Zahlen und Auswertung der Woche |
| Gespräche | **Antwort nötig** | Du bist am Zug |
| | **Warte auf Antwort** | Du hast geschrieben und wartest |
| | **Zurückgestellt** | Ausgeblendete Gespräche |
| | **Alle Gespräche** | Alles, auch Info und Erledigt |
| Belege & Aufräumen | **Rechnungen** | Ausgelesene Rechnungen, CSV-Export |
| | **Einladungen** | Kalendereinladungen aus Mails |
| | **Newsletter** | Absender zum Abbestellen |
| System | **Regeln & VIP** | Eigene Regeln, VIP-Liste, gelernte Korrekturen |
| | **Claude-Nutzung** | Aufrufe, Token, Abo-Auslastung |
| | **Aktivität** | Protokoll mit Rückgängig |
| | **Einstellungen** | Alle Optionen |

Zahlen neben den Einträgen zeigen offene Punkte: Gespräche mit Antwortbedarf, wartende und zurückgestellte Gespräche, Rechnungen, die überfällig oder in den nächsten 7 Tagen fällig sind, neue Einladungen und Regelvorschläge. MailPilot hat kein Dock-Symbol; es lebt in der Menüleiste. Das Dashboard-Fenster öffnet sich beim Start, Schließen beendet die App nicht (beenden über das Menüleisten-Fenster). Unten in der Seitenleiste steht der aktuelle Status. Oben im Fenster löst **Jetzt prüfen** (⟳) sofort einen Durchlauf aus.

---

## 3. Täglich arbeiten

### Wie MailPilot Mails verarbeitet

Alle X Minuten (Standard: 5) liest MailPilot neue Mails der letzten Tage (Standard: 3) aus den Posteingängen und, wenn aktiviert, den Gesendet-Ordnern, höchstens 20 pro Durchlauf; der Rest folgt im nächsten. Dann:

1. Mails werden zu **Gesprächen** gruppiert (über die Mail-Header `References`/`In-Reply-To`, sonst über Betreff und Gegenseite).
2. Claude **kategorisiert** jede Mail, vergibt eine Priorität, fasst sie zusammen und pflegt pro Gespräch Status, Zusammenfassung, nächsten Schritt und Frist.
3. Bei Mails, auf die du antworten sollst, schreibt Claude einen **Antwortentwurf**.
4. Mails werden bei Bedarf in einen Ordner `Claude/<Kategorie>` **verschoben** und mit einer **Flagge** markiert.

Mails, die jünger als 14 Tage sind, werden einzeln mit Gesprächsverlauf analysiert (ein Claude-Aufruf je Mail, bis zu drei gleichzeitig), ältere gebündelt mit dem günstigeren Modell und ohne Antwortentwurf. Antwortentwürfe entstehen nur, wenn die Option aktiv ist und eine Antwort erwartet wird. Auch deine gesendeten Mails werden analysiert, damit der Gesprächsstand stimmt (siehe [Claude-Nutzung](#8-claude-nutzung-und-limits)). Die Schalter *Mails automatisch in Ordner verschieben* und *Mails automatisch markieren* gelten für alles, auch für Regeln und VIPs. Schlägt die Analyse einer Mail fehl, versucht MailPilot es bis zu dreimal mit je 15 Minuten Abstand; Anmelde- und Limitprobleme zählen dabei nicht als Fehlversuch.

### Gesprächsstatus

| Status | Bedeutung |
|---|---|
| **Antwort nötig** | Du bist am Zug |
| **Wartet auf Antwort** | Du hast geschrieben oder gefragt und wartest |
| **Zur Info** | Keine Aktion nötig |
| **Erledigt** | Abgeschlossen |

Den Status kannst du in jedem Gespräch über das Menü **Status** ändern oder mit **Erledigt** abschließen.

### Ein Gespräch öffnen

Im Gesprächsfenster siehst du:

- **Kopf:** Status, Hinweise (VIP, Wichtig, Vertraulich), Kategorie, Betreff, Gegenseite und Nachrichtenzahl, dazu die Menüs *Zurückstellen*, *Kategorie*, *Absender* und *Status*.
- **Stand:** Zusammenfassung des Gesprächs, nächster Schritt und Frist.
- **Antwortentwurf:** ein frei bearbeitbarer Text (siehe unten).
- **Verlauf:** alle Nachrichten mit Kurzfassung, Ordner und dem Hinweis, wer die Kategorie bestimmt hat (Claude, Regel, VIP, Korrektur). *Volltext* zeigt den Mailtext, das Briefumschlag-Symbol öffnet die Mail in Apple Mail.

### Antwortentwürfe

Der Entwurf erscheint im Textfeld und lässt sich beliebig ändern.

- **Neu schreiben:** Schreibe eine Anweisung in das Feld darunter, z. B. „kürzer, Termin Dienstag vorschlagen“, und drücke Return oder *Neu schreiben*. Claude formuliert den Entwurf entsprechend neu.
- **Zeiten vorschlagen:** Schreibt den Entwurf neu und nennt freie Zeiten aus deinem Kalender (siehe [Freie Zeiten](#freie-zeiten-in-entwürfen)).
- **Speichern:** Übernimmt deine Änderungen in MailPilot.
- **In Entwürfe legen:** Legt die Antwort still im Ordner „Entwürfe“ des Mail-Kontos ab – ohne Fenster.
- **In Mail öffnen:** Öffnet ein Antwortfenster in Apple Mail mit deinem Text über dem zitierten Original. Hatte die Mail mehr als einen Empfänger (An und Cc zusammen), wird **„Allen antworten“** verwendet – prüfe die Empfänger vor dem Senden.

In beiden Fällen **wird nichts gesendet**. Das tust du in Mail.

Die Entwürfe orientieren sich an deinem Schreibstil, wenn *Einstellungen → Antwortstil* aktiv ist (siehe [Antwortstil](#antwortstil)).

### Zurückstellen

Mit *Zurückstellen* blendest du ein Gespräch aus Listen und Zählern aus und holst es später zurück: **Heute Abend** (18 Uhr, nur bis 17:30), **Morgen früh** (8 Uhr), **Montag**, **In einer Woche** oder **Datum und Uhrzeit …** frei gewählt.

- Kommt im Gespräch eine neue eingehende Nachricht an, ist es sofort wieder da.
- Läuft die Zeit ab, erhältst du eine Mitteilung. Geprüft wird bei jedem Durchlauf, die Mitteilung kann sich also um das Prüfintervall verzögern.
- Zurückgestellte Gespräche findest du unter *Zurückgestellt*; dort hebst du die Zurückstellung auch wieder auf.

### Nachfassen

Wartet ein Gespräch länger als X Tage auf Antwort (Standard: 3), gilt es als **überfällig**. MailPilot meldet das per Mitteilung und schreibt automatisch eine freundliche **Nachfrage** (höchstens drei Entwürfe pro Durchlauf). Mit *In Mail öffnen* entsteht eine neue Nachricht an dieselben Empfänger, inklusive Zitat deiner letzten Mail; *In Entwürfe legen* speichert sie still. Antwortet die Gegenseite, wird der Nachfass-Entwurf verworfen.

### Fristen

Nennt eine Mail eine Frist, trägt Claude sie ins Gespräch ein. Du kannst Fristen auch selbst setzen, ändern oder entfernen: im Gespräch beim Fristfeld über das Menü (⋯).

- **Automatisch übernehmen:** Unter *Einstellungen → Fristen* wählst du, ob Fristen als Erinnerung (9 Uhr am Fristtag), als ganztägiger Termin oder als beides eingetragen werden. Jede Frist wird nur einmal eingetragen, Werbung und Newsletter werden ausgenommen.
- **Von Hand:** Im Menü des Fristfelds *In Erinnerungen eintragen* bzw. *In Kalender eintragen*.
- Für Termine musst du unter *Einstellungen → Fristen* einen Kalender wählen, sonst werden keine angelegt.

### Mitteilungen

MailPilot meldet sich bei VIP-Mails, wichtigen Mails mit Antwortbedarf, überfälligen Follow-ups, fertigen Nachfass-Entwürfen, abgelaufenen Zurückstellungen und wenn das Briefing bereit ist. Mitteilungen zu einem Gespräch haben Knöpfe:

- **Antworten** – öffnet das Antwortfenster mit dem Entwurf
- **Morgen früh wieder zeigen**
- **Erledigt**

Ein Klick auf die Mitteilung selbst öffnet das Gespräch im Dashboard. Mitteilungen lassen sich unter *Einstellungen → Automatik* abschalten. Sie funktionieren nur, wenn MailPilot als App (`build/MailPilot.app`) läuft, und brauchen die Erlaubnis in den Systemeinstellungen. Außerdem gibt es Mitteilungen zum fertigen Erstscan und wenn Verschieben in einem Konto gesperrt wird.

### Briefing

Ab einer einstellbaren Uhrzeit (Standard: 8 Uhr) fasst Claude den Tag zusammen: Kurzfazit, was heute wichtig ist, worauf du antworten musst, worauf du wartest, Fristen und fällige Rechnungen. Unter *Briefing* kannst du es jederzeit neu erstellen. Vertrauliche Gespräche kommen im Briefing nie vor.

---

## 4. Mails sortieren: Kategorien, Regeln und VIP

### Kategorien

Claude ordnet jede Mail genau einer Kategorie zu. Standard sind: *Handlung nötig*, *Termine*, *Persönlich*, *Info*, *Rechnungen*, *Bestellungen*, *Benachrichtigungen*, *Newsletter* und *Werbung*.

Unter *Einstellungen → Kategorien* bearbeitest du pro Kategorie:

- **Name** und **Symbol**
- **Beschreibung für Claude** – daran orientiert sich die Zuordnung; formuliere sie präzise
- **Zielordner** (ohne Präfix). Leer bedeutet: im Posteingang lassen. Mit Präfix `Claude/` ergibt „Rechnungen“ den Ordner `Claude/Rechnungen` im jeweiligen Konto
- **Flagge** in einer von sieben Farben, oder keine

Du kannst Kategorien hinzufügen, löschen oder mit *Standard wiederherstellen* zurücksetzen. Unter *Einstellungen → Claude → Eigene Anweisungen* gibst du Claude zusätzliche Hinweise (Tonalität, Signatur, wichtige Personen).

Mails mit hoher Priorität werden rot markiert, sofern keine Regel eine andere Flagge setzt. Beim Einsortieren gilt außerdem: Ist eine Mail älter als die eingestellte Zeit (Standard: 30 Tage), gehört zu einem Gespräch mit Status *Info* oder *Erledigt* und hat keinen eigenen Kategorie-Ordner, kommt sie in den Archivordner (`Claude/Archiv`). Das geschieht nur beim Einsortieren (typischerweise im Erstscan oder beim Anwenden von Regeln), nicht nachträglich, wenn eine Mail erst später altert.

**Wichtig:** Einige Funktionen erkennen Kategorien am Namen: *Newsletter* (Newsletter-Bereich, Vorfilter), *Benachrichtigungen* (Vorfilter), *Termine* (Einladungssuche), *Werbung* und *Newsletter* (keine automatischen Fristen) sowie die in den Einstellungen gewählte Rechnungs-Kategorie. Benenne diese Kategorien nicht um und lösche sie nicht, sonst fallen die jeweiligen Funktionen weg.

### Eigene Regeln

Unter *Regeln & VIP* legst du Regeln an, die **vor Claude** gelten. Eine Regel besteht aus Bedingungen und Aktionen.

**Wenn** – eine oder mehrere Bedingungen, verknüpft mit „alle“ oder „mindestens eine“:

- *Absender enthält* (z. B. `name@firma.de` oder ein Namensteil)
- *Absender-Domain ist* (`firma.de`; Subdomains zählen mit)
- *Betreff enthält*
- *Text enthält*
- *Empfänger enthält*

**Dann** – beliebig kombinierbar:

- **Kategorie** und **Priorität** setzen
- **Flagge** setzen
- **Ordner** festlegen oder **Im Posteingang lassen**
- **Ohne Claude einordnen** – die Mail bekommt die Kategorie sofort, ohne Zusammenfassung und ohne Entwurf; das Gespräch gilt als „Zur Info“. Das spart Claude-Aufrufe. Braucht eine Kategorie und gilt nicht in laufenden Gesprächen (Status *Antwort nötig* oder *Wartet auf Antwort*), dort entscheidet weiter Claude.

Regeln werden von oben nach unten ausgewertet: **Die erste Regel, die ein Feld setzt, gewinnt.** Mit den Pfeilen änderst du die Reihenfolge. Mit *Testen* siehst du, auf wie viele gespeicherte Mails eine Regel zutrifft. Eine Regel ohne Aktion ist als „Ohne Aktion“ gekennzeichnet.

Schneller geht es aus einem Gespräch: Menü **Absender → Regel für diesen Absender …** bzw. **Regel für die Domain …** legt einen Entwurf an, den du nur noch bestätigst.

**Auf vorhandene Mails anwenden:** Neue Regeln wirken zunächst nur auf neue Mails. Mit *Auf vorhandene Mails anwenden …* siehst du, wie viele gespeicherte Mails sich ändern würden, und kannst sie umsortieren lassen. Verschiebungen lassen sich unter *Aktivität* rückgängig machen.

### VIP-Liste

Mails von VIPs bekommen immer **hohe Priorität**, werden markiert (Farbe einstellbar) und lösen auf Wunsch eine Mitteilung aus. Einträge sind E-Mail-Adressen oder Domains. Im Gespräch markierst du den Absender über **Absender → Absender als VIP markieren**. Wenn du Kontakte freigegeben hast, kannst du eine **Kontaktgruppe** als VIP-Liste verwenden (*Einstellungen → Kontakte*); diese Einträge tragen den Vermerk „Kontakte“.

### Lernen aus Korrekturen

Sortierst du eine einsortierte Mail um, merkt sich MailPilot das:

- in Apple Mail, indem du sie in einen anderen Kategorie-Ordner oder zurück in den Posteingang legst, oder
- im Dashboard über das Menü **Kategorie** im Gespräch. Das betrifft die letzte eingegangene Mail des Gesprächs. MailPilot verschiebt sie dann auch, aber nur in Konten mit geprüftem Verschieben; sonst wird die Kategorie nur gespeichert.

Löschst du eine Mail oder legst sie in einen anderen Ordner, ist das kein Lernsignal.

Claude erhält die Korrekturen als Hinweis zum Absender. Nach wiederholten Korrekturen schlägt MailPilot eine **Regel** vor (2× je Absender, 3 Absender je Domain). Die Vorschläge stehen oben unter *Regeln & VIP*: *Regel anlegen* oder *Verwerfen*. Abschalten lässt sich das mit „Aus Korrekturen lernen“. Für Absender, die du schon einmal korrigiert hast, entscheidet nie der Vorfilter.

### Weniger Claude-Aufrufe

MailPilot ordnet offensichtlich automatische Mails **ohne Claude** ein:

- Mails mit dem Header `Auto-Submitted` → *Benachrichtigungen*
- Mails mit `List-Unsubscribe` (bzw. Massenmail-Kennzeichen) → *Newsletter*
- Absender wie `noreply@` → *Benachrichtigungen*
- Wiederkehrende Absender, die bisher fast immer (90 %, mindestens 3 Mails) als Newsletter, Werbung oder Benachrichtigung eingeordnet wurden

Mails mit Wörtern wie Rechnung, Bestellung, Termin, Frist oder dringend sowie laufende Gespräche gehen **immer** an Claude. Der Vorfilter lässt sich in den Einstellungen abschalten.

### Verschiebe-Schutz

Nach jedem Verschieben prüft MailPilot, ob die Mail im Zielordner angekommen ist. Manche Konten (vor allem Exchange und manche IMAP-Konten mit Unterordnern) zeigen verschobene Mails dort nicht an. In solchen Konten wird dann **nur noch markiert, nicht verschoben**.

- In *Einstellungen → Konten* zeigt jedes Konto seinen Status: *Verschieben geprüft*, *Nur markieren – Ordner nicht lesbar* oder *Verschieben aus – ungeprüft*.
- In ungeprüften Konten wird nie verschoben. Mit **Verschieben testen …** erlaubst du ausdrücklich eine einzelne Probe-Verschiebung. Achtung: Bei manchen Konten (Exchange) kann diese Mail danach in Mail unsichtbar sein. Teste zuerst mit einem Konto, in dem das nicht schadet.
- *Erneut prüfen* wiederholt den Test, z. B. nach Änderungen am Konto.
- Gmail-Mails im Ordner „Alle Nachrichten“ werden nie verschoben, nur markiert.

### Aktivität und Rückgängig

*Aktivität* protokolliert alles, was MailPilot tut: Verschiebungen, Flaggen, erkannte Korrekturen, Fehler. Bei Verschiebungen und Flaggen gibt es **Rückgängig**. MailPilot merkt sich den Zustand vor dem Markieren; mit *Alle Flaggen zurücknehmen* setzt du alle Flaggen auf einmal zurück. Im Probelauf stehen die Einträge als „Würde …“ im Protokoll.

---

## 5. Rechnungen, Einladungen, Newsletter

### Rechnungen

Mails der Kategorie „Rechnungen“ (einstellbar) werden samt PDF-Anhang ausgelesen: eingebetteter Text, bei Scans per Texterkennung. MailPilot erfasst Aussteller, Rechnungsnummer, Betrag brutto, Umsatzsteuer, Rechnungsdatum und Fälligkeit und erkennt bereits bezahlte Belege.

In *Rechnungen*:

- Übersicht mit **Summen** und den Zuständen *offen*, *bezahlt* und *überfällig*
- Vier Kacheln: *Offen*, *Überfällig*, *Fällig in 7 Tagen*, *Dieser Monat*; Filter *Offen*, *Bezahlt*, *Alle*, *Prüfen* (Einträge mit Fehler oder „Keine Rechnung“)
- Noch nicht ausgelesene Mails werden mit „N auslesen“ nachgeholt; automatisch liest MailPilot je Durchlauf bis zu 6
- Doppelklick, Rechtsklick oder die Knöpfe unten: **Als bezahlt markieren** / **Wieder auf offen setzen**, **Bearbeiten …** (Korrekturformular), **Neu auslesen**, **Mail öffnen**, **Entfernen**
- **CSV exportieren …** für die Buchhaltung: exportiert die gerade angezeigten Zeilen (Semikolon, Dezimalkomma, deutsches Datum, UTF-8 mit BOM). Spalten: Rechnungsdatum, Fälligkeit, Aussteller, Rechnungsnummer, Betrag brutto, davon USt, Währung, Status, Beschreibung, Absender, Betreff, Konto, Mail-Datum, Quelle, Datei

Pro Mail werden bis zu 3 PDF-Anhänge (je höchstens 12 MB) gelesen, davon die ersten 6 Seiten. Enthält ein PDF kaum Text, versucht MailPilot Texterkennung auf den ersten beiden Seiten. Ein Claude-Aufruf je Rechnung.

Die Fälligkeit wird zur Frist des Gesprächs (und damit auf Wunsch zur Erinnerung), sofern das Gespräch noch keine Frist hat. Überfällige und innerhalb von 14 Tagen fällige Rechnungen erscheinen im Briefing. Mit „Rechnungen aus Mails und PDF-Anhängen auslesen“ in den Einstellungen schaltest du die Funktion ab.

**Hinweis zu „Entfernen“:** Entfernte Einträge sind nicht dauerhaft weg. Die Mail liegt weiter in der Rechnungs-Kategorie und wird beim nächsten Durchlauf erneut ausgelesen. Um eine Mail dauerhaft loszuwerden, ändere ihre Kategorie.

Prüfe ausgelesene Beträge immer stichprobenartig – die Erkennung kann sich irren.

### Einladungen

Kalenderanhänge (`.ics`) in Mails werden gelesen, einschließlich Zeitzonen, ganztägiger Termine, Absagen und Änderungen. In *Einladungen* siehst du jede Einladung mit Titel, Zeit, Ort und Organisator sowie mögliche **Überschneidungen** mit deinen Terminen.

- **In Kalender eintragen** übernimmt den Termin in den gewählten Kalender (mit Ort, Organisator und Link zur Mail).
- **Ignorieren** / **Ausblenden** / **Wieder anzeigen** verwalten die Liste. Reiter: *Neu*, *Eingetragen*, *Ignoriert* (dort landen auch vergangene, nie eingetragene Termine).
- Mit *Einstellungen → Fristen → Einladungen aus Mails automatisch eintragen* geschieht das ohne Klick, für künftige, nicht abgesagte Termine.

Voraussetzung ist ein gewählter Kalender unter *Einstellungen → Fristen*. Gesucht wird in Mails der letzten 30 Tage mit einladungstypischem Betreff (z. B. Einladung, Termin, Meeting, Webinar, abgesagt) oder der Kategorie „Termine“; automatisch fünf Mails je Durchlauf, mit *Jetzt suchen* bis zu 25.

**Grenzen:** Bei wiederkehrenden Terminen wird nur der erste Termin eingetragen. Ändert der Organisator die Zeit, erscheint die Einladung erneut als „Neu“ und kann ein zweites Mal eingetragen werden; der alte Kalendereintrag bleibt bestehen. Absagen ändern oder löschen nichts im Kalender. MailPilot ändert nie vorhandene Kalendereinträge.

### Newsletter abbestellen

Der Bereich arbeitet mit Mails der Kategorie **„Newsletter“** (Name nicht ändern). Ein Absender wird vorgeschlagen, wenn er in den letzten 90 Tagen mindestens 4 Mails schickte, der Lesestatus bekannt ist und höchstens jede zehnte Mail gelesen wurde. „Gelesen“ ist, was in Apple Mail als gelesen markiert ist (auch durch die Vorschau). Den Lesestatus gleicht MailPilot stündlich ab, *Lesestatus abgleichen* sofort. Absender auf der VIP-Liste und solche, denen du je geschrieben hast, werden nie vorgeschlagen.

- **Abbestellen …** (nach Rückfrage) meldet dich ab: per **Ein-Klick-Abmeldung** nach RFC 8058 (eine Anfrage ohne Cookies und ohne Weiterleitung an den Server des Absenders; lässt sich nicht zurücknehmen), über die **Abmelde-Webseite** (öffnet im Browser, dort bestätigst du selbst) oder mit einer **vorbereiteten E-Mail** (gesendet wird erst, wenn du in Mail auf Senden klickst). Ohne gefundene Abmeldemöglichkeit ist der Knopf gesperrt.
- Bei Webseite und E-Mail gilt der Absender sofort als „Abbestellt“, auch wenn du die Abmeldung nicht abschließt. Prüfe das im Zweifel.
- Im Reiter *Abbestellt* siehst du, ob danach (nach mehr als 7 Tagen) noch Mails kamen.
- **Behalten** entfernt den Vorschlag (Reiter *Behalten*), **Wieder vorschlagen** holt ihn zurück.
- Unsichere Ziele werden nie angesprochen: nur https, keine Zugangsdaten in der Adresse, keine IP-Adressen und keine lokalen Hosts (`.local`, `.lan`, `localhost` …).

---

## 6. Berichte und Suche

### Volltextsuche

*Suche* (⌘F) durchsucht Betreff, Absender, Zusammenfassungen und Mailtexte **aller gespeicherten Gespräche**, auch bereits verschobener Mails. Umlaute und Groß-/Kleinschreibung sind egal; Phrasen setzt du in Anführungszeichen. Treffer lassen sich direkt in Mail öffnen.

### Wochenbericht

Der Wochenbericht erscheint montags ab der Briefing-Uhrzeit automatisch (höchstens einmal pro Woche) und lässt sich mit *Neu erstellen* jederzeit auffrischen. Er vergleicht die letzten 7 Tage mit der Woche davor und zeigt:

- Zahl empfangener und gesendeter Mails
- Wachstum der Kategorien
- deine **mediane Antwortzeit** (Zeit bis zu deiner nächsten Mail im Gespräch, höchstens 14 Tage)
- **„Hier bist du säumig“:** Gespräche mit Antwortbedarf, die seit mehr als 2 Tagen offen sind
- **„Hier wartest du“:** Gespräche, in denen du seit mehr als 3 Tagen wartest (fest, unabhängig von der Follow-up-Einstellung)
- neue und überfällige Rechnungen
- eine kurze Auswertung mit Empfehlungen von Claude

Zurückgestellte und vertrauliche Gespräche fehlen im Bericht. Ist Claude gerade nicht erreichbar, bekommst du die Zahlen ohne Text.

### Antwortstil

Damit Entwürfe nach dir klingen, lernt MailPilot aus deinen gesendeten Mails (ohne zitierte Verläufe) einen **Stilleitfaden**: Anrede, Du/Sie, Grußformeln, Tonfall, Satzlänge, typische Wendungen.

- Voraussetzung: *Gesendete Mails einbeziehen* ist aktiv und es gibt mindestens 10 geeignete Mails (40–1500 Zeichen, keine Abwesenheitsnotizen, keine reinen Link-Mails; höchstens 3 je Empfänger).
- *Einstellungen → Antwortstil → Stil lernen* erzeugt den Leitfaden aus bis zu 40 Mails. *Sendeverlauf einlesen (180 Tage)* holt ältere gesendete Mails nur für den Stil nach (ohne Analyse). Sind genug Mails da und ist noch kein Stil gelernt, lernt MailPilot automatisch, höchstens einmal am Tag.
- Der Leitfaden ist frei bearbeitbar.
- Beim Neuschreiben eines Entwurfs (*Neu schreiben*) kommen der Leitfaden und bis zu zwei frühere Mails an dieselbe Person als Beispiel mit; die automatisch vorbereiteten Entwürfe nutzen nur den Leitfaden.
- Mails an Empfänger mit Datenschutz-Ausnahme werden nie verwendet.

### Freie Zeiten in Entwürfen

Erkennt MailPilot in der letzten eingegangenen Mail einen Terminwunsch (Wörter wie Termin, Treffen, Meeting, Besprechung, Call, verfügbar, Rückruf), nennt der Entwurf freie Zeiten aus deinem Kalender. Mit *Zeiten vorschlagen* erzwingst du das. **Es gehen nur Zeiträume an Claude, nie Titel, Orte oder Teilnehmer.**

Unter *Einstellungen → Kalender & freie Zeiten* erlaubst du den Kalenderzugriff und legst Arbeitszeit, Terminlänge (30–120 Minuten) und die zu berücksichtigenden Kalender fest (keiner gewählt = alle außer Geburtstagen). Vorgeschlagen werden bis zu drei Zeiträume in den nächsten rund zehn Tagen: nur Montag bis Freitag, höchstens zwei je Tag (vormittags bis 12 Uhr, nachmittags ab 13 Uhr), auf halbe Stunden gerundet und frühestens in zwei Stunden. Ganztägige, abgesagte, von dir abgelehnte und als „frei“ markierte Termine blockieren nichts. Claude formuliert die Zeiten als Vorschlag und sagt nichts zu.

### Kontakte

Mit Zugriff auf die Kontakte-App zeigt MailPilot Namen an, wenn eine Mail keinen enthält, und kann eine Kontaktgruppe als VIP-Liste nutzen. Das Adressbuch wird nur lokal gelesen. **Beachte:** Ein so ermittelter Name wird als Gegenüber des Gesprächs gespeichert und kann daher in Briefing, Wochenbericht und Entwürfen an Claude gehen. Wer das nicht möchte, schaltet „Namen aus Kontakten verwenden“ aus.

---

## 7. Datenschutz

Zur Analyse werden Mailinhalte an Claude übergeben. Claude hat dabei **keine Tools** und kann nur das vorgegebene JSON bzw. den Text zurückgeben; die Aktionen (Ordner, Flaggen) bestimmt die App. Die Claude-CLI speichert keine Sitzungen.

Alle Daten liegen lokal in `~/Library/Application Support/MailPilot/`.

### Datenschutz-Ausnahmen

Für besonders vertrauliche Mails legst du unter *Einstellungen → Datenschutz* **Ausnahmen** an: Absender, Domains oder Stichworte in Betreff und Text (bei gesendeten Mails zählen die Empfänger). Auf diese Mails und alle Gespräche, die sie enthalten, hat Claude **nie** Zugriff:

- keine Analyse, kein Entwurf, kein Briefing, keine Rechnungsauslesung
- weder Mailtext noch Betreff noch Absender

Solche Gespräche sind als *Vertraulich* gekennzeichnet. MailPilot sortiert sie nur mit deinen eigenen Regeln und der VIP-Liste.

- **Mailtext nicht speichern (empfohlen):** Dann behält MailPilot den Text dieser Mails gar nicht.
- **Gespeicherte Mails prüfen …:** Wendet eine neue Ausnahme nachträglich an: Mailtext und Zusammenfassung der Mails, auf die die Ausnahme selbst zutrifft, werden von diesem Rechner entfernt, ihre Gespräche gelten fortan als vertraulich. Andere, ältere Mails desselben Gesprächs behalten ihren gespeicherten Text, gehen aber nicht mehr an Claude. Bereits an Claude gesendete Inhalte lassen sich nicht zurückholen; die Mails in Apple Mail bleiben unverändert.
- Schnell geht es im Gespräch über **Absender → Von Claude ausschließen …**.

---

## 8. Claude-Nutzung und Limits

*Claude-Nutzung* zeigt Aufrufe, Token und Dauer je Tag und Zweck sowie die **Abo-Auslastung** (5-Stunden- und 7-Tage-Fenster, aus der Claude-CLI). Ohne aktuelle Messung hilft *Jetzt abfragen* (ein winziger Aufruf).

**Schutz vor Überlast:** Erreicht die Auslastung die eingestellten Schwellen (Standard: 90 %, einstellbar von 50 bis 100 %) oder das optionale Tageslimit automatischer Aufrufe, **pausieren automatische Aufrufe**. Im Status steht dann der Grund. Meldet die Claude-CLI ein erreichtes Limit, pausiert MailPilot bis zum Zurücksetzen des Fensters (mindestens 30 Minuten).

Was du gezielt per Knopf auslöst (Entwurf neu schreiben, Briefing, Wochenbericht oder Stil neu erstellen, Rechnungen auslesen, Verbindung testen), läuft trotzdem. **Nicht dazu gehören „Jetzt prüfen“ und „Prüfen“:** Sie starten einen normalen Durchlauf und respektieren die Pause.

**Folge der Pause:** Muss in einem Durchlauf eine Mail von Claude analysiert werden, bricht der Durchlauf ab. Das Verschieben und Markieren, Korrekturerkennung, Fristen und Sicherung warten dann bis zum Ende der Pause, auch für Mails, die MailPilot lokal einordnen könnte.

**Aufrufe grob:** Eine Mail unter 14 Tagen kostet einen Aufruf, zehn ältere Mails einen gemeinsamen. Dazu kommen Nachfass-Entwürfe (höchstens 3 je Durchlauf), Rechnungen (höchstens 6 je Durchlauf), Briefing, Wochenbericht und Stil. Newsletter und Systemmeldungen sowie Regeln mit „Ohne Claude“ sparen Aufrufe, unter *Claude-Nutzung → Ohne Claude* siehst du, wie viele.

**Modelle:** Unter *Einstellungen → Claude* wählst du das Hauptmodell (Sonnet empfohlen, Haiku schnell, Opus gründlich) und das Modell für ältere Mails (Standard: Haiku). *Ältere Mails: N pro Claude-Aufruf* legt fest, wie viele ältere Mails gebündelt analysiert werden (1–25, Standard 10). Mit *Verbindung testen* prüfst du die CLI.

---

## 9. Sicherung und Export

Alles dazu steht unter *Einstellungen → Daten & Sicherung*.

- **Tägliche Sicherung** der Datenbank; die letzten 7 bleiben erhalten (einstellbar). *Jetzt sichern* und *Sichern unter …* erstellen Sicherungen von Hand.
- **Wiederherstellen:** Wähle eine Sicherung aus. MailPilot beendet sich und spielt sie beim nächsten Start ein. Der bisherige Stand bleibt als „vor-wiederherstellung-…“ im Sicherungsordner erhalten.
- **Export:** *Daten als JSON …* (Mailtexte nur auf Wunsch, vertrauliche nie) und *Gespräche als CSV …*.
- **Einstellungen übertragen:** *Einstellungen exportieren …* und *Importieren …* sichern die komplette `settings.json` (Regeln, Kategorien, VIPs, Ausnahmen, Modelle, Konto-, Kalender- und Erinnerungsauswahl, eigene Anweisungen). Beim Import werden alle aktuellen Einstellungen ersetzt; auf einem anderen Rechner musst du Konten, Kalender und den Pfad zur Claude-CLI gegebenenfalls neu wählen.
- Die Sicherungen liegen unter `~/Library/Application Support/MailPilot/backups`. Automatische und mit *Jetzt sichern* erstellte Sicherungen zählen zu den „letzten N“; ältere werden gelöscht. Die Sicherheitskopien „vor-wiederherstellung-…“ bleiben erhalten.

Sicherungen enthalten auch gespeicherte Mailtexte – bewahre sie entsprechend auf.

---

## 10. Einstellungen im Überblick

| Abschnitt | Wichtige Optionen |
|---|---|
| **Konten** | Konten aktivieren; Status des Verschiebe-Schutzes |
| **Automatik** | Verschieben, Markieren, Entwürfe, Nachfass-Entwürfe, Rechnungen auslesen, **Probelauf**, gesendete Mails einbeziehen, Mitteilungen, Ordner-Präfix, Archivierung |
| **Zeitplan** | Prüfintervall, Zeitraum (letzte Tage), Mails pro Durchlauf, Paketgröße, Follow-up-Tage, Briefing-Uhrzeit, Start beim Anmelden |
| **Fristen** | Ziel (Erinnerungen/Kalender/beides), Erinnerungsliste, Kalender, automatische Einladungen |
| **Datenschutz** | Ausnahmen für Absender, Domains, Stichworte |
| **Antwortstil** | Stil lernen, Leitfaden bearbeiten |
| **Kontakte** | Zugriff, Namen, VIP-Kontaktgruppe |
| **Kalender & freie Zeiten** | Zugriff, Arbeitszeit, Terminlänge, Kalender |
| **Claude** | Modelle, Vorfilter, Umfang des Erstscans, Pfad zur CLI, Verbindungstest, eigene Anweisungen |
| **Kategorien** | Name, Beschreibung, Zielordner, Flagge, Symbol |
| **Daten & Sicherung** | Sicherung, Wiederherstellung, Export |

---

## 11. Tastenkürzel

Im Menü **Gespräch** (bei geöffnetem Dashboard):

| Kürzel | Aktion |
|---|---|
| ⌘F | Suche |
| ⌘J | Gespräch bis morgen früh zurückstellen |
| ⇧⌘J | Gespräch bis Montag zurückstellen |
| ⌘E | Gespräch als erledigt markieren |
| ⌘R | Antwort in Mail öffnen |
| ⌘0 | Briefing |
| ⌘1 | Antwort nötig |
| ⌘2 | Warte auf Antwort |
| ⌘3 | Zurückgestellt |
| ⌘4 | Rechnungen |

Die Aktionen wirken auf das gerade geöffnete Gespräch.

---

## 12. Fehlerbehebung

| Problem | Lösung |
|---|---|
| „Claude Code CLI nicht gefunden“ | Pfad unter *Einstellungen → Claude* eintragen (`which claude` im Terminal). MailPilot sucht automatisch u. a. in `~/.local/bin` und `/opt/homebrew/bin`. |
| „Claude Code ist nicht angemeldet“ | Im Terminal `claude` starten und `/login` ausführen. |
| „Keine Berechtigung, Apple Mail zu steuern“ | *Systemeinstellungen → Datenschutz & Sicherheit → Automation* → MailPilot den Zugriff auf Mail erlauben. |
| Status „Pausiert: …“ | Das Abo-Limit ist fast erreicht (siehe *Claude-Nutzung*). MailPilot setzt automatisch fort, sobald das Limit wieder frei ist. Schwellen sind einstellbar. |
| Mails werden nicht verschoben, nur markiert | Das Konto ist ungeprüft oder gesperrt (Exchange, Gmail „Alle Nachrichten“). Siehe [Verschiebe-Schutz](#verschiebe-schutz). |
| Eine verschobene Mail ist in Mail verschwunden | Unter *Aktivität* findest du den Eintrag; mit **Rückgängig** legst du sie zurück. Bei Konten, deren Ordner nicht lesbar sind, kann die Mail nur auf dem Server liegen. |
| Mails erscheinen nicht im Dashboard | Prüfe, ob das Konto aktiviert und der Erstscan abgeschlossen ist, und ob der Zeitraum (*Zeitplan*) die Mail umfasst. Mit *Jetzt prüfen* löst du sofort einen Durchlauf aus. |
| Es werden keine Termine angelegt | Unter *Einstellungen → Fristen* einen Kalender wählen und die Berechtigung erteilen. |
| Eine Mail zeigt einen Analysefehler | MailPilot versucht es bis zu dreimal. Danach wird die Mail übersprungen; der Fehler steht beim Eintrag im Verlauf. |
| Zu viele Claude-Aufrufe | Vorfilter aktiv lassen, Erstscan auf wenige Tage begrenzen, Regeln mit „Ohne Claude einordnen“ anlegen, Paketgröße erhöhen. |

### Sicherheitsgrenzen

- Ordner werden nie gelöscht, Mails nie gelöscht oder gesendet.
- Entwürfe werden nur geöffnet oder im Ordner „Entwürfe“ abgelegt.
- Der Probelauf ändert nichts in Mail.

### Kommandozeilen-Tests (für Entwickler)

Ohne Änderungen an Mail lassen sich die Funktionen prüfen:

```bash
.build/release/MailPilot --selftest-rules
.build/release/MailPilot --selftest-features
.build/release/MailPilot --selftest-more
.build/release/MailPilot --selftest --analyze
```

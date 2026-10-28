import Foundation

struct CalendarInfo: Decodable, Identifiable, Hashable {
    var id: String
    var name: String
    var writable: Bool
}

/// Zugriff auf Erinnerungen und Kalender (per JXA, wie bei Mail).
extension MailBridge {
    struct ExportTargets: Decodable {
        var reminderLists: [String]
        var calendars: [CalendarInfo]
    }

    struct ExportTestResult: Decodable {
        var reminderCreated: Bool
        var reminderDeleted: Bool
        var eventCreated: Bool
        var eventDeleted: Bool
        var errors: [String]
    }

    private static let exportScript: URL = {
        let url = Paths.scripts.appendingPathComponent("export.js")
        try? exportJS.write(to: url, atomically: true, encoding: .utf8)
        return url
    }()

    func exportTargets() async throws -> ExportTargets {
        let out = try await run(Self.exportScript, ["mode": "lists"])
        return try JSONDecoder().decode(ExportTargets.self, from: Data(out.utf8))
    }

    /// Legt eine Erinnerung (fällig am `due`-Tag um 9 Uhr) an und liefert ihre ID.
    func createReminder(title: String, notes: String, due: String, list: String) async throws -> String? {
        let out = try await run(Self.exportScript, ["mode": "reminder", "title": title, "notes": notes, "due": due, "list": list])
        return (try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])?["id"] as? String
    }

    /// Legt einen ganztägigen Kalendereintrag an und liefert seine ID.
    func createEvent(title: String, notes: String, due: String, calendarID: String, url: String?) async throws -> String? {
        var params: [String: Any] = ["mode": "event", "title": title, "notes": notes, "due": due, "calendarId": calendarID]
        if let url { params["url"] = url }
        let out = try await run(Self.exportScript, params)
        return (try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])?["id"] as? String
    }

    /// Legt einen Termin mit Uhrzeit (oder ganztägig) und Ort an – für Einladungen aus Mails.
    func createInviteEvent(_ e: InviteEvent, calendarID: String, url: String?) async throws -> String? {
        let iso = ISO8601DateFormatter()
        var params: [String: Any] = ["mode": "event", "title": e.summary, "notes": e.notes + (e.organizer.isEmpty ? "" : "\n\nOrganisator: \(e.organizer)"),
                                     "calendarId": calendarID, "start": iso.string(from: e.start), "end": iso.string(from: e.end), "allDay": e.allDay,
                                     "location": e.location]
        if let url { params["url"] = url }
        let out = try await run(Self.exportScript, params)
        return (try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])?["id"] as? String
    }

    /// Selbsttest: legt Erinnerung und Termin an und löscht beide sofort wieder.
    func testExport(list: String, calendarID: String, due: String) async throws -> ExportTestResult {
        let out = try await run(Self.exportScript, ["mode": "test", "list": list, "calendarId": calendarID, "due": due])
        return try JSONDecoder().decode(ExportTestResult.self, from: Data(out.utf8))
    }

    private static let exportJS = #"""
    function run(argv) {
      ObjC.import('Foundation');
      const p = JSON.parse($.NSString.stringWithContentsOfFileEncodingError(argv[0], $.NSUTF8StringEncoding, null).js);

      function day(s) { const a = s.split('-').map(Number); return new Date(a[0], a[1] - 1, a[2]); }

      function makeReminder(R, title, notes, due, listName) {
        let list = R.lists.byName(listName);
        if (!list.exists()) { R.lists.push(R.List({ name: listName })); list = R.lists.byName(listName); }
        const when = day(due); when.setHours(9, 0, 0, 0);
        const rem = R.Reminder({ name: title, body: notes, dueDate: when, remindMeDate: when });
        list.reminders.push(rem);
        let id = null; try { id = rem.id(); } catch (e) {}
        return { rem: rem, id: id };
      }

      function makeEvent(C, title, notes, due, calendarId, url, timed) {
        const cut = calendarId.lastIndexOf('|');
        const calName = calendarId.slice(0, cut), calIndex = Number(calendarId.slice(cut + 1));
        const matches = C.calendars().filter(c => { try { return c.name() === calName; } catch (e) { return false; } });
        const cal = matches[calIndex];
        if (!cal) throw new Error('Kalender nicht gefunden: ' + calName);
        let start = day(due);
        let end = new Date(start.getTime() + 86400000);
        const props = { summary: title, startDate: start, endDate: end, alldayEvent: true, description: notes };
        if (timed && timed.start) {
          // Einladung: mit Uhrzeit (oder ganztägig) und Ort
          props.startDate = new Date(timed.start);
          props.endDate = new Date(timed.end);
          props.alldayEvent = !!timed.allDay;
          if (timed.location) props.location = timed.location;
        }
        if (url) props.url = url;
        const ev = C.Event(props);
        cal.events.push(ev);
        let id = null; try { id = ev.uid(); } catch (e) {}
        return { ev: ev, id: id };
      }

      if (p.mode === 'lists') {
        const R = Application('Reminders'), C = Application('Calendar');
        // Einzelne Kalender (z. B. abonnierte) verweigern manchmal Eigenschaften – die überspringen, nicht abbrechen.
        // Kalender haben keine auslesbare ID; sie werden über Name und Nummer unter gleichnamigen Kalendern gefunden („Kalender|1“).
        const cals = [];
        const seen = {};
        for (const c of C.calendars()) {
          try {
            const n = c.name();
            let w = true; try { w = c.writable(); } catch (e) {}
            const k = seen[n] || 0;
            seen[n] = k + 1;
            cals.push({ id: n + '|' + k, name: n, writable: w });
          } catch (e) {}
        }
        return JSON.stringify({ reminderLists: R.lists.name(), calendars: cals });
      }
      if (p.mode === 'reminder') {
        const r = makeReminder(Application('Reminders'), p.title, p.notes, p.due, p.list);
        return JSON.stringify({ id: r.id });
      }
      if (p.mode === 'event') {
        const e = makeEvent(Application('Calendar'), p.title, p.notes, p.due || '1970-01-01', p.calendarId, p.url, p.start ? p : null);
        return JSON.stringify({ id: e.id });
      }
      // test: anlegen und sofort wieder löschen
      const out = { reminderCreated: false, reminderDeleted: false, eventCreated: false, eventDeleted: false, errors: [] };
      const R = Application('Reminders'), C = Application('Calendar');
      try {
        const r = makeReminder(R, 'MailPilot-Test (wird sofort gelöscht)', 'Testeintrag', p.due, p.list);
        out.reminderCreated = true;
        try { R.delete(r.rem); out.reminderDeleted = true; } catch (e) { out.errors.push('Erinnerung löschen: ' + e); }
      } catch (e) { out.errors.push('Erinnerung: ' + e); }
      try {
        const ev = makeEvent(C, 'MailPilot-Test (wird sofort gelöscht)', 'Testeintrag', p.due, p.calendarId, null);
        out.eventCreated = true;
        try { C.delete(ev.ev); out.eventDeleted = true; } catch (e) { out.errors.push('Termin löschen: ' + e); }
      } catch (e) { out.errors.push('Termin: ' + e); }
      return JSON.stringify(out);
    }
    """#
}

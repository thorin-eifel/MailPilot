import Foundation

struct FetchResult: Decodable {
    var messages: [RawMessage]
    var myAddresses: [String]
    var remaining: Int
}

enum BridgeError: LocalizedError {
    case script(String)

    var errorDescription: String? {
        switch self {
        case .script(let msg):
            if msg.contains("-1743") {
                return "Keine Berechtigung, Apple Mail zu steuern. Bitte in Systemeinstellungen → Datenschutz & Sicherheit → Automation MailPilot den Zugriff auf Mail erlauben."
            }
            return "Mail-Skript fehlgeschlagen: \(msg)"
        }
    }
}

/// Spricht über JXA-Skripte (osascript) mit Apple Mail.
final class MailBridge: @unchecked Sendable {
    private let fetchScript: URL
    private let actionScript: URL
    private let batchScript: URL

    init() {
        fetchScript = Paths.scripts.appendingPathComponent("fetch.js")
        actionScript = Paths.scripts.appendingPathComponent("action.js")
        batchScript = Paths.scripts.appendingPathComponent("batch.js")
        try? Self.fetchJS.write(to: fetchScript, atomically: true, encoding: .utf8)
        try? Self.actionJS.write(to: actionScript, atomically: true, encoding: .utf8)
        try? Self.batchJS.write(to: batchScript, atomically: true, encoding: .utf8)
    }

    func fetch(since: Date, sentSince: Date? = nil, known: [String], maxNew: Int, includeSent: Bool,
               contentLimit: Int = 6000) async throws -> FetchResult {
        let params: [String: Any] = [
            "since": since.isoString,
            "sentSince": (sentSince ?? since).isoString,
            "known": known,
            "maxNew": maxNew,
            "includeSent": includeSent,
            "contentLimit": contentLimit,
        ]
        let out = try await run(fetchScript, params)
        return try JSONDecoder().decode(FetchResult.self, from: Data(out.utf8))
    }

    struct Location {
        var account: String
        var mailbox: String
        var mailId: Int
    }

    /// Verschiebt eine Nachricht innerhalb ihres Kontos in `folder` (wird bei Bedarf angelegt).
    func move(messageId: String, from loc: Location, to folder: String) async throws -> Location {
        let out = try await perform(["action": "move", "target": folder], messageId: messageId, loc: loc)
        let newId = (out["newId"] as? Int) ?? loc.mailId
        return Location(account: loc.account, mailbox: folder, mailId: newId)
    }

    func flag(messageId: String, at loc: Location, color: FlagColor) async throws {
        _ = try await perform(["action": "flag", "flagIndex": color.rawValue], messageId: messageId, loc: loc)
    }

    /// Öffnet ein Antwortfenster in Mail mit `text` über dem zitierten Original. Gesendet wird nichts.
    func openReply(messageId: String, at loc: Location, text: String, replyAll: Bool) async throws {
        _ = try await perform(["action": "reply", "text": text, "replyAll": replyAll], messageId: messageId, loc: loc)
    }

    struct BatchItem {
        var messageId: String
        var location: Location
        var target: String?
        var flag: FlagColor?
    }

    struct BatchResult: Decodable {
        var messageId: String
        var ok: Bool
        var error: String?
    }

    /// Markiert und verschiebt viele Nachrichten in einem einzigen osascript-Aufruf.
    func batch(_ items: [BatchItem]) async throws -> [BatchResult] {
        let list: [[String: Any]] = items.map { it in
            var d: [String: Any] = ["messageId": it.messageId, "account": it.location.account,
                                    "mailbox": it.location.mailbox, "id": it.location.mailId]
            if let t = it.target { d["target"] = t }
            if let f = it.flag { d["flagIndex"] = f.rawValue }
            return d
        }
        let out = try await run(batchScript, ["items": list])
        return try JSONDecoder().decode([BatchResult].self, from: Data(out.utf8))
    }

    private func perform(_ extra: [String: Any], messageId: String, loc: Location) async throws -> [String: Any] {
        var params = extra
        params["messageId"] = messageId
        params["account"] = loc.account
        params["mailbox"] = loc.mailbox
        params["id"] = loc.mailId
        let out = try await run(actionScript, params)
        return (try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any]) ?? [:]
    }

    private func run(_ script: URL, _ params: [String: Any]) async throws -> String {
        // Parameter über eine Datei übergeben – die Liste bekannter IDs sprengt sonst die Argumentlänge.
        let paramFile = FileManager.default.temporaryDirectory.appendingPathComponent("mailpilot-\(UUID().uuidString).json")
        try JSONSerialization.data(withJSONObject: params).write(to: paramFile)
        defer { try? FileManager.default.removeItem(at: paramFile) }
        let result = try await ProcessRunner.run(
            executable: "/usr/bin/osascript",
            arguments: ["-l", "JavaScript", script.path, paramFile.path],
            timeout: 1800
        )
        guard result.status == 0 else {
            throw BridgeError.script(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - JXA

    private static let fetchJS = #"""
    function run(argv) {
      ObjC.import('Foundation');
      const p = JSON.parse($.NSString.stringWithContentsOfFileEncodingError(argv[0], $.NSUTF8StringEncoding, null).js);
      const Mail = Application('Mail');
      const since = new Date(p.since);
      const sentSince = new Date(p.sentSince);
      const known = {};
      p.known.forEach(k => { known[k] = true; });
      const out = { messages: [], myAddresses: [], remaining: 0 };

      try {
        Mail.accounts.emailAddresses().forEach(list => list.forEach(a => out.myAddresses.push(String(a).toLowerCase())));
      } catch (e) {}

      const idsIn = s => s ? (s.match(/<[^>]+>/g) || []).map(x => x.slice(1, -1)) : [];
      function headers(m) {
        let h = '';
        try { h = m.allHeaders() || ''; } catch (e) { return { irt: null, refs: [] }; }
        h = h.replace(/\r?\n[ \t]+/g, ' ');
        const irt = (h.match(/^In-Reply-To:\s*(.*)$/mi) || [])[1];
        const refs = (h.match(/^References:\s*(.*)$/mi) || [])[1];
        return { irt: idsIn(irt)[0] || null, refs: idsIn(refs) };
      }

      function collect(coll, isSent) {
        // Fehler hier nicht verschlucken – sonst sähe ein Timeout wie „keine neuen Mails“ aus.
        const ids = coll.messageId();
        const dates = isSent ? coll.dateSent() : coll.dateReceived();
        // Älteste zuerst, damit Gesprächsverläufe in der richtigen Reihenfolge entstehen.
        const order = ids.map((_, i) => i).sort((a, b) => dates[a] - dates[b]);
        for (const i of order) {
          const mid = ids[i];
          if (!mid || known[mid]) continue;
          if (out.messages.length >= p.maxNew) { out.remaining++; continue; }
          known[mid] = true;
          try {
            const m = coll[i];
            // Der Posteingang kann sich seit der Massenabfrage verändert haben (neue/verschobene Mails).
            if (m.messageId() !== mid) { delete known[mid]; out.remaining++; continue; }
            const mb = m.mailbox();
            let account = '';
            try { account = mb.account().name(); } catch (e) {}
            const h = headers(m);
            let content = '';
            try { content = m.content() || ''; } catch (e) {}
            out.messages.push({
              id: m.id(),
              messageId: mid,
              account: account,
              mailbox: mb.name(),
              subject: m.subject() || '',
              sender: m.sender() || '',
              date: dates[i].toISOString(),
              read: m.readStatus(),
              inReplyTo: h.irt,
              references: h.refs,
              to: m.toRecipients.address(),
              cc: m.ccRecipients.address(),
              content: content.slice(0, p.contentLimit),
              isSent: isSent
            });
          } catch (e) {}
        }
      }

      // Beim Vollscan ohne Datumsfilter lesen: „whose“ über Tausende Mails läuft in einen AppleEvent-Timeout.
      const fullScan = since.getFullYear() < 1980;
      collect(fullScan ? Mail.inbox.messages : Mail.inbox.messages.whose({ dateReceived: { _greaterThan: since } }), false);
      if (p.includeSent) collect(Mail.sentMailbox.messages.whose({ dateSent: { _greaterThan: sentSince } }), true);
      return JSON.stringify(out);
    }
    """#

    private static let batchJS = #"""
    function run(argv) {
      ObjC.import('Foundation');
      const p = JSON.parse($.NSString.stringWithContentsOfFileEncodingError(argv[0], $.NSUTF8StringEncoding, null).js);
      const Mail = Application('Mail');
      const boxes = {};

      // Exchange führt Unterordner unter dem Elternordner, teils mit vollem Pfad als Name.
      function lookup(acct, name) {
        const mb = acct.mailboxes.byName(name);
        if (mb.exists()) return mb;
        const parts = name.split('/');
        if (parts.length > 1) {
          const parent = acct.mailboxes.byName(parts[0]);
          if (parent.exists()) {
            for (const cand of [name, parts.slice(1).join('/')]) {
              const c = parent.mailboxes.byName(cand);
              if (c.exists()) return c;
            }
          }
        }
        return null;
      }

      function ensureMailbox(acct, accountName, name) {
        const key = accountName + '\u0000' + name;
        if (boxes[key]) return boxes[key];
        let mb = lookup(acct, name);
        if (!mb) {
          try { acct.mailboxes.push(Mail.Mailbox({ name: name })); } catch (e) {}
          for (let i = 0; i < 20 && !mb; i++) { delay(0.25); mb = lookup(acct, name); }
          if (!mb) throw new Error('Ordner konnte nicht angelegt werden: ' + name);
        }
        boxes[key] = mb;
        return mb;
      }

      function find(acct, it) {
        const mb = lookup(acct, it.mailbox) || acct.mailboxes.byName(it.mailbox);
        if (it.id) {
          try { const m = mb.messages.byId(it.id); if (m.messageId() === it.messageId) return m; } catch (e) {}
        }
        const r = mb.messages.whose({ messageId: it.messageId });
        if (r.length > 0) return r[0];
        throw new Error('Nachricht nicht gefunden');
      }

      const results = [];
      for (const it of p.items) {
        const r = { messageId: it.messageId, ok: true };
        try {
          const acct = Mail.accounts.byName(it.account);
          const m = find(acct, it);
          if (it.flagIndex !== undefined) { m.flaggedStatus = true; m.flagIndex = it.flagIndex; }
          if (it.target) Mail.move(m, { to: ensureMailbox(acct, it.account, it.target) });
        } catch (e) { r.ok = false; r.error = String(e); }
        results.push(r);
      }
      return JSON.stringify(results);
    }
    """#

    private static let actionJS = #"""
    function run(argv) {
      ObjC.import('Foundation');
      const p = JSON.parse($.NSString.stringWithContentsOfFileEncodingError(argv[0], $.NSUTF8StringEncoding, null).js);
      const Mail = Application('Mail');
      const acct = Mail.accounts.byName(p.account);

      function find() {
        const mb = lookup(acct, p.mailbox) || acct.mailboxes.byName(p.mailbox);
        try { const m = mb.messages.byId(p.id); if (m.messageId() === p.messageId) return m; } catch (e) {}
        try { const r = mb.messages.whose({ messageId: p.messageId }); if (r.length > 0) return r[0]; } catch (e) {}
        const r2 = Mail.inbox.messages.whose({ messageId: p.messageId });
        if (r2.length > 0) return r2[0];
        throw new Error('Nachricht nicht gefunden: ' + p.messageId);
      }

      // Exchange führt Unterordner unter dem Elternordner, teils mit vollem Pfad als Name.
      function lookup(acct, name) {
        const mb = acct.mailboxes.byName(name);
        if (mb.exists()) return mb;
        const parts = name.split('/');
        if (parts.length > 1) {
          const parent = acct.mailboxes.byName(parts[0]);
          if (parent.exists()) {
            for (const cand of [name, parts.slice(1).join('/')]) {
              const c = parent.mailboxes.byName(cand);
              if (c.exists()) return c;
            }
          }
        }
        return null;
      }

      function ensureMailbox(name) {
        let mb = lookup(acct, name);
        if (mb) return mb;
        try { acct.mailboxes.push(Mail.Mailbox({ name: name })); } catch (e) {}
        for (let i = 0; i < 20 && !mb; i++) { delay(0.25); mb = lookup(acct, name); }
        if (!mb) throw new Error('Ordner konnte nicht angelegt werden: ' + name);
        return mb;
      }

      const m = find();
      const out = { ok: true };
      switch (p.action) {
        case 'move': {
          const target = ensureMailbox(p.target);
          Mail.move(m, { to: target });
          for (let i = 0; i < 12; i++) {
            try {
              const r = target.messages.whose({ messageId: p.messageId });
              if (r.length > 0) { out.newId = r[0].id(); break; }
            } catch (e) {}
            delay(0.25);
          }
          break;
        }
        case 'flag':
          m.flaggedStatus = true;
          m.flagIndex = p.flagIndex;
          break;
        case 'reply': {
          const r = Mail.reply(m, { openingWindow: true, replyToAll: !!p.replyAll });
          delay(0.5);
          let quoted = '';
          try { quoted = r.content() || ''; } catch (e) {}
          r.content = p.text + '\n\n' + quoted;
          Mail.activate();
          break;
        }
        default:
          throw new Error('Unbekannte Aktion: ' + p.action);
      }
      return JSON.stringify(out);
    }
    """#
}

enum ProcessRunner {
    struct Result {
        var status: Int32
        var stdout: String
        var stderr: String
    }

    static func run(executable: String, arguments: [String], stdin: String? = nil,
                    currentDirectory: URL? = nil, environment: [String: String]? = nil,
                    timeout: TimeInterval) async throws -> Result {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: executable)
                p.arguments = arguments
                if let currentDirectory { p.currentDirectoryURL = currentDirectory }
                if let environment { p.environment = environment }
                let out = Pipe(), err = Pipe(), inp = Pipe()
                p.standardOutput = out
                p.standardError = err
                p.standardInput = inp
                do { try p.run() } catch { cont.resume(throwing: error); return }

                if let stdin { inp.fileHandleForWriting.write(Data(stdin.utf8)) }
                try? inp.fileHandleForWriting.close()

                let timer = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)

                // Beide Pipes parallel leeren, sonst kann der Prozess bei vollem Puffer hängen.
                var errData = Data()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async {
                    errData = err.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                let outData = out.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                p.waitUntilExit()
                timer.cancel()

                cont.resume(returning: Result(
                    status: p.terminationStatus,
                    stdout: String(decoding: outData, as: UTF8.self),
                    stderr: String(decoding: errData, as: UTF8.self)
                ))
            }
        }
    }
}

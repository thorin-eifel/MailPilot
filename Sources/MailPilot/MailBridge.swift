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
    private let accountsScript: URL
    private let syncScript: URL
    private let composeScript: URL

    init() {
        fetchScript = Paths.scripts.appendingPathComponent("fetch.js")
        actionScript = Paths.scripts.appendingPathComponent("action.js")
        batchScript = Paths.scripts.appendingPathComponent("batch.js")
        try? Self.fetchJS.write(to: fetchScript, atomically: true, encoding: .utf8)
        try? Self.actionJS.write(to: actionScript, atomically: true, encoding: .utf8)
        try? Self.batchJS.write(to: batchScript, atomically: true, encoding: .utf8)
        accountsScript = Paths.scripts.appendingPathComponent("accounts.js")
        try? Self.accountsJS.write(to: accountsScript, atomically: true, encoding: .utf8)
        syncScript = Paths.scripts.appendingPathComponent("sync.js")
        try? Self.syncJS.write(to: syncScript, atomically: true, encoding: .utf8)
        composeScript = Paths.scripts.appendingPathComponent("compose.js")
        try? Self.composeJS.write(to: composeScript, atomically: true, encoding: .utf8)
    }

    func listAccounts() async throws -> [MailAccountInfo] {
        let out = try await run(accountsScript, [:])
        return try JSONDecoder().decode([MailAccountInfo].self, from: Data(out.utf8))
    }

    /// Liest neue Nachrichten aus den Posteingängen (und ggf. Gesendet) der angegebenen Konten.
    func fetch(since: Date, sentSince: Date? = nil, accounts: [String], known: [String], maxNew: Int, includeSent: Bool,
               contentLimit: Int = 6000) async throws -> FetchResult {
        let params: [String: Any] = [
            "accounts": accounts,
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
        /// Tatsächlicher Ordnername, wenn das Ziel der Posteingang war.
        var mailbox: String?
        /// Nur bei verschobenen Mails: im Zielordner wiedergefunden? `false` = nicht zurücklesbar.
        var verified: Bool?
    }

    /// Spezielles Verschiebeziel: der Posteingang des jeweiligen Kontos.
    static let inboxToken = "\u{1}INBOX"

    struct ComposeResult: Decodable {
        var subject: String
        var to: [String]
        var discarded: Bool
    }

    /// Öffnet ein neues Nachrichtenfenster mit Empfängern, Betreff und Text. Gesendet wird nichts.
    /// `visible: false` legt die Nachricht nur unsichtbar an und verwirft sie wieder (Tests).
    @discardableResult
    func compose(sender: String?, to: [String], subject: String, content: String, visible: Bool = true) async throws -> ComposeResult {
        var params: [String: Any] = ["to": to, "subject": subject, "content": content, "visible": visible]
        if let sender { params["sender"] = sender }
        let out = try await run(composeScript, params)
        return try JSONDecoder().decode(ComposeResult.self, from: Data(out.utf8))
    }

    struct FolderRef: Hashable {
        var account: String
        var path: String
    }

    private struct FolderListing: Decodable {
        var account: String
        var path: String
        var ids: [String]?
    }

    /// Message-IDs je Ordner (nur lesend). Nicht gefundene Ordner fehlen im Ergebnis.
    func folderContents(_ refs: [FolderRef]) async throws -> [FolderRef: [String]] {
        let params: [String: Any] = ["mode": "folders", "folders": refs.map { ["account": $0.account, "path": $0.path] }]
        let out = try await run(syncScript, params)
        var result: [FolderRef: [String]] = [:]
        for l in try JSONDecoder().decode([FolderListing].self, from: Data(out.utf8)) {
            if let ids = l.ids { result[FolderRef(account: l.account, path: l.path)] = ids }
        }
        return result
    }

    /// Welche der IDs liegen im Posteingang des Kontos? (nur lesend)
    func inboxMembership(account: String, ids: [String]) async throws -> (inbox: String, found: Set<String>) {
        struct Out: Decodable { var inbox: String; var found: [String] }
        let out = try await run(syncScript, ["mode": "inbox", "account": account, "ids": ids])
        let o = try JSONDecoder().decode(Out.self, from: Data(out.utf8))
        return (o.inbox, Set(o.found))
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

    func run(_ script: URL, _ params: [String: Any]) async throws -> String {
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

      // Nur die Posteingänge (und Gesendet-Ordner) der freigegebenen Konten lesen.
      const wanted = {};
      p.accounts.forEach(a => { wanted[a] = true; });
      const accountOf = mb => { try { return mb.account().name(); } catch (e) { return ''; } };
      // Beim Vollscan ohne Datumsfilter lesen: „whose“ über Tausende Mails läuft in einen AppleEvent-Timeout.
      const fullScan = since.getFullYear() < 1980;
      for (const mb of Mail.inbox.mailboxes()) {
        if (!wanted[accountOf(mb)]) continue;
        collect(fullScan ? mb.messages : mb.messages.whose({ dateReceived: { _greaterThan: since } }), false);
      }
      if (p.includeSent) {
        for (const mb of Mail.sentMailbox.mailboxes()) {
          if (!wanted[accountOf(mb)]) continue;
          collect(mb.messages.whose({ dateSent: { _greaterThan: sentSince } }), true);
        }
      }
      return JSON.stringify(out);
    }
    """#

    private static let composeJS = #"""
    function run(argv) {
      ObjC.import('Foundation');
      const p = JSON.parse($.NSString.stringWithContentsOfFileEncodingError(argv[0], $.NSUTF8StringEncoding, null).js);
      const Mail = Application('Mail');
      const msg = Mail.OutgoingMessage({ subject: p.subject, content: p.content, visible: p.visible });
      Mail.outgoingMessages.push(msg);
      if (p.sender) { try { msg.sender = p.sender; } catch (e) {} }
      for (const a of p.to) { msg.toRecipients.push(Mail.ToRecipient({ address: a })); }
      const out = { subject: msg.subject(), to: msg.toRecipients.address(), discarded: false };
      if (p.visible) {
        Mail.activate();
      } else {
        // Nur für Tests: unsichtbar angelegt und wieder verworfen, nichts wird gespeichert oder gesendet.
        try { Mail.delete(msg); out.discarded = true; } catch (e) {}
      }
      return JSON.stringify(out);
    }
    """#

    private static let syncJS = #"""
    function run(argv) {
      ObjC.import('Foundation');
      const p = JSON.parse($.NSString.stringWithContentsOfFileEncodingError(argv[0], $.NSUTF8StringEncoding, null).js);
      const Mail = Application('Mail');

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

      if (p.mode === 'folders') {
        const out = [];
        for (const f of p.folders) {
          const r = { account: f.account, path: f.path, ids: null };
          try {
            const mb = lookup(Mail.accounts.byName(f.account), f.path);
            if (mb) r.ids = mb.messages.messageId();
          } catch (e) {}
          out.push(r);
        }
        return JSON.stringify(out);
      }

      let inbox = null;
      for (const mb of Mail.inbox.mailboxes()) {
        try { if (mb.account().name() === p.account) inbox = mb; } catch (e) {}
      }
      if (!inbox) throw new Error('Posteingang nicht gefunden: ' + p.account);
      const want = {};
      p.ids.forEach(i => { want[i] = true; });
      return JSON.stringify({ inbox: inbox.name(), found: inbox.messages.messageId().filter(i => want[i]) });
    }
    """#

    private static let accountsJS = #"""
    function run(argv) {
      const Mail = Application('Mail');
      const counts = {};
      for (const mb of Mail.inbox.mailboxes()) {
        try { counts[mb.account().name()] = mb.messages.length; } catch (e) {}
      }
      const names = Mail.accounts.name();
      const emails = Mail.accounts.emailAddresses();
      const enabled = Mail.accounts.enabled();
      const out = [];
      names.forEach((n, i) => {
        if (enabled[i]) out.push({ name: n, emails: emails[i].map(String), inboxCount: counts[n] || 0 });
      });
      return JSON.stringify(out);
    }
    """#

    private static let batchJS = #"""
    function run(argv) {
      ObjC.import('Foundation');
      const p = JSON.parse($.NSString.stringWithContentsOfFileEncodingError(argv[0], $.NSUTF8StringEncoding, null).js);
      const Mail = Application('Mail');
      const boxes = {};
      const INBOX = '\u0001INBOX';

      function inboxOf(accountName) {
        for (const mb of Mail.inbox.mailboxes()) {
          try { if (mb.account().name() === accountName) return mb; } catch (e) {}
        }
        throw new Error('Posteingang nicht gefunden: ' + accountName);
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

      function ensureMailbox(acct, accountName, name) {
        const key = accountName + '\u0000' + name;
        if (boxes[key]) return boxes[key];
        if (name === INBOX) { boxes[key] = inboxOf(accountName); return boxes[key]; }
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
      const moved = [];
      for (const it of p.items) {
        const r = { messageId: it.messageId, ok: true };
        try {
          const acct = Mail.accounts.byName(it.account);
          const m = find(acct, it);
          if (it.flagIndex !== undefined) { m.flaggedStatus = true; m.flagIndex = it.flagIndex; }
          if (it.target) {
            const dest = ensureMailbox(acct, it.account, it.target);
            Mail.move(m, { to: dest });
            if (it.target === INBOX) r.mailbox = dest.name();
            moved.push({ r: r, dest: dest, id: it.messageId, key: it.account + '\u0000' + it.target });
          }
        } catch (e) { r.ok = false; r.error = String(e); }
        results.push(r);
      }

      // Verifikation: Liegt jede verschobene Mail jetzt wirklich im Zielordner? IMAP/Exchange brauchen dafür etwas Zeit.
      // Lässt sich eine Mail dort nicht zurücklesen, bleibt `verified` false.
      const byKey = {};
      moved.forEach(x => { (byKey[x.key] = byKey[x.key] || []).push(x); });
      for (const key of Object.keys(byKey)) {
        const group = byKey[key];
        let pending = group;
        for (let attempt = 0; attempt < 8 && pending.length > 0; attempt++) {
          if (attempt > 0) delay(0.75);
          let have = [];
          try { have = group[0].dest.messages.messageId(); } catch (e) {}
          const seen = {};
          have.forEach(i => { seen[i] = true; });
          pending = pending.filter(x => !seen[x.id]);
        }
        group.forEach(x => { x.r.verified = pending.indexOf(x) < 0; });
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

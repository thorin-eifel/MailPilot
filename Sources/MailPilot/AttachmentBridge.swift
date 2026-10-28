import Foundation

/// Anhänge einer Mail lesen und (PDFs) in einen Ordner speichern.
extension MailBridge {
    struct AttachmentInfo: Decodable {
        var name: String
        var mimeType: String?
        var size: Int?
        var downloaded: Bool?
        var saved: String?
        var error: String?
    }

    private static let attachScript: URL = {
        let url = Paths.scripts.appendingPathComponent("attachments.js")
        try? attachJS.write(to: url, atomically: true, encoding: .utf8)
        return url
    }()

    /// Listet die Anhänge; mit `saveTo` werden PDFs (bis 12 MB) dort abgelegt.
    func attachments(account: String, mailbox: String, id: Int, messageId: String, saveTo dir: URL?) async throws -> [AttachmentInfo] {
        var params: [String: Any] = ["account": account, "mailbox": mailbox, "id": id, "messageId": messageId, "maxBytes": 12_000_000]
        if let dir { params["save"] = true; params["dir"] = dir.path }
        let out = try await run(Self.attachScript, params)
        return try JSONDecoder().decode([AttachmentInfo].self, from: Data(out.utf8))
    }

    private static let attachJS = #"""
    function run(argv) {
      ObjC.import('Foundation');
      const p = JSON.parse($.NSString.stringWithContentsOfFileEncodingError(argv[0], $.NSUTF8StringEncoding, null).js);
      const Mail = Application('Mail');
      const acct = Mail.accounts.byName(p.account);

      // Exchange führt Unterordner unter dem Elternordner, teils mit vollem Pfad als Name.
      function lookup(name) {
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

      const mb = lookup(p.mailbox) || acct.mailboxes.byName(p.mailbox);
      let m = null;
      if (p.id) { try { const x = mb.messages.byId(p.id); if (x.messageId() === p.messageId) m = x; } catch (e) {} }
      if (!m) { try { const r = mb.messages.whose({ messageId: p.messageId }); if (r.length > 0) m = r[0]; } catch (e) {} }
      if (!m) throw new Error('Nachricht nicht gefunden');

      const out = [];
      for (const a of m.mailAttachments()) {
        const item = { name: '', mimeType: '', size: 0, downloaded: true, saved: null };
        try { item.name = a.name(); } catch (e) {}
        try { item.mimeType = a.mimeType(); } catch (e) {}
        try { item.size = a.fileSize(); } catch (e) {}
        try { item.downloaded = a.downloaded(); } catch (e) {}
        const isPdf = /pdf/i.test(item.mimeType || '') || /\.pdf$/i.test(item.name || '');
        if (p.save && isPdf && item.size < p.maxBytes) {
          try {
            const path = p.dir + '/' + out.length + '-' + (item.name || 'anhang.pdf').replace(/[\/:]/g, '_');
            Mail.save(a, { in: Path(path) });
            item.saved = path;
          } catch (e) { item.error = String(e); }
        }
        out.push(item);
      }
      return JSON.stringify(out);
    }
    """#
}

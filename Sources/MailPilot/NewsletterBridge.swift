import Foundation

/// Lesestatus und Abmelde-Header direkt aus Apple Mail (nur lesend).
extension MailBridge {
    struct ReadListing: Decodable {
        var account: String
        var mailbox: String
        var ids: [String]?
        var read: [Bool]?
    }

    struct HeaderInfo: Decodable {
        var unsub: String?
        var post: String?
    }

    private static let readScript: URL = {
        let url = Paths.scripts.appendingPathComponent("readstate.js")
        try? readJS.write(to: url, atomically: true, encoding: .utf8)
        return url
    }()

    private static let headersScript: URL = {
        let url = Paths.scripts.appendingPathComponent("headers.js")
        try? headersJS.write(to: url, atomically: true, encoding: .utf8)
        return url
    }()

    /// Lesestatus aller Mails der angegebenen Ordner: Message-ID → gelesen.
    func readStates(_ refs: [FolderRef]) async throws -> [FolderRef: [String: Bool]] {
        let out = try await run(Self.readScript, ["refs": refs.map { ["account": $0.account, "mailbox": $0.path] }])
        var result: [FolderRef: [String: Bool]] = [:]
        for l in try JSONDecoder().decode([ReadListing].self, from: Data(out.utf8)) {
            guard let ids = l.ids, let read = l.read, ids.count == read.count else { continue }
            result[FolderRef(account: l.account, path: l.mailbox)] = Dictionary(zip(ids, read), uniquingKeysWith: { a, _ in a })
        }
        return result
    }

    /// Liest `List-Unsubscribe` einer einzelnen Mail nach.
    func unsubscribeHeader(account: String, mailbox: String, id: Int, messageId: String) async throws -> HeaderInfo {
        let out = try await run(Self.headersScript, ["account": account, "mailbox": mailbox, "id": id, "messageId": messageId])
        return try JSONDecoder().decode(HeaderInfo.self, from: Data(out.utf8))
    }

    private static let lookupJS = #"""
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
    """#

    private static let readJS = #"""
    function run(argv) {
      ObjC.import('Foundation');
      const p = JSON.parse($.NSString.stringWithContentsOfFileEncodingError(argv[0], $.NSUTF8StringEncoding, null).js);
      const Mail = Application('Mail');
    """# + lookupJS + #"""

      const out = [];
      for (const ref of p.refs) {
        const r = { account: ref.account, mailbox: ref.mailbox, ids: null, read: null };
        try {
          const acct = Mail.accounts.byName(ref.account);
          const mb = lookup(acct, ref.mailbox) || acct.mailboxes.byName(ref.mailbox);
          if (mb.exists()) { r.ids = mb.messages.messageId(); r.read = mb.messages.readStatus(); }
        } catch (e) {}
        out.push(r);
      }
      return JSON.stringify(out);
    }
    """#

    private static let headersJS = #"""
    function run(argv) {
      ObjC.import('Foundation');
      const p = JSON.parse($.NSString.stringWithContentsOfFileEncodingError(argv[0], $.NSUTF8StringEncoding, null).js);
      const Mail = Application('Mail');
      const acct = Mail.accounts.byName(p.account);
    """# + lookupJS + #"""

      const mb = lookup(acct, p.mailbox) || acct.mailboxes.byName(p.mailbox);
      let m = null;
      if (p.id) { try { const x = mb.messages.byId(p.id); if (x.messageId() === p.messageId) m = x; } catch (e) {} }
      if (!m) { try { const r = mb.messages.whose({ messageId: p.messageId }); if (r.length > 0) m = r[0]; } catch (e) {} }
      if (!m) throw new Error('Nachricht nicht gefunden');
      const h = (m.allHeaders() || '').replace(/\r?\n[ \t]+/g, ' ');
      return JSON.stringify({ unsub: (h.match(/^List-Unsubscribe:\s*(.*)$/mi) || [])[1] || null,
                              post: (h.match(/^List-Unsubscribe-Post:\s*(.*)$/mi) || [])[1] || null });
    }
    """#
}

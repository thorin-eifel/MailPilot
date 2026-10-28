import Foundation
import Network

/// Tests für den eigenen Mail-Client (`--selftest-client`): MIME, Protokoll, Speicher und ein Durchlauf gegen einen Testserver im Prozess.
enum ClientSelfTest {
    nonisolated(unsafe) static var failures = 0

    static func check(_ ok: Bool, _ name: String) {
        print((ok ? "PASS  " : "FAIL  ") + name)
        if !ok { failures += 1 }
    }

    static func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }

    // MARK: Beispielnachrichten

    static let plainMessage = [
        "From: =?UTF-8?Q?J=C3=BCrgen_M=C3=BCller?= <juergen@example.org>",
        "To: anna@example.org, \"Doe, John\" <john@example.org>",
        "Subject: =?UTF-8?B?\(Data("Rückfrage über Rechnung".utf8).base64EncodedString())?=",
        "Date: Sun, 01 Nov 2026 10:00:00 +0100",
        "Message-ID: <m101@example.org>",
        "Content-Type: text/plain; charset=utf-8",
        "Content-Transfer-Encoding: quoted-printable",
        "", "Gr=C3=BC=C3=9Fe=", " von hier.", "A9 OK fake line", "",
    ].joined(separator: "\r\n")

    static let richMessage = [
        "From: Shop <shop@example.org>", "To: anna@example.org", "Subject: Ihre Rechnung", "Date: 2 Nov 2026 08:15 +0000 (UTC)",
        "Message-ID: <m102@example.org>", "References: <m101@example.org> <m100@example.org>", "In-Reply-To: <m101@example.org>",
        "Content-Type: multipart/mixed; boundary=\"MIX\"", "",
        "--MIX", "Content-Type: multipart/alternative; boundary=\"ALT\"", "",
        "--ALT", "Content-Type: text/plain; charset=iso-8859-1", "Content-Transfer-Encoding: quoted-printable", "", "Gr=FC=DFe aus dem Shop", "",
        "--ALT", "Content-Type: text/html; charset=utf-8", "", "<p>Hallo <b>Welt</b> &amp; Co.</p><img src=\"cid:logo1\">", "",
        "--ALT--", "",
        "--MIX", "Content-Type: image/png", "Content-ID: <logo1>", "Content-Disposition: inline", "Content-Transfer-Encoding: base64", "",
        Data("PNGDATA".utf8).base64EncodedString(), "",
        "--MIX", "Content-Type: application/pdf; name=\"r.pdf\"", "Content-Disposition: attachment; filename*=utf-8''R%C3%A4chnung.pdf",
        "Content-Transfer-Encoding: base64", "", Data("PDF-DATA".utf8).base64EncodedString(), "",
        "--MIX--", "",
    ].joined(separator: "\r\n")

    // MARK: Lauf

    static func run() {
        mimeTests()
        codecTests()
        composeTests()
        let sema = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                try storeTests()
                try await serverTests()
                try await smtpTests()
            } catch {
                check(false, "Tests liefen ohne Fehler: \(error)")
            }
            sema.signal()
        }
        sema.wait()
        print(failures == 0 ? "\nAlle Tests bestanden." : "\n\(failures) Test(s) fehlgeschlagen.")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: MIME

    static func mimeTests() {
        check(MIME.decodeWords("=?UTF-8?Q?M=C3=BCller?= <a@b.de>") == "Müller <a@b.de>", "MIME: Q-kodiertes Wort")
        check(MIME.decodeWords("=?UTF-8?B?" + Data("Grüße".utf8).base64EncodedString() + "?=") == "Grüße", "MIME: B-kodiertes Wort")
        check(MIME.decodeWords("=?utf-8?Q?Hallo?= =?utf-8?Q?_Welt?=") == "Hallo Welt", "MIME: Leerraum zwischen kodierten Wörtern entfällt")
        check(MIME.decodeWords("=?iso-8859-1?Q?Gr=FC=DFe?=") == "Grüße", "MIME: andere Zeichensätze")
        check(MIME.decodeWords("Ohne Kodierung") == "Ohne Kodierung", "MIME: unkodierter Text bleibt")

        let h = MIME.parseHeaders(bytes("Subject: Ein langer\r\n Betreff\r\n\tmit Fortsetzung\r\nX-Test: 1\r\n"))
        check(h.count == 2 && h[0].value == "Ein langer Betreff mit Fortsetzung", "MIME: gefaltete Kopfzeilen")

        let p1 = MIME.parseParams("attachment; filename*=utf-8''M%C3%BCller.pdf")
        check(p1.main == "attachment" && p1.params["filename"] == "Müller.pdf", "MIME: Parameter nach RFC 2231")
        let p2 = MIME.parseParams("attachment; filename*0=\"lang\"; filename*1=\"er-name.txt\"")
        check(p2.params["filename"] == "langer-name.txt", "MIME: fortgesetzte Parameter")
        let p3 = MIME.parseParams("text/plain; charset=\"utf-8\"; x=\"a;b\"")
        check(p3.main == "text/plain" && p3.params["charset"] == "utf-8" && p3.params["x"] == "a;b", "MIME: Parameter in Anführungszeichen")

        check(String(decoding: MIME.quotedPrintable(bytes("a=3Db=\r\nc")), as: UTF8.self) == "a=bc", "MIME: Quoted-Printable mit weichem Umbruch")
        check(MIME.splitHeadBody(bytes("A: 1\r\n\r\nBody")).body == bytes("Body") && MIME.splitHeadBody(bytes("A: 1\n\nBody")).body == bytes("Body"), "MIME: Kopf und Rumpf trennen (CRLF und LF)")

        let plain = MIME.extract(MIME.parse(bytes(plainMessage)))
        check(plain.text == "Grüße von hier.\r\nA9 OK fake line" || plain.text.hasPrefix("Grüße von hier."), "MIME: einfache Nachricht (UTF-8, quoted-printable)")

        let rich = MIME.extract(MIME.parse(bytes(richMessage)))
        check(rich.text == "Grüße aus dem Shop" && rich.html?.contains("<b>Welt</b>") == true, "MIME: multipart/alternative – Text (Latin-1) und HTML")
        check(rich.attachments.count == 2, "MIME: zwei Teile außerhalb des Textes (\(rich.attachments.count))")
        let pdf = rich.attachments.first { $0.mime == "application/pdf" }
        check(pdf?.name == "Rächnung.pdf" && pdf.map { String(decoding: $0.data, as: UTF8.self) } == "PDF-DATA", "MIME: Anhang mit Namen nach RFC 2231 und Inhalt")
        let img = rich.attachments.first { $0.mime == "image/png" }
        check(img?.isInline == true && img?.contentID == "<logo1>", "MIME: eingebettetes Bild mit Content-ID")
        check(rich.htmlWithInlineImages()?.contains("data:image/png;base64,") == true && rich.htmlWithInlineImages()?.contains("cid:") == false, "MIME: cid-Bilder werden eingebettet")
        check(rich.preview == "Grüße aus dem Shop", "MIME: Vorschau")

        let html = MIME.stripHTML("<style>x{}</style><p>Hallo &amp; <b>Welt</b></p><p>Zweite&nbsp;Zeile</p>")
        check(html.contains("Hallo & Welt") && html.contains("Zweite Zeile") && !html.contains("<"), "MIME: HTML zu Text")

        check(MIME.splitAddresses("\"Doe, John\" <j@x.de>, anna@x.de, B <b@x.de>") == ["\"Doe, John\" <j@x.de>", "anna@x.de", "B <b@x.de>"], "MIME: Adressliste mit Komma im Namen")

        let info = MIME.headerInfo(MIME.splitHeadBody(bytes(plainMessage)).head)
        check(info.subject == "Rückfrage über Rechnung" && info.fromName == "Jürgen Müller" && info.fromEmail == "juergen@example.org"
              && info.messageId == "m101@example.org" && info.to.count == 2, "MIME: Kopfdaten (Betreff, Absender, Empfänger, ID)")
        let info2 = MIME.headerInfo(MIME.splitHeadBody(bytes(richMessage)).head)
        check(info2.references == ["m101@example.org", "m100@example.org"] && info2.inReplyTo == "m101@example.org", "MIME: References und In-Reply-To")

        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!
        let d1 = MIME.parseDate("Sun, 01 Nov 2026 10:00:00 +0100")
        check(d1 == c.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 9)), "MIME: Datum mit Zeitzone")
        check(MIME.parseDate("2 Nov 2026 08:15 +0000 (UTC)") == c.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 8, minute: 15)), "MIME: Datum ohne Wochentag, mit Kommentar")
        check(MIME.parseDate("kein Datum") == nil, "MIME: ungültiges Datum")
    }

    // MARK: Protokoll

    static func codecTests() {
        var p = IMAPParser(bytes("* 5 FETCH (UID 7 FLAGS (\\Seen \\Flagged) BODY[HEADER] {7}\r\nA: 1\r\nB INTERNALDATE \"01-Nov-2026 10:00:00 +0100\" X NIL)\r\n"))
        let t = (try? p.parseAll()) ?? []
        check(t.count == 4 && t[2].text == "FETCH", "IMAP: Antwort zerlegen")
        let items = t.count > 3 ? t[3].items : []
        check(items.count == 10 && items[3].items.count == 2 && items[3].items[1].text == "\\Flagged", "IMAP: verschachtelte Liste (Flags)")
        check(items[5].bytes == bytes("A: 1\r\nB"), "IMAP: Literal mit Zeilenumbruch bleibt ganz")
        check(items[7].text == "01-Nov-2026 10:00:00 +0100" && items[9] == .null, "IMAP: Quoted-String und NIL")
        var q = IMAPParser(bytes("\"a\\\"b\\\\c\""))
        check((try? q.parseAll())?.first?.text == "a\"b\\c", "IMAP: Maskierung in Quoted-Strings")

        let r = IMAPResponse(raw: bytes("* OK [UIDVALIDITY 3857529045] UIDs valid\r\n"))
        check(r.code("UIDVALIDITY") == 3857529045, "IMAP: Statuscode UIDVALIDITY")
        check(IMAPResponse(raw: bytes("* 23 EXISTS\r\n")).count("EXISTS") == 23 && IMAPResponse(raw: bytes("* SEARCH 4 9 12\r\n")).keyword == "SEARCH", "IMAP: EXISTS und SEARCH")

        check(IMAPCodec.decodeFolderName("Entw&APw-rfe") == "Entwürfe" && IMAPCodec.decodeFolderName("A&-B") == "A&B", "IMAP: Ordnername (modifiziertes UTF-7) lesen")
        for name in ["Entwürfe", "Gesendet Objekte", "A&B", "日本語/Ordner", "Plain"] {
            check(IMAPCodec.decodeFolderName(IMAPCodec.encodeFolderName(name)) == name, "IMAP: Ordnername Hin und Zurück (\(name))")
        }
        check(IMAPCodec.encodeFolderName("Entwürfe") == "Entw&APw-rfe", "IMAP: Ordnername schreiben")
        check(IMAPCodec.uidSet([1, 2, 3, 7, 9, 10, 3]) == "1:3,7,9:10" && IMAPCodec.uidSet([]) == "", "IMAP: UID-Mengen")
        check(IMAPCodec.quote("a\"b\\c") == "\"a\\\"b\\\\c\"", "IMAP: Befehlsargumente maskieren")
        check(IMAPCodec.parseInternalDate("01-Nov-2026 10:00:00 +0100") != nil, "IMAP: Zustelldatum")
    }

    // MARK: Speicher

    static func storeTests() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mp-client-\(UUID()).sqlite")
        defer { for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: tmp.path + s) } }
        let store = try Store(path: tmp)
        try store.saveClientFolders(account: "A", folders: [
            IMAPFolderInfo(path: "Sent Messages", name: "Sent Messages", delimiter: "/", special: "sent", selectable: true),
            IMAPFolderInfo(path: "INBOX", name: "INBOX", delimiter: "/", special: "inbox", selectable: true),
            IMAPFolderInfo(path: "Alt", name: "Alt", delimiter: "/", special: nil, selectable: true),
        ])
        check(store.clientFolders(account: "A").map(\.path) == ["INBOX", "Sent Messages", "Alt"], "Speicher: Ordner nach Art sortiert")
        let fetched = IMAPFetched(uid: 5, flags: ["\\Flagged"], internalDate: Date(), size: 99, header: bytes(String(plainMessage.prefix(while: { _ in true }))))
        try store.saveClientHeader(account: "A", folder: "INBOX", fetched: fetched)
        try store.saveClientHeader(account: "A", folder: "INBOX", fetched: IMAPFetched(uid: 6, flags: ["\\Seen"], internalDate: Date(), size: 1, header: bytes(richMessage)))
        let list = store.clientMessages(account: "A", folder: "INBOX")
        check(list.count == 2 && list.contains { $0.subject == "Rückfrage über Rechnung" && $0.recipients.count == 2 && $0.recipients[1].contains("Doe, John") },
              "Speicher: Kopfdaten gespeichert (Empfänger mit Komma bleiben heil)")
        check(store.clientFolders(account: "A").first?.unread == 1, "Speicher: Zahl ungelesener Nachrichten")
        try store.saveClientBody(account: "A", folder: "INBOX", uid: 5, raw: Data([0, 1, 2, 13, 10, 255]), preview: "Vorschau")
        check(store.clientBody(account: "A", folder: "INBOX", uid: 5) == Data([0, 1, 2, 13, 10, 255]) && store.clientBody(account: "A", folder: "INBOX", uid: 6) == nil,
              "Speicher: Rohnachricht als Blob (auch mit Nullbytes)")
        try store.setClientFlags(account: "A", folder: "INBOX", uid: 5, flags: ["\\Seen"])
        check(store.clientFolders(account: "A").first?.unread == 0, "Speicher: Flags ändern")
        try store.deleteClientMessages(account: "A", folder: "INBOX", uids: [5])
        check(store.clientUIDs(account: "A", folder: "INBOX") == [6], "Speicher: Nachricht entfernen")
        try store.saveClientFolders(account: "A", folders: [IMAPFolderInfo(path: "INBOX", name: "INBOX", delimiter: "/", special: "inbox", selectable: true)])
        check(store.clientFolders(account: "A").count == 1, "Speicher: auf dem Server gelöschte Ordner verschwinden")
        store.removeClientAccount("A")
        check(store.clientMessages(account: "A", folder: "INBOX").isEmpty, "Speicher: Konto entfernen")
    }

    // MARK: Ende zu Ende gegen den Testserver

    static func serverTests() async throws {
        let server = FakeIMAPServer()
        server.messages = [101: .init(flags: [], raw: plainMessage), 102: .init(flags: ["\\Seen"], raw: richMessage),
                           103: .init(flags: [], raw: plainMessage.replacingOccurrences(of: "m101", with: "m103"))]
        try await server.start()
        let client = IMAPClient(.init(host: "127.0.0.1", port: server.port, tls: false))
        try await client.connect()
        let caps = await client.capabilities
        check(caps.contains("IMAP4REV1"), "Server: Fähigkeiten gelesen")

        do { try await client.login(user: "anna", password: "falsch"); check(false, "Server: falsches Passwort wird abgelehnt") }
        catch IMAPError.auth { check(true, "Server: falsches Passwort wird abgelehnt") }
        try await client.login(user: "anna", password: "secret")

        let folders = try await client.listFolders()
        check(folders.count == 4 && folders.contains { $0.path == "Entwürfe" && $0.special == "drafts" }
              && folders.contains { $0.path == "Sent Messages" && $0.special == "sent" } && folders.contains { $0.path == "INBOX" && $0.special == "inbox" }
              && folders.contains { $0.path == "Parent" && !$0.selectable }, "Server: Ordnerliste mit Sonderordnern und Umlauten")

        let state = try await client.folderState("INBOX")
        check(state.status.exists == 3 && state.status.uidValidity == 42 && state.status.uidNext == 104 && state.uids == [101, 102, 103], "Server: Ordner öffnen, UIDs lesen")
        let heads = try await client.fetchHeaders("INBOX", uids: [101, 102])
        check(heads.count == 2 && heads[0].header != nil && heads[1].flags == ["\\Seen"] && heads[0].size > 0 && heads[0].internalDate != nil, "Server: Kopfzeilen laden")
        let body = try await client.fetchBody("INBOX", uid: 101)
        check(String(decoding: body, as: UTF8.self) == plainMessage, "Server: Nachricht mit Literal unverändert geladen (auch Zeilen wie „A9 OK“)")
        try await client.setFlag("INBOX", uid: 101, flag: "\\Seen", on: true)
        check(server.log.contains { $0.hasSuffix("UID STORE 101 +FLAGS.SILENT (\\Seen)") }, "Server: Flag setzen")

        // Abgleich in den Speicher
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mp-client-sync-\(UUID()).sqlite")
        defer { for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: tmp.path + s) } }
        let store = try Store(path: tmp)
        try await ClientSync.syncFolders(store: store, client: client, account: "A")
        check(store.clientFolders(account: "A").count == 4, "Abgleich: Ordner gespeichert")
        let n1 = try await ClientSync.syncFolder(store: store, client: client, account: "A", path: "INBOX")
        check(n1 == 3 && Set(store.clientUIDs(account: "A", folder: "INBOX")) == [101, 102, 103], "Abgleich: erster Lauf lädt alle")

        // Serverseitige Änderungen: 103 gelöscht, 104 neu, 101 gelesen
        server.mutate { s in
            s.messages[103] = nil
            s.messages[104] = .init(flags: [], raw: richMessage.replacingOccurrences(of: "m102", with: "m104"))
            s.messages[101]?.flags = ["\\Flagged"]
        }
        let n2 = try await ClientSync.syncFolder(store: store, client: client, account: "A", path: "INBOX")
        let msgs = store.clientMessages(account: "A", folder: "INBOX")
        check(n2 == 1 && Set(msgs.map(\.uid)) == [101, 102, 104], "Abgleich: neue Nachricht geladen, gelöschte entfernt")
        check(msgs.first { $0.uid == 101 }?.isFlagged == true, "Abgleich: geänderte Flags übernommen")

        // Beim ersten Abgleich nur die neuesten laden
        let n3 = try await ClientSync.syncFolder(store: store, client: client, account: "B", path: "INBOX", initialLimit: 2)
        check(n3 == 2 && Set(store.clientUIDs(account: "B", folder: "INBOX")) == [102, 104], "Abgleich: erster Lauf begrenzt auf die neuesten")

        // Lesen mit Zwischenspeicher
        let raw1 = try await ClientSync.loadBody(store: store, client: client, account: "A", path: "INBOX", uid: 102)
        check(String(decoding: raw1, as: UTF8.self) == richMessage && store.clientMessages(account: "A", folder: "INBOX").first { $0.uid == 102 }?.preview == "Grüße aus dem Shop",
              "Abgleich: Nachricht geladen und zwischengespeichert, Vorschau gesetzt")
        let before = server.log.count
        _ = try await ClientSync.loadBody(store: store, client: nil, account: "A", path: "INBOX", uid: 102)
        check(server.log.count == before, "Abgleich: zweites Lesen kommt aus dem Speicher")

        // UIDVALIDITY geändert → Ordner neu aufbauen
        server.mutate { s in
            s.uidValidity = 43
            s.messages = [201: .init(flags: [], raw: plainMessage)]
        }
        _ = try await ClientSync.syncFolder(store: store, client: client, account: "A", path: "INBOX")
        check(store.clientUIDs(account: "A", folder: "INBOX") == [201], "Abgleich: geänderte UIDVALIDITY baut den Ordner neu auf")

        // Ablegen (Gesendet, Entwürfe) und Löschen
        let draftData = Data(plainMessage.utf8)
        let newUID = try await client.append("Entwürfe", flags: ["\\Draft", "\\Seen"], message: draftData)
        check(newUID != nil && server.appended.count == 1 && server.appended[0].folder == "Entwürfe" && server.appended[0].flags == ["\\Draft", "\\Seen"]
              && server.appended[0].raw == plainMessage, "Server: Nachricht per APPEND abgelegt (Ordner mit Umlaut, Flags, Inhalt unverändert)")
        check(newUID.map { server.messages[$0] != nil } == true, "Server: APPENDUID liefert die neue UID")
        if let uid = newUID {
            try await client.deleteMessage("Entwürfe", uid: uid)
            check(server.messages[uid] == nil, "Server: Nachricht gelöscht (als gelöscht markiert und expungt)")
        }

        // Server weg → verständlicher Fehler
        server.stop()
        var failed = false
        do { _ = try await client.folderState("INBOX") } catch { failed = true }
        check(failed, "Server: Verbindungsabbruch wird als Fehler gemeldet")
        await client.close()
    }

    // MARK: Nachricht bauen und Antworten

    static func parsedBuilt(_ b: MessageBuilder.Built) -> (part: MIMEPart, parsed: ParsedMessage, info: MailHeaderInfo) {
        let raw = [UInt8](b.data)
        let part = MIME.parse(raw)
        return (part, MIME.extract(part), MIME.headerInfo(MIME.splitHeadBody(raw).head))
    }

    static func composeTests() {
        var m = OutgoingMessage(fromName: "Anna \"Ä\" Beispiel", fromEmail: "anna@icloud.com", to: ["Jürgen Müller <juergen@example.org>", "\"Doe, John\" <john@example.org>"],
                                cc: ["cc@example.org"], bcc: ["geheim@example.org"], subject: "Rückfrage zur Rechnung – bitte kurz antworten, das ist ein ziemlich langer Betreff",
                                body: "Hallo Jürgen,\n\n.einzelner Punkt am Anfang\nGrüße = viel\u{20}\nEnde")
        m.inReplyTo = "orig@example.org"
        m.references = ["a@example.org", "orig@example.org"]
        do {
            let b = try MessageBuilder.build(m)
            let r = parsedBuilt(b)
            check(r.info.subject == m.subject, "Senden: Betreff mit Umlauten und Länge (RFC 2047 in mehreren Wörtern)")
            check(r.info.fromEmail == "anna@icloud.com" && r.info.fromName == "Anna \"Ä\" Beispiel", "Senden: Absender mit Anführungszeichen und Umlaut")
            check(r.info.to.count == 2 && r.info.to[0].contains("juergen@example.org") && r.info.to[1].contains("Doe, John"), "Senden: Empfängerliste (Komma im Namen)")
            check(b.recipients == ["juergen@example.org", "john@example.org", "cc@example.org", "geheim@example.org"], "Senden: Umschlag enthält To, Cc und Bcc")
            check(!String(decoding: b.data, as: UTF8.self).lowercased().contains("geheim@example.org"), "Senden: Bcc steht nicht in den Kopfzeilen")
            check(r.info.inReplyTo == "orig@example.org" && r.info.references == ["a@example.org", "orig@example.org"], "Senden: In-Reply-To und References")
            check(r.parsed.text == "Hallo Jürgen,\r\n\r\n.einzelner Punkt am Anfang\r\nGrüße = viel \r\nEnde", "Senden: Text unverändert (UTF-8, „=“, Leerzeichen am Zeilenende)")
            check(b.messageID.hasSuffix("@icloud.com") && r.info.messageId == b.messageID && r.part.header("MIME-Version") == "1.0", "Senden: Message-ID und MIME-Version")
        } catch {
            check(false, "Senden: Nachricht bauen: \(error)")
        }

        // Kopfzeilen-Einschleusung
        var evil = OutgoingMessage(fromEmail: "anna@icloud.com", to: ["a@x.de"], subject: "Hallo\r\nBcc: evil@x.de", body: "x")
        evil.fromName = "Anna\r\nX-Evil: 1"
        if let b = try? MessageBuilder.build(evil) {
            let names = MIME.parseHeaders(MIME.splitHeadBody([UInt8](b.data)).head).map { $0.name.lowercased() }
            check(!names.contains("bcc") && !names.contains("x-evil"), "Senden: Zeilenumbrüche in Betreff und Name schleusen keine Kopfzeilen ein")
        } else { check(false, "Senden: Einschleusung wird neutralisiert statt abgelehnt") }
        check((try? MessageBuilder.build(OutgoingMessage(fromEmail: "a@x.de", to: ["kein-at"], subject: "", body: ""))) == nil, "Senden: ungültige Adresse wird abgelehnt")
        check((try? MessageBuilder.build(OutgoingMessage(fromEmail: "a@x.de", to: ["a@x.de, b@x.de"], subject: "", body: "")))?.recipients.count == 2, "Senden: Komma getrennte Empfänger in einem Feld")
        check((try? MessageBuilder.build(OutgoingMessage(fromEmail: "a@x.de", subject: "", body: ""))) == nil, "Senden: ohne Empfänger keine Nachricht")
        check((try? MessageBuilder.build(OutgoingMessage(fromEmail: "a@x.de", subject: "Entwurf", body: ""), requireRecipients: false)) != nil, "Senden: Entwurf ohne Empfänger möglich")

        // Quoted-Printable
        let longLine = String(repeating: "Grüße aus Trier, äöüß=! ", count: 20) + "Ende \n\nzweite Zeile  "
        let qp = MessageBuilder.quotedPrintable(longLine)
        let back = String(decoding: MIME.quotedPrintable(Array(qp.utf8)), as: UTF8.self)
        check(qp.components(separatedBy: "\r\n").allSatisfy { $0.utf8.count <= 76 }, "Senden: Quoted-Printable bricht Zeilen bei 76 Zeichen")
        check(back == longLine.replacingOccurrences(of: "\n", with: "\r\n"), "Senden: Quoted-Printable Hin und Zurück")

        // Anhänge
        let payload = Data((0..<2000).map { UInt8($0 % 251) })
        var withFile = OutgoingMessage(fromEmail: "anna@icloud.com", to: ["a@x.de"], subject: "Mit Anhang", body: "Siehe Anhang.")
        withFile.attachments = [OutgoingAttachment(name: "Räch nung \"1\".pdf", mime: "application/pdf", data: payload),
                                OutgoingAttachment(name: "notiz.txt", mime: "text/plain", data: Data("Hallo".utf8))]
        if let b = try? MessageBuilder.build(withFile) {
            let r = parsedBuilt(b)
            check(r.parsed.text == "Siehe Anhang." && r.parsed.attachments.count == 2, "Senden: Text und zwei Anhänge")
            check(r.parsed.attachments.first?.name == "Räch nung \"1\".pdf" && r.parsed.attachments.first?.data == payload, "Senden: Anhang mit Umlaut im Namen, Inhalt bleibt bitgleich")
            check(r.parsed.attachments.last?.data == Data("Hallo".utf8) && r.parsed.attachments.last?.mime == "text/plain", "Senden: Textanhang bleibt Anhang")
        } else { check(false, "Senden: Nachricht mit Anhang bauen") }

        // Punkte am Zeilenanfang
        let stuffed = String(decoding: SMTPSession.dotStuffed(Data("a\r\n.b\r\n.\r\nc".utf8)), as: UTF8.self)
        check(stuffed == "a\r\n..b\r\n..\r\nc\r\n.\r\n", "SMTP: Zeilen mit Punkt am Anfang werden verdoppelt, Abschluss „.“")

        // Antworten und Weiterleiten
        check(ComposeDraft.prefixed("Hallo", with: "Re:") == "Re: Hallo" && ComposeDraft.prefixed("AW: Hallo", with: "Re:") == "AW: Hallo" && ComposeDraft.prefixed("Re: x", with: "Re:") == "Re: x",
              "Antworten: Betreff mit „Re:“ ohne Verdopplung")
        check(ComposeDraft.prefixed("WG: Hallo", with: "Fwd:") == "WG: Hallo" && ComposeDraft.prefixed("", with: "Fwd:") == "Fwd:", "Weiterleiten: Betreff")
        var hdr = MailHeaderInfo()
        hdr.fromName = "Jürgen Müller"; hdr.fromEmail = "juergen@example.org"; hdr.messageId = "m1@example.org"; hdr.references = ["m0@example.org"]
        hdr.to = ["anna@icloud.com", "Bernd <bernd@example.org>"]; hdr.cc = ["JUERGEN@example.org", "cc@example.org", "bernd@example.org"]
        let msg = ClientMessage(account: "A", folder: "INBOX", uid: 7, messageId: "m1@example.org", inReplyTo: "", references: [], subject: "Frage", senderName: "Jürgen Müller",
                                senderEmail: "juergen@example.org", recipients: [], date: Date(timeIntervalSince1970: 1_800_000_000), flags: [], size: 1, preview: "", hasBody: true)
        var parsed = ParsedMessage(); parsed.text = "Zeile 1\nZeile 2"
        let id = UUID()
        let one = ComposeDraft.reply(to: msg, header: hdr, parsed: parsed, accountID: id, ownEmail: "anna@icloud.com", all: false)
        check(one.to == "Jürgen Müller <juergen@example.org>" && one.cc.isEmpty && one.subject == "Re: Frage" && one.body.contains("> Zeile 1\n> Zeile 2")
              && one.inReplyTo == "m1@example.org" && one.references == ["m0@example.org", "m1@example.org"] && one.origin?.uid == 7, "Antworten: Empfänger, Zitat, Verweise")
        let all = ComposeDraft.reply(to: msg, header: hdr, parsed: parsed, accountID: id, ownEmail: "ANNA@icloud.com", all: true)
        check(all.cc == "Bernd <bernd@example.org>, cc@example.org", "Allen antworten: ohne dich selbst, ohne Absender, ohne Doppelte (\(all.cc))")
        hdr.replyTo = ["Antwort <reply@example.org>"]
        check(ComposeDraft.reply(to: msg, header: hdr, parsed: parsed, accountID: id, ownEmail: "anna@icloud.com", all: false).to == "Antwort <reply@example.org>", "Antworten: Reply-To hat Vorrang")
        parsed.attachments = [MailAttachment(name: "a.pdf", mime: "application/pdf", data: Data([1]), contentID: nil, isInline: false),
                              MailAttachment(name: "logo.png", mime: "image/png", data: Data([2]), contentID: "<l>", isInline: true)]
        let fwd = ComposeDraft.forward(msg, header: hdr, parsed: parsed, accountID: id)
        check(fwd.subject == "Fwd: Frage" && fwd.attachments.map(\.name) == ["a.pdf"] && fwd.body.contains("Weitergeleitete Nachricht") && fwd.to.isEmpty, "Weiterleiten: Anhänge ohne eingebettete Bilder, kein Empfänger")

        // Konten aus früheren Versionen
        let legacy = #"{"id":"8D1B2E0A-0000-4000-8000-000000000009","name":"iCloud","email":"a@icloud.com","username":"a@icloud.com","host":"imap.mail.me.com","port":993}"#
        if let acc = try? JSONDecoder().decode(ClientAccount.self, from: Data(legacy.utf8)) {
            check(acc.smtpHost == "smtp.mail.me.com" && acc.smtpPort == 587 && acc.smtpSecurity == .startTLS && acc.displayName.isEmpty, "Konto: ältere Einstellungen ohne SMTP-Felder bleiben lesbar")
        } else { check(false, "Konto: ältere Einstellungen ohne SMTP-Felder bleiben lesbar") }
    }

    // MARK: SMTP gegen den Testserver

    static func smtpTests() async throws {
        let smtp = FakeSMTPServer()
        try await smtp.start()
        let config = SMTPConfig(host: "127.0.0.1", port: smtp.port, security: .none)
        var m = OutgoingMessage(fromEmail: "anna@icloud.com", to: ["a@example.org"], cc: ["c@example.org"], subject: "Prüfung", body: "Zeile\n.Punkt am Anfang\n.\nEnde")
        let built = try MessageBuilder.build(m)

        try await SMTPClient.send(config, user: "anna@icloud.com", password: "geheim", from: "anna@icloud.com", recipients: built.recipients, message: built.data)
        let got = smtp.received.first
        check(smtp.received.count == 1 && got?.from == "anna@icloud.com" && got?.recipients == ["a@example.org", "c@example.org"], "SMTP: Absender und Empfänger im Umschlag")
        check(got?.data == built.data, "SMTP: Nachricht kommt bitgleich an (Punkte am Zeilenanfang überstehen die Übertragung)")
        check(smtp.authUsed == "PLAIN anna@icloud.com", "SMTP: Anmeldung mit AUTH PLAIN")

        smtp.advertise = "AUTH LOGIN"
        try await SMTPClient.send(config, user: "anna@icloud.com", password: "geheim", from: "anna@icloud.com", recipients: ["a@example.org"], message: built.data)
        check(smtp.received.count == 2 && smtp.authUsed == "LOGIN anna@icloud.com", "SMTP: Anmeldung mit AUTH LOGIN")

        do { try await SMTPClient.send(config, user: "anna@icloud.com", password: "falsch", from: "anna@icloud.com", recipients: ["a@example.org"], message: built.data); check(false, "SMTP: falsches Passwort") }
        catch SMTPError.auth { check(smtp.received.count == 2, "SMTP: falsches Passwort wird abgelehnt, nichts gesendet") }

        smtp.rejected = ["b@example.org"]
        do { try await SMTPClient.send(config, user: "anna@icloud.com", password: "geheim", from: "anna@icloud.com", recipients: ["a@example.org", "b@example.org"], message: built.data); check(false, "SMTP: abgelehnter Empfänger") }
        catch SMTPError.rejected(let text) { check(text.contains("b@example.org") && smtp.received.count == 2, "SMTP: abgelehnter Empfänger bricht ab, nichts gesendet") }

        smtp.stop()
        do { try await SMTPClient.send(config, user: "x", password: "y", from: "a@x.de", recipients: ["b@x.de"], message: built.data); check(false, "SMTP: Server nicht erreichbar") }
        catch { check(true, "SMTP: nicht erreichbarer Server wird als Fehler gemeldet") }
        m.subject = ""
    }
}


// MARK: - Testserver

/// Minimaler IMAP-Server für Tests: ein Konto, ein Ordner mit Nachrichten, ohne TLS, nur auf der Loopback-Schnittstelle.
final class FakeIMAPServer: @unchecked Sendable {
    struct Msg { var flags: [String]; var raw: String }
    struct Appended { var folder: String; var flags: [String]; var raw: String }

    private final class ConnState: @unchecked Sendable {
        var append: (tag: String, folder: String, flags: [String], size: Int)?
    }

    private let lock = NSLock()
    private var _messages: [UInt32: Msg] = [:]
    private var _uidValidity: UInt32 = 42
    private var _log: [String] = []
    private var _appended: [Appended] = []
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private(set) var port: UInt16 = 0

    var messages: [UInt32: Msg] {
        get { lock.lock(); defer { lock.unlock() }; return _messages }
        set { lock.lock(); _messages = newValue; lock.unlock() }
    }
    var uidValidity: UInt32 {
        get { lock.lock(); defer { lock.unlock() }; return _uidValidity }
        set { lock.lock(); _uidValidity = newValue; lock.unlock() }
    }
    var log: [String] { lock.lock(); defer { lock.unlock() }; return _log }
    var appended: [Appended] { lock.lock(); defer { lock.unlock() }; return _appended }

    func mutate(_ body: (FakeIMAPServer) -> Void) { body(self) }

    func start() async throws {
        let l = try NWListener(using: .tcp, on: .any)
        listener = l
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        final class Once: @unchecked Sendable { var done = false }
        let once = Once()
        port = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<UInt16, Error>) in
            l.stateUpdateHandler = { state in
                guard !once.done else { return }
                if case .ready = state, let p = l.port?.rawValue { once.done = true; cont.resume(returning: p) }
                if case .failed(let e) = state { once.done = true; cont.resume(throwing: e) }
            }
            l.start(queue: .global())
        }
    }

    func stop() {
        listener?.cancel()
        lock.lock(); let all = connections; connections = []; lock.unlock()
        all.forEach { $0.cancel() }
    }

    private func accept(_ c: NWConnection) {
        lock.lock(); connections.append(c); lock.unlock()
        c.start(queue: .global())
        send(c, "* OK IMAP4rev1 Testserver bereit\r\n")
        let state = ConnState()
        var buffer = Data()
        func receive() {
            c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
                guard let self else { return }
                if let data { buffer.append(data) }
                while true {
                    if let a = state.append {
                        guard buffer.count >= a.size + 2 else { break }
                        let raw = String(decoding: buffer.prefix(a.size), as: UTF8.self)
                        buffer = Data(buffer.dropFirst(a.size + 2))
                        state.append = nil
                        self.lock.lock()
                        let uid = (self._messages.keys.max() ?? 100) + 1
                        self._messages[uid] = Msg(flags: a.flags, raw: raw)
                        self._appended.append(Appended(folder: a.folder, flags: a.flags, raw: raw))
                        self.lock.unlock()
                        self.send(c, "\(a.tag) OK [APPENDUID \(self.uidValidity) \(uid)] fertig\r\n")
                        continue
                    }
                    guard let range = buffer.range(of: Data("\r\n".utf8)) else { break }
                    let line = String(decoding: buffer[buffer.startIndex..<range.lowerBound], as: UTF8.self)
                    buffer = Data(buffer.dropFirst(buffer.distance(from: buffer.startIndex, to: range.upperBound)))
                    self.handle(line, on: c, state: state)
                }
                if error == nil, !complete { receive() }
            }
        }
        receive()
    }

    private func send(_ c: NWConnection, _ text: String) { c.send(content: Data(text.utf8), completion: .contentProcessed { _ in }) }
    private func send(_ c: NWConnection, data: Data) { c.send(content: data, completion: .contentProcessed { _ in }) }

    private func expand(_ set: String) -> [UInt32] {
        set.split(separator: ",").flatMap { part -> [UInt32] in
            let r = part.split(separator: ":").compactMap { UInt32($0) }
            return r.count == 2 ? Array(r[0]...r[1]) : r
        }
    }

    private func handle(_ line: String, on c: NWConnection, state: ConnState) {
        lock.lock(); _log.append(line); lock.unlock()
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return }
        let tag = parts[0], rest = parts[1]
        let word = rest.split(separator: " ").first.map { $0.uppercased() } ?? ""
        let msgs = messages
        switch word {
        case "CAPABILITY":
            send(c, "* CAPABILITY IMAP4rev1 IDLE UIDPLUS\r\n\(tag) OK fertig\r\n")
        case "LOGIN":
            let args = rest.split(separator: " ")
            let pass = args.count > 2 ? args[2].trimmingCharacters(in: CharacterSet(charactersIn: "\"")) : ""
            send(c, pass == "secret" ? "\(tag) OK angemeldet\r\n" : "\(tag) NO [AUTHENTICATIONFAILED] falsches Passwort\r\n")
        case "LIST":
            send(c, """
            * LIST (\\HasNoChildren) "/" "INBOX"\r
            * LIST (\\HasNoChildren \\Drafts) "/" "Entw&APw-rfe"\r
            * LIST (\\HasNoChildren \\Sent) "/" "Sent Messages"\r
            * LIST (\\Noselect \\HasChildren) "/" "Parent"\r
            \(tag) OK fertig\r\n
            """)
        case "SELECT":
            let next = (msgs.keys.max() ?? 100) + 1
            send(c, "* \(msgs.count) EXISTS\r\n* OK [UIDVALIDITY \(uidValidity)] ok\r\n* OK [UIDNEXT \(next)] ok\r\n\(tag) OK [READ-WRITE] fertig\r\n")
        case "APPEND":
            // APPEND "Ordner" (Flags) {n}
            let quoted = rest.split(separator: "\"", omittingEmptySubsequences: false)
            let folder = quoted.count > 1 ? IMAPCodec.decodeFolderName(String(quoted[1])) : ""
            let flags = rest.firstIndex(of: "(").flatMap { open in rest[rest.index(after: open)...].firstIndex(of: ")").map { rest[rest.index(after: open)..<$0].split(separator: " ").map(String.init) } } ?? []
            let size = rest.lastIndex(of: "{").flatMap { Int(rest[rest.index(after: $0)...].prefix { $0.isNumber }) } ?? 0
            state.append = (tag, folder, flags, size)
            send(c, "+ bereit\r\n")
        case "LOGOUT":
            send(c, "* BYE\r\n\(tag) OK tschüss\r\n")
        case "UID":
            let args = rest.split(separator: " ", maxSplits: 3).map(String.init)
            guard args.count >= 3 else { send(c, "\(tag) BAD\r\n"); return }
            switch args[1].uppercased() {
            case "SEARCH":
                send(c, "* SEARCH \(msgs.keys.sorted().map(String.init).joined(separator: " "))\r\n\(tag) OK fertig\r\n")
            case "FETCH":
                let items = args.count > 3 ? args[3] : ""
                let order = msgs.keys.sorted()
                for uid in expand(args[2]) {
                    guard let m = msgs[uid], let seq = order.firstIndex(of: uid) else { continue }
                    let flags = "(" + m.flags.joined(separator: " ") + ")"
                    let raw = Data(m.raw.utf8)
                    if items.contains("BODY.PEEK[HEADER]") {
                        let end = raw.range(of: Data("\r\n\r\n".utf8))?.upperBound ?? raw.count
                        let head = raw.prefix(end)
                        send(c, "* \(seq + 1) FETCH (UID \(uid) FLAGS \(flags) INTERNALDATE \"01-Nov-2026 10:00:00 +0100\" RFC822.SIZE \(raw.count) BODY[HEADER] {\(head.count)}\r\n")
                        send(c, data: Data(head)); send(c, ")\r\n")
                    } else if items.contains("BODY.PEEK[]") {
                        send(c, "* \(seq + 1) FETCH (UID \(uid) BODY[] {\(raw.count)}\r\n")
                        send(c, data: raw); send(c, ")\r\n")
                    } else {
                        send(c, "* \(seq + 1) FETCH (UID \(uid) FLAGS \(flags))\r\n")
                    }
                }
                send(c, "\(tag) OK fertig\r\n")
            case "STORE":
                // UID STORE <uid> +FLAGS.SILENT (\Seen)
                let spec = args.count > 3 ? args[3] : ""
                let flags = spec.firstIndex(of: "(").flatMap { open in spec[spec.index(after: open)...].firstIndex(of: ")").map { spec[spec.index(after: open)..<$0].split(separator: " ").map(String.init) } } ?? []
                lock.lock()
                for uid in expand(args[2]) {
                    guard var m = _messages[uid] else { continue }
                    if spec.hasPrefix("+") { m.flags = Array(Set(m.flags + flags)).sorted() }
                    else if spec.hasPrefix("-") { m.flags.removeAll { flags.contains($0) } }
                    _messages[uid] = m
                }
                lock.unlock()
                send(c, "\(tag) OK fertig\r\n")
            case "EXPUNGE":
                lock.lock()
                for uid in expand(args[2]) where _messages[uid]?.flags.contains("\\Deleted") == true { _messages[uid] = nil }
                lock.unlock()
                send(c, "\(tag) OK fertig\r\n")
            default:
                send(c, "\(tag) BAD unbekannt\r\n")
            }
        default:
            send(c, "\(tag) BAD unbekannt\r\n")
        }
    }
}

/// Minimaler SMTP-Server für Tests (ohne TLS, nur Loopback): nimmt Nachrichten an und merkt sie sich.
final class FakeSMTPServer: @unchecked Sendable {
    struct Received { var from: String; var recipients: [String]; var data: Data }

    private final class ConnState: @unchecked Sendable {
        var from = ""
        var recipients: [String] = []
        var inData = false
        var data = Data()
        var loginStep = 0
        var loginUser = ""
    }

    private let lock = NSLock()
    private var _received: [Received] = []
    private var _authUsed = ""
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private(set) var port: UInt16 = 0
    var advertise = "AUTH PLAIN LOGIN"
    var rejected: Set<String> = []
    let user = "anna@icloud.com", password = "geheim"

    var received: [Received] { lock.lock(); defer { lock.unlock() }; return _received }
    var authUsed: String { lock.lock(); defer { lock.unlock() }; return _authUsed }

    func start() async throws {
        let l = try NWListener(using: .tcp, on: .any)
        listener = l
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        final class Once: @unchecked Sendable { var done = false }
        let once = Once()
        port = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<UInt16, Error>) in
            l.stateUpdateHandler = { state in
                guard !once.done else { return }
                if case .ready = state, let p = l.port?.rawValue { once.done = true; cont.resume(returning: p) }
                if case .failed(let e) = state { once.done = true; cont.resume(throwing: e) }
            }
            l.start(queue: .global())
        }
    }

    func stop() {
        listener?.cancel()
        lock.lock(); let all = connections; connections = []; lock.unlock()
        all.forEach { $0.cancel() }
    }

    private func send(_ c: NWConnection, _ text: String) { c.send(content: Data(text.utf8), completion: .contentProcessed { _ in }) }

    private func accept(_ c: NWConnection) {
        lock.lock(); connections.append(c); lock.unlock()
        c.start(queue: .global())
        send(c, "220 fake ESMTP bereit\r\n")
        let st = ConnState()
        var buffer = Data()
        func receive() {
            c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
                guard let self else { return }
                if let data { buffer.append(data) }
                while true {
                    if st.inData {
                        // Ende der Daten: „<CRLF>.<CRLF>“
                        let marker = Data("\r\n.\r\n".utf8)
                        guard let r = buffer.range(of: marker) else { break }
                        var body = Data(buffer[buffer.startIndex..<r.lowerBound])
                        body.append(contentsOf: [13, 10])
                        buffer = Data(buffer.dropFirst(buffer.distance(from: buffer.startIndex, to: r.upperBound)))
                        // Punkte am Zeilenanfang entdoppeln
                        var out = Data()
                        var atStart = true
                        var skip = false
                        for b in body {
                            if atStart, b == 46, !skip { skip = true; atStart = false; continue }
                            skip = false
                            out.append(b)
                            atStart = b == 10
                        }
                        self.lock.lock(); self._received.append(Received(from: st.from, recipients: st.recipients, data: out)); self.lock.unlock()
                        st.inData = false
                        self.send(c, "250 angenommen\r\n")
                        continue
                    }
                    guard let range = buffer.range(of: Data("\r\n".utf8)) else { break }
                    let line = String(decoding: buffer[buffer.startIndex..<range.lowerBound], as: UTF8.self)
                    buffer = Data(buffer.dropFirst(buffer.distance(from: buffer.startIndex, to: range.upperBound)))
                    self.handle(line, c, st)
                }
                if error == nil, !complete { receive() }
            }
        }
        receive()
    }

    private func decode(_ b64: String) -> String { String(data: Data(base64Encoded: b64) ?? Data(), encoding: .utf8) ?? "" }

    private func handle(_ line: String, _ c: NWConnection, _ st: ConnState) {
        if st.loginStep == 1 {
            st.loginUser = decode(line); st.loginStep = 2
            send(c, "334 UGFzc3dvcmQ6\r\n"); return
        }
        if st.loginStep == 2 {
            st.loginStep = 0
            if st.loginUser == user, decode(line) == password {
                lock.lock(); _authUsed = "LOGIN \(st.loginUser)"; lock.unlock()
                send(c, "235 angemeldet\r\n")
            } else { send(c, "535 Anmeldung fehlgeschlagen\r\n") }
            return
        }
        let upper = line.uppercased()
        if upper.hasPrefix("EHLO") {
            send(c, "250-fake\r\n250-SIZE 10000000\r\n250 \(advertise)\r\n")
        } else if upper.hasPrefix("AUTH PLAIN") {
            let fields = decode(String(line.dropFirst(11))).split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
            if fields.count == 3, fields[1] == user, fields[2] == password {
                lock.lock(); _authUsed = "PLAIN \(fields[1])"; lock.unlock()
                send(c, "235 angemeldet\r\n")
            } else { send(c, "535 Anmeldung fehlgeschlagen\r\n") }
        } else if upper.hasPrefix("AUTH LOGIN") {
            st.loginStep = 1
            send(c, "334 VXNlcm5hbWU6\r\n")
        } else if upper.hasPrefix("MAIL FROM:") {
            st.from = String(line.dropFirst(10)).trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
            st.recipients = []
            send(c, "250 ok\r\n")
        } else if upper.hasPrefix("RCPT TO:") {
            let r = String(line.dropFirst(8)).trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
            if rejected.contains(r) { send(c, "550 Empfänger unbekannt\r\n") } else { st.recipients.append(r); send(c, "250 ok\r\n") }
        } else if upper == "DATA" {
            st.inData = true
            send(c, "354 weiter, Ende mit <CRLF>.<CRLF>\r\n")
        } else if upper == "QUIT" {
            send(c, "221 tschüss\r\n")
        } else {
            send(c, "500 unbekannt\r\n")
        }
    }
}

import Foundation

/// MIME-Verarbeitung für den eigenen Mail-Client: Header, mehrteilige Nachrichten, Kodierungen.

struct MIMEHeader: Hashable {
    var name: String
    var value: String
}

struct MIMEPart {
    var headers: [MIMEHeader] = []
    /// Rumpf, noch in der Transferkodierung (base64, quoted-printable …).
    var body: [UInt8] = []
    var children: [MIMEPart] = []

    func header(_ name: String) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    /// Inhaltstyp in Kleinbuchstaben (Standard `text/plain`) und Parameter.
    var contentType: (main: String, params: [String: String]) {
        let p = MIME.parseParams(header("Content-Type") ?? "")
        return (p.main.isEmpty ? "text/plain" : p.main.lowercased(), p.params)
    }

    var disposition: (main: String, params: [String: String]) {
        let p = MIME.parseParams(header("Content-Disposition") ?? "")
        return (p.main.lowercased(), p.params)
    }
}

struct MailAttachment: Identifiable, Hashable {
    var id = UUID()
    var name: String
    var mime: String
    var data: Data
    var contentID: String?
    var isInline: Bool
}

struct ParsedMessage {
    var text = ""
    var html: String?
    var attachments: [MailAttachment] = []

    /// Klartext für Vorschau und Suche; bei reinen HTML-Mails aus dem HTML gewonnen.
    var plainText: String { text.isEmpty ? (html.map(MIME.stripHTML) ?? "") : text }

    var preview: String {
        String(plainText.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(160))
    }

    /// HTML mit eingebetteten Bildern (`cid:`) als Datenadressen – externe Inhalte bleiben unberührt.
    func htmlWithInlineImages() -> String? {
        guard var out = html else { return nil }
        for a in attachments where a.mime.hasPrefix("image/") {
            guard let cid = a.contentID?.trimmingCharacters(in: CharacterSet(charactersIn: "<> ")), !cid.isEmpty else { continue }
            let uri = "data:\(a.mime);base64,\(a.data.base64EncodedString())"
            out = out.replacingOccurrences(of: "cid:\(cid)", with: uri, options: .caseInsensitive)
        }
        return out
    }
}

/// Kopfdaten einer Nachricht für Listen.
struct MailHeaderInfo {
    var subject = ""
    var fromName = ""
    var fromEmail = ""
    var to: [String] = []
    var cc: [String] = []
    var date: Date?
    var messageId = ""
    var inReplyTo = ""
    var references: [String] = []
    var replyTo: [String] = []
}

enum MIME {
    // MARK: Aufbau

    static func parse(_ data: [UInt8]) -> MIMEPart {
        let (head, body) = splitHeadBody(data)
        var part = MIMEPart(headers: parseHeaders(head), body: body)
        let ct = part.contentType
        if ct.main.hasPrefix("multipart/"), let boundary = ct.params["boundary"], !boundary.isEmpty {
            part.children = splitMultipart(body, boundary: boundary).map(parse)
        }
        return part
    }

    static func splitHeadBody(_ b: [UInt8]) -> (head: [UInt8], body: [UInt8]) {
        let n = b.count
        if n >= 1, b[0] == 10 { return ([], Array(b[1...])) }
        if n >= 2, b[0] == 13, b[1] == 10 { return ([], Array(b[2...])) }
        var i = 0
        while i < n {
            if b[i] == 10 {
                if i + 1 < n, b[i + 1] == 10 { return (Array(b[0..<i]), Array(b[(i + 2)...])) }
                if i + 2 < n, b[i + 1] == 13, b[i + 2] == 10 { return (Array(b[0..<i]), Array(b[(i + 3)...])) }
            }
            i += 1
        }
        return (b, [])
    }

    static func parseHeaders(_ bytes: [UInt8]) -> [MIMEHeader] {
        // Auf Byte-Ebene trennen: Swift behandelt „\r\n“ als ein einziges Zeichen.
        var lines: [String] = []
        for raw in bytes.split(separator: 10, omittingEmptySubsequences: false) {
            var chunk = Array(raw)
            if chunk.last == 13 { chunk.removeLast() }
            let line = String(bytes: chunk, encoding: .utf8) ?? String(bytes: chunk, encoding: .isoLatin1) ?? ""
            if let f = chunk.first, f == 32 || f == 9, !lines.isEmpty {
                lines[lines.count - 1] += " " + line.trimmingCharacters(in: .whitespaces)
            } else {
                lines.append(line)
            }
        }
        return lines.compactMap { line in
            guard let colon = line.firstIndex(of: ":"), colon != line.startIndex else { return nil }
            return MIMEHeader(name: String(line[..<colon]).trimmingCharacters(in: .whitespaces),
                              value: String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces))
        }
    }

    static func splitMultipart(_ b: [UInt8], boundary: String) -> [[UInt8]] {
        let delim = Array("--\(boundary)".utf8)
        let n = b.count
        // Positionen der Trennzeilen: (Anfang, Ende der Zeile, ist Schlussmarke)
        var marks: [(start: Int, contentStart: Int, final: Bool)] = []
        var i = 0
        while i + delim.count <= n {
            if (i == 0 || b[i - 1] == 10), b[i] == delim[0], Array(b[i..<(i + delim.count)]) == delim {
                let after = i + delim.count
                let final = after + 1 < n && b[after] == 45 && b[after + 1] == 45
                var j = after
                while j < n, b[j] != 10 { j += 1 }
                marks.append((i, min(j + 1, n), final))
                i = j + 1
                if final { break }
            } else {
                i += 1
            }
        }
        var parts: [[UInt8]] = []
        for (k, m) in marks.enumerated() where !m.final {
            guard k + 1 < marks.count else { break }
            var end = marks[k + 1].start - 1                       // das \n vor der nächsten Trennzeile
            if end > m.contentStart - 1, end - 1 >= 0, b[end - 1] == 13 { end -= 1 }
            if end >= m.contentStart { parts.append(Array(b[m.contentStart..<end])) } else { parts.append([]) }
        }
        return parts
    }

    // MARK: Parameter

    /// „text/plain; charset="utf-8"“ → Haupttyp und Parameter (inkl. RFC 2231: `filename*=utf-8''…`, `name*0=…`).
    static func parseParams(_ s: String) -> (main: String, params: [String: String]) {
        var pieces: [String] = []
        var cur = ""
        var quoted = false
        var escaped = false
        for ch in s {
            if escaped { cur.append(ch); escaped = false; continue }
            if quoted, ch == "\\" { cur.append(ch); escaped = true; continue }
            if ch == "\"" { quoted.toggle(); cur.append(ch); continue }
            if ch == ";", !quoted { pieces.append(cur); cur = ""; continue }
            cur.append(ch)
        }
        pieces.append(cur)
        let main = pieces.first?.trimmingCharacters(in: .whitespaces) ?? ""
        var simple: [String: String] = [:]
        var continued: [String: [Int: (value: String, encoded: Bool)]] = [:]
        for raw in pieces.dropFirst() {
            guard let eq = raw.firstIndex(of: "=") else { continue }
            var key = raw[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            var value = raw[raw.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
            }
            if key.hasSuffix("*") {
                key.removeLast()
                if let star = key.lastIndex(of: "*"), let n = Int(key[key.index(after: star)...]) {
                    let base = String(key[..<star])
                    continued[base, default: [:]][n] = (value, true)
                } else {
                    simple[key] = decodeExtended(value)
                }
            } else if let star = key.lastIndex(of: "*"), let n = Int(key[key.index(after: star)...]) {
                continued[String(key[..<star]), default: [:]][n] = (value, false)
            } else {
                simple[key] = value
            }
        }
        for (base, map) in continued {
            let ordered = map.keys.sorted().compactMap { map[$0] }
            guard let first = ordered.first else { continue }
            if first.encoded {
                simple[base] = decodeExtended(ordered.map(\.value).joined())
            } else {
                simple[base] = ordered.map(\.value).joined()
            }
        }
        return (main, simple)
    }

    /// `utf-8''%C3%A4.txt` → „ä.txt“
    static func decodeExtended(_ v: String) -> String {
        let parts = v.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3 else { return v.removingPercentEncoding ?? v }
        var bytes: [UInt8] = []
        let text = Array(parts[2].utf8)
        var i = 0
        while i < text.count {
            if text[i] == 37, i + 2 < text.count, let h = hexValue(text[i + 1]), let l = hexValue(text[i + 2]) {
                bytes.append(UInt8(h * 16 + l)); i += 3
            } else {
                bytes.append(text[i]); i += 1
            }
        }
        return string(from: Data(bytes), charset: String(parts[0]))
    }

    // MARK: Kodierungen

    static func hexValue(_ c: UInt8) -> Int? {
        switch c {
        case 48...57: return Int(c) - 48
        case 65...70: return Int(c) - 55
        case 97...102: return Int(c) - 87
        default: return nil
        }
    }

    static func encoding(for charset: String?) -> String.Encoding? {
        guard let charset = charset?.trimmingCharacters(in: .whitespaces).lowercased(), !charset.isEmpty else { return nil }
        let cf = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
        if cf == kCFStringEncodingInvalidId { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
    }

    static func string(from data: Data, charset: String?) -> String {
        if let enc = encoding(for: charset), let s = String(data: data, encoding: enc) { return s }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
    }

    static func quotedPrintable(_ input: [UInt8], header: Bool = false) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(input.count)
        var i = 0
        while i < input.count {
            let c = input[i]
            if c == 61 {                                             // =
                if i + 1 < input.count, input[i + 1] == 10 { i += 2; continue }
                if i + 2 < input.count, input[i + 1] == 13, input[i + 2] == 10 { i += 3; continue }
                if i + 2 < input.count, let h = hexValue(input[i + 1]), let l = hexValue(input[i + 2]) {
                    out.append(UInt8(h * 16 + l)); i += 3; continue
                }
            }
            out.append(header && c == 95 ? 32 : c)
            i += 1
        }
        return out
    }

    /// Rumpf nach der Transferkodierung.
    static func decodedBody(_ p: MIMEPart) -> Data {
        switch (p.header("Content-Transfer-Encoding") ?? "").trimmingCharacters(in: .whitespaces).lowercased() {
        case "base64":
            let s = String(decoding: p.body, as: UTF8.self)
            return Data(base64Encoded: s, options: .ignoreUnknownCharacters) ?? Data()
        case "quoted-printable":
            return Data(quotedPrintable(p.body))
        default:
            return Data(p.body)
        }
    }

    /// RFC 2047: `=?UTF-8?Q?M=C3=BCller?=` → „Müller“
    static func decodeWords(_ s: String) -> String {
        guard s.contains("=?") else { return s }
        guard let re = try? NSRegularExpression(pattern: #"=\?([^?\s]+)\?([bBqQ])\?([^?\s]*)\?="#) else { return s }
        let ns = s as NSString
        let matches = re.matches(in: s, range: NSRange(location: 0, length: ns.length))
        var out = ""
        var last = 0
        var previousWasWord = false
        for m in matches {
            let gap = ns.substring(with: NSRange(location: last, length: m.range.location - last))
            // Zwischen zwei kodierten Wörtern ist Leerraum bedeutungslos.
            if !(previousWasWord && gap.allSatisfy(\.isWhitespace)) { out += gap }
            let charset = ns.substring(with: m.range(at: 1))
            let kind = ns.substring(with: m.range(at: 2)).lowercased()
            let payload = ns.substring(with: m.range(at: 3))
            let bytes: Data
            if kind == "b" {
                bytes = Data(base64Encoded: payload + String(repeating: "=", count: (4 - payload.count % 4) % 4)) ?? Data()
            } else {
                bytes = Data(quotedPrintable(Array(payload.utf8), header: true))
            }
            out += string(from: bytes, charset: charset)
            last = m.range.location + m.range.length
            previousWasWord = true
        }
        out += ns.substring(from: last)
        return out
    }

    // MARK: Nachricht auswerten

    static func extract(_ root: MIMEPart) -> ParsedMessage {
        var texts: [String] = []
        var htmls: [String] = []
        var attachments: [MailAttachment] = []

        func walk(_ p: MIMEPart) {
            let ct = p.contentType
            if ct.main.hasPrefix("multipart/") {
                p.children.forEach(walk)
                return
            }
            let disp = p.disposition
            let filename = disp.params["filename"] ?? ct.params["name"]
            let isText = ct.main == "text/plain" || ct.main == "text/html"
            if isText, disp.main != "attachment", filename == nil {
                let s = string(from: decodedBody(p), charset: ct.params["charset"])
                if ct.main == "text/html" { htmls.append(s) } else { texts.append(s) }
                return
            }
            let cid = p.header("Content-ID")
            var name = filename.map(decodeWords) ?? ""
            if name.isEmpty { name = ct.main == "message/rfc822" ? "Nachricht.eml" : (ct.main == "text/calendar" ? "Einladung.ics" : "Anhang") }
            attachments.append(MailAttachment(name: name, mime: ct.main, data: decodedBody(p), contentID: cid,
                                              isInline: disp.main == "inline" || cid != nil))
        }
        walk(root)
        return ParsedMessage(text: texts.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines),
                             html: htmls.isEmpty ? nil : htmls.joined(separator: "\n"), attachments: attachments)
    }

    static func stripHTML(_ html: String) -> String {
        var s = html
        for pattern in [#"(?is)<(style|script|head)[^>]*>.*?</\1>"#, #"(?i)<br\s*/?>"#, #"(?i)</(p|div|tr|li|h[1-6])>"#] {
            let replacement = pattern.contains("style") ? " " : "\n"
            s = s.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        s = s.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        for (e, r) in [("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&auml;", "ä"),
                       ("&ouml;", "ö"), ("&uuml;", "ü"), ("&Auml;", "Ä"), ("&Ouml;", "Ö"), ("&Uuml;", "Ü"), ("&szlig;", "ß")] {
            s = s.replacingOccurrences(of: e, with: r)
        }
        return s.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Kopfdaten

    /// Adressliste auftrennen; Kommas in Anführungszeichen oder spitzen Klammern trennen nicht.
    static func splitAddresses(_ s: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var quoted = false
        var angle = false
        for ch in s {
            switch ch {
            case "\"": quoted.toggle(); cur.append(ch)
            case "<" where !quoted: angle = true; cur.append(ch)
            case ">" where !quoted: angle = false; cur.append(ch)
            case "," where !quoted && !angle:
                if !cur.trimmingCharacters(in: .whitespaces).isEmpty { out.append(cur.trimmingCharacters(in: .whitespaces)) }
                cur = ""
            default: cur.append(ch)
            }
        }
        if !cur.trimmingCharacters(in: .whitespaces).isEmpty { out.append(cur.trimmingCharacters(in: .whitespaces)) }
        return out
    }

    static func messageIDs(_ s: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: #"<([^<>\s]+)>"#) else { return [] }
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }
    }

    private static let dateFormats = ["EEE, d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm Z", "EEE, d MMM yy HH:mm:ss Z",
                                      "EEE, d MMM yyyy HH:mm:ss z", "d MMM yyyy HH:mm Z"]

    static func parseDate(_ raw: String) -> Date? {
        var s = raw.replacingOccurrences(of: #"\([^)]*\)"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        for format in dateFormats {
            f.dateFormat = format
            if let d = f.date(from: s) { return d }
        }
        return nil
    }

    /// Kennzeichen automatisch erzeugter Mails (für den Vorfilter): auto, bulk, list, suppress – durch Leerzeichen getrennt.
    static func automationFlags(_ headers: [MIMEHeader]) -> String {
        func h(_ n: String) -> String? { headers.first { $0.name.caseInsensitiveCompare(n) == .orderedSame }?.value }
        var flags: [String] = []
        if let auto = h("Auto-Submitted"), auto.trimmingCharacters(in: .whitespaces).lowercased() != "no" { flags.append("auto") }
        if let prec = h("Precedence")?.trimmingCharacters(in: .whitespaces).lowercased(), ["bulk", "list", "junk"].contains(where: { prec.hasPrefix($0) }) { flags.append("bulk") }
        if h("List-Id") != nil { flags.append("list") }
        if h("X-Auto-Response-Suppress") != nil { flags.append("suppress") }
        return flags.joined(separator: " ")
    }

    static func headerInfo(_ head: [UInt8]) -> MailHeaderInfo {
        let headers = parseHeaders(head)
        func h(_ n: String) -> String? { headers.first { $0.name.caseInsensitiveCompare(n) == .orderedSame }?.value }
        var info = MailHeaderInfo()
        info.subject = decodeWords(h("Subject") ?? "")
        if let from = h("From") {
            let p = MailAddress.parse(decodeWords(splitAddresses(from).first ?? from))
            info.fromName = p.name ?? ""
            info.fromEmail = p.email
        }
        info.to = splitAddresses(decodeWords(h("To") ?? ""))
        info.cc = splitAddresses(decodeWords(h("Cc") ?? ""))
        info.replyTo = splitAddresses(decodeWords(h("Reply-To") ?? ""))
        info.date = h("Date").flatMap(parseDate)
        info.messageId = messageIDs(h("Message-ID") ?? "").first ?? ""
        info.inReplyTo = messageIDs(h("In-Reply-To") ?? "").first ?? ""
        info.references = messageIDs(h("References") ?? "")
        return info
    }
}

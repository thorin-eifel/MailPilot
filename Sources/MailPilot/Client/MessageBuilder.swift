import Foundation

struct OutgoingAttachment: Identifiable, Hashable {
    var id = UUID()
    var name: String
    var mime: String
    var data: Data
}

struct OutgoingMessage {
    var fromName = ""
    var fromEmail: String
    var to: [String] = []
    var cc: [String] = []
    var bcc: [String] = []
    var subject = ""
    var body = ""
    var inReplyTo: String?
    var references: [String] = []
    var attachments: [OutgoingAttachment] = []
    var date = Date()
    var messageID: String?
}

enum BuildError: LocalizedError {
    case invalidAddress(String)
    case noRecipients

    var errorDescription: String? {
        switch self {
        case .invalidAddress(let a): return "Ungültige Adresse: \(a)"
        case .noRecipients: return "Es ist kein Empfänger angegeben."
        }
    }
}

/// Baut eine Nachricht nach RFC 5322/2045: Kopfzeilen, Text als quoted-printable, Anhänge als base64.
enum MessageBuilder {
    struct Built {
        var data: Data
        var recipients: [String]
        var messageID: String
    }

    static func isASCII(_ s: String) -> Bool { s.unicodeScalars.allSatisfy { $0.value >= 32 && $0.value < 127 } }

    /// Zeilenumbrüche entfernen: Schutz vor eingeschleusten Kopfzeilen.
    static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
    }

    /// Nicht-ASCII-Text als RFC-2047-Wörter (je höchstens 45 Byte Inhalt), gefaltet.
    static func encodeWords(_ s: String) -> String {
        let s = clean(s)
        if isASCII(s) { return s }
        var chunks: [String] = []
        var cur = ""
        var bytes = 0
        for ch in s {
            let n = String(ch).utf8.count
            if bytes + n > 45 { chunks.append(cur); cur = ""; bytes = 0 }
            cur.append(ch)
            bytes += n
        }
        chunks.append(cur)
        return chunks.map { "=?UTF-8?B?\(Data($0.utf8).base64EncodedString())?=" }.joined(separator: "\r\n ")
    }

    /// „Anna Beispiel <anna@x.de>“ oder „anna@x.de“ → Name und Adresse, geprüft.
    static func parseAddress(_ raw: String) throws -> (name: String, email: String) {
        let p = MailAddress.parse(clean(raw))
        let email = p.email
        guard email.contains("@"), !email.contains(" "), !email.contains("<"), !email.contains(">"), !email.contains(","),
              email.hasPrefix("@") == false, email.hasSuffix("@") == false else { throw BuildError.invalidAddress(raw) }
        return (p.name ?? "", email)
    }

    static func formatAddress(name: String, email: String) -> String {
        let name = clean(name)
        if name.isEmpty { return email }
        if isASCII(name) { return "\"" + name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\" <\(email)>" }
        return "\(encodeWords(name)) <\(email)>"
    }

    /// Eingabefeld „a@x.de, B <b@x.de>“ in einzelne Adressen zerlegen.
    static func addressList(_ field: String) throws -> [(name: String, email: String)] {
        try MIME.splitAddresses(field.replacingOccurrences(of: ";", with: ",")).map(parseAddress)
    }

    private static func foldList(_ items: [String]) -> String {
        var lines: [String] = []
        var cur = ""
        for item in items {
            let piece = cur.isEmpty ? item : ", " + item
            if cur.count + piece.count > 70, !cur.isEmpty { lines.append(cur + ","); cur = item } else { cur += piece }
        }
        lines.append(cur)
        return lines.joined(separator: "\r\n ")
    }

    // MARK: Kodierung

    static func quotedPrintable(_ text: String) -> String {
        var lines: [[UInt8]] = [[]]
        for b in Array(text.utf8) {
            if b == 10 { lines.append([]) } else if b != 13 { lines[lines.count - 1].append(b) }
        }
        let hex = Array("0123456789ABCDEF".utf8)
        var out: [String] = []
        for line in lines {
            var result = ""
            var width = 0
            func emit(_ token: String) {
                if width + token.count > 75 { result += "=\r\n"; width = 0 }
                result += token
                width += token.count
            }
            for (i, b) in line.enumerated() {
                let trailing = i == line.count - 1
                if b == 9 || b == 32 {
                    emit(trailing ? "=" + String(UnicodeScalar(hex[Int(b >> 4)])) + String(UnicodeScalar(hex[Int(b & 15)])) : String(UnicodeScalar(b)))
                } else if b >= 33, b <= 126, b != 61 {
                    emit(String(UnicodeScalar(b)))
                } else {
                    emit("=" + String(UnicodeScalar(hex[Int(b >> 4)])) + String(UnicodeScalar(hex[Int(b & 15)])))
                }
            }
            out.append(result)
        }
        return out.joined(separator: "\r\n")
    }

    static func base64Lines(_ data: Data) -> String {
        let s = data.base64EncodedString()
        var lines: [String] = []
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 76, limitedBy: s.endIndex) ?? s.endIndex
            lines.append(String(s[i..<j]))
            i = j
        }
        return lines.joined(separator: "\r\n")
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return f
    }()

    static func percentEncode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789.-_~")) ?? s
    }

    // MARK: Aufbau

    /// `requireRecipients: false` für Entwürfe.
    static func build(_ m: OutgoingMessage, requireRecipients: Bool = true) throws -> Built {
        let from = try parseAddress(m.fromEmail)
        let to = try addressList(m.to.joined(separator: ","))
        let cc = try addressList(m.cc.joined(separator: ","))
        let bcc = try addressList(m.bcc.joined(separator: ","))
        let recipients = (to + cc + bcc).map(\.email)
        if requireRecipients, recipients.isEmpty { throw BuildError.noRecipients }

        let domain = from.email.split(separator: "@").last.map(String.init) ?? "localhost"
        let messageID = m.messageID ?? "\(UUID().uuidString.lowercased())@\(domain)"

        var head: [String] = []
        head.append("From: " + formatAddress(name: m.fromName, email: from.email))
        if !to.isEmpty { head.append("To: " + foldList(to.map { formatAddress(name: $0.name, email: $0.email) })) }
        if !cc.isEmpty { head.append("Cc: " + foldList(cc.map { formatAddress(name: $0.name, email: $0.email) })) }
        head.append("Subject: " + encodeWords(m.subject))
        head.append("Date: " + dateFormatter.string(from: m.date))
        head.append("Message-ID: <\(messageID)>")
        if let irt = m.inReplyTo, !irt.isEmpty { head.append("In-Reply-To: <\(clean(irt))>") }
        let refs = m.references.filter { !$0.isEmpty }
        if !refs.isEmpty { head.append("References: " + refs.map { "<\(clean($0))>" }.joined(separator: " ")) }
        head.append("MIME-Version: 1.0")
        head.append("X-Mailer: MailPilot")

        let textPart = "Content-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\n" + quotedPrintable(m.body)
        var out: String
        if m.attachments.isEmpty {
            out = head.joined(separator: "\r\n") + "\r\n" + textPart + "\r\n"
        } else {
            let boundary = "=_MailPilot_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
            head.append("Content-Type: multipart/mixed; boundary=\"\(boundary)\"")
            var parts = ["--\(boundary)\r\n" + textPart]
            for a in m.attachments {
                let asciiName = isASCII(a.name) ? a.name : a.name.unicodeScalars.map { $0.value < 127 && $0.value >= 32 ? String($0) : "_" }.joined()
                let safe = clean(asciiName).replacingOccurrences(of: "\"", with: "'")
                let mime = clean(a.mime).isEmpty ? "application/octet-stream" : clean(a.mime)
                parts.append("--\(boundary)\r\nContent-Type: \(mime); name=\"\(safe)\"\r\n"
                             + "Content-Disposition: attachment; filename=\"\(safe)\"; filename*=UTF-8''\(percentEncode(clean(a.name)))\r\n"
                             + "Content-Transfer-Encoding: base64\r\n\r\n" + base64Lines(a.data))
            }
            out = head.joined(separator: "\r\n") + "\r\n\r\n" + parts.joined(separator: "\r\n") + "\r\n--\(boundary)--\r\n"
        }
        return Built(data: Data(out.utf8), recipients: recipients, messageID: messageID)
    }
}

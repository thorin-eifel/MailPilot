import Foundation

/// IMAP-Protokoll: Antworten zerlegen, Ordnernamen (modifiziertes UTF-7) und UID-Mengen.

enum IMAPValue: Equatable {
    case null
    case atom(String)
    case string([UInt8])
    case list([IMAPValue])

    /// Text eines Atoms oder Strings.
    var text: String? {
        switch self {
        case .atom(let s): return s
        case .string(let b): return String(bytes: b, encoding: .utf8) ?? String(bytes: b, encoding: .isoLatin1)
        default: return nil
        }
    }

    var number: UInt32? {
        if case .atom(let s) = self { return UInt32(s) }
        return nil
    }

    var items: [IMAPValue] {
        if case .list(let l) = self { return l }
        return []
    }

    var bytes: [UInt8]? {
        switch self {
        case .string(let b): return b
        case .atom(let s): return Array(s.utf8)
        default: return nil
        }
    }
}

enum IMAPError: LocalizedError {
    case parse(String)
    case command(String)
    case connection(String)
    case timeout
    case auth(String)

    var errorDescription: String? {
        switch self {
        case .parse(let m): return "Unerwartete Serverantwort: \(m)"
        case .command(let m): return "Der Mailserver lehnte den Befehl ab: \(m)"
        case .connection(let m): return "Verbindung zum Mailserver fehlgeschlagen: \(m)"
        case .timeout: return "Zeitüberschreitung beim Mailserver."
        case .auth(let m): return "Anmeldung fehlgeschlagen: \(m)"
        }
    }
}

/// Eine vollständige Serverantwort (Zeile samt eingebetteten Literalen) in Bestandteile zerlegt.
struct IMAPResponse {
    var raw: [UInt8]
    var tokens: [IMAPValue]

    /// Textzeile ohne Literal-Inhalte, für Statuscodes wie `[UIDVALIDITY 123]`.
    var line: String { String(decoding: raw, as: UTF8.self) }

    init(raw: [UInt8]) {
        self.raw = raw
        var p = IMAPParser(raw)
        self.tokens = (try? p.parseAll()) ?? []
    }

    /// Bestandteile ohne das einleitende `*`.
    var body: [IMAPValue] { tokens.first == .atom("*") ? Array(tokens.dropFirst()) : tokens }

    /// Zahl vor dem Schlüsselwort: `* 23 EXISTS`
    func count(_ keyword: String) -> UInt32? {
        let t = body
        guard t.count >= 2, let n = t[0].number, t[1].text?.uppercased() == keyword else { return nil }
        return n
    }

    /// Schlüsselwort nach `*`: `* LIST …`, `* SEARCH …`; bei `* 5 FETCH` das Wort nach der Zahl.
    var keyword: String? {
        let t = body
        if let first = t.first, first.number == nil { return first.text?.uppercased() }
        return t.count > 1 ? t[1].text?.uppercased() : nil
    }

    /// Zahl aus `[KEY 123]` in einer OK-Zeile.
    func code(_ key: String) -> UInt32? {
        guard let r = line.range(of: "[\(key) ") else { return nil }
        let rest = line[r.upperBound...]
        return UInt32(rest.prefix { $0.isNumber })
    }
}

struct IMAPParser {
    private let b: [UInt8]
    private var i = 0

    init(_ bytes: [UInt8]) { b = bytes }

    mutating func parseAll() throws -> [IMAPValue] {
        var out: [IMAPValue] = []
        while true {
            skipSpace()
            if i >= b.count { break }
            if b[i] == 13 || b[i] == 10 { i += 1; continue }
            out.append(try value())
        }
        return out
    }

    private mutating func skipSpace() {
        while i < b.count, b[i] == 32 { i += 1 }
    }

    private mutating func value() throws -> IMAPValue {
        guard i < b.count else { throw IMAPError.parse("Ende") }
        switch b[i] {
        case 40:                                                   // (
            i += 1
            var items: [IMAPValue] = []
            while true {
                skipSpace()
                guard i < b.count else { throw IMAPError.parse("Liste nicht geschlossen") }
                if b[i] == 41 { i += 1; return .list(items) }
                items.append(try value())
            }
        case 34:                                                   // "
            i += 1
            var out: [UInt8] = []
            while i < b.count, b[i] != 34 {
                if b[i] == 92, i + 1 < b.count { i += 1 }
                out.append(b[i]); i += 1
            }
            guard i < b.count else { throw IMAPError.parse("String nicht geschlossen") }
            i += 1
            return .string(out)
        case 123:                                                  // {n}
            var j = i + 1
            var n = 0
            while j < b.count, b[j] >= 48, b[j] <= 57 { n = n * 10 + Int(b[j] - 48); j += 1 }
            if j < b.count, b[j] == 43 { j += 1 }                  // {n+}
            guard j < b.count, b[j] == 125 else { throw IMAPError.parse("Literal") }
            j += 1
            if j < b.count, b[j] == 13 { j += 1 }
            if j < b.count, b[j] == 10 { j += 1 }
            guard j + n <= b.count else { throw IMAPError.parse("Literal zu kurz") }
            let data = Array(b[j..<(j + n)])
            i = j + n
            return .string(data)
        default:
            let start = i
            // Eckige Klammern (BODY[HEADER]) gehören zum Atom, Leerzeichen darin nicht.
            while i < b.count, b[i] != 32, b[i] != 40, b[i] != 41, b[i] != 13, b[i] != 10 { i += 1 }
            let s = String(decoding: b[start..<i], as: UTF8.self)
            return s.uppercased() == "NIL" ? .null : .atom(s)
        }
    }
}

enum IMAPCodec {
    /// Modifiziertes UTF-7 (RFC 3501): `Entw&APw-rfe` → „Entwürfe“
    static func decodeFolderName(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""
        var it = s.makeIterator()
        while let c = it.next() {
            if c != "&" { out.append(c); continue }
            var b64 = ""
            while let d = it.next(), d != "-" { b64.append(d) }
            if b64.isEmpty { out.append("&"); continue }
            var std = b64.replacingOccurrences(of: ",", with: "/")
            std += String(repeating: "=", count: (4 - std.count % 4) % 4)
            if let data = Data(base64Encoded: std), let str = String(data: data, encoding: .utf16BigEndian) { out += str }
        }
        return out
    }

    static func encodeFolderName(_ s: String) -> String {
        var out = ""
        var run: [UInt16] = []
        func flush() {
            guard !run.isEmpty else { return }
            var data = Data()
            for u in run { data.append(UInt8(u >> 8)); data.append(UInt8(u & 0xFF)) }
            let b64 = data.base64EncodedString().replacingOccurrences(of: "/", with: ",").replacingOccurrences(of: "=", with: "")
            out += "&" + b64 + "-"
            run = []
        }
        for scalar in s.unicodeScalars {
            if scalar.value >= 0x20, scalar.value <= 0x7E {
                flush()
                if scalar == "&" { out += "&-" } else { out.unicodeScalars.append(scalar) }
            } else {
                run.append(contentsOf: Array(String(scalar).utf16))
            }
        }
        flush()
        return out
    }

    /// Quoted-String für Befehle (Anführungszeichen und Rückstrich maskieren).
    static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// UID-Menge mit Bereichen: [1,2,3,7,9,10] → „1:3,7,9:10“
    static func uidSet(_ uids: [UInt32]) -> String {
        let sorted = Array(Set(uids)).sorted()
        var parts: [String] = []
        var i = 0
        while i < sorted.count {
            var j = i
            while j + 1 < sorted.count, sorted[j + 1] == sorted[j] + 1 { j += 1 }
            parts.append(i == j ? "\(sorted[i])" : "\(sorted[i]):\(sorted[j])")
            i = j + 1
        }
        return parts.joined(separator: ",")
    }

    private static let internalDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "d-MMM-yyyy HH:mm:ss Z"
        return f
    }()

    static func parseInternalDate(_ s: String) -> Date? {
        internalDateFormatter.date(from: s.trimmingCharacters(in: .whitespaces))
    }
}

// MARK: - Ergebnisse

struct IMAPFolderInfo: Hashable {
    var path: String
    var name: String
    var delimiter: String
    var special: String?
    var selectable: Bool
}

struct IMAPMailboxStatus {
    var exists: UInt32 = 0
    var uidValidity: UInt32 = 0
    var uidNext: UInt32 = 0
}

struct IMAPFetched {
    var uid: UInt32
    var flags: [String] = []
    var internalDate: Date?
    var size: Int = 0
    var header: [UInt8]?
    var body: [UInt8]?
}

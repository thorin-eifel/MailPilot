import Foundation

/// Wo gesucht wird: im gewählten Ordner, im ganzen Konto oder in allen Konten.
enum ClientSearchScope: Equatable {
    case folder(account: String, path: String)
    case account(String)
    case all
}

/// Suchanfrage: freie Begriffe plus `von:`, `an:` und `betreff:`; Wörter in Anführungszeichen bleiben zusammen.
/// Beispiel: `von:anna rechnung "oktober 2026"`.
struct ClientSearchQuery: Equatable {
    var terms: [String] = []
    var from: [String] = []
    var to: [String] = []
    var subject: [String] = []

    var isEmpty: Bool { terms.isEmpty && from.isEmpty && to.isEmpty && subject.isEmpty }

    static func parse(_ text: String) -> ClientSearchQuery {
        var tokens: [String] = []
        var cur = ""
        var quoted = false
        for ch in text {
            if ch == "\"" { quoted.toggle(); cur.append(ch); continue }
            if ch.isWhitespace && !quoted {
                if !cur.isEmpty { tokens.append(cur); cur = "" }
            } else {
                cur.append(ch)
            }
        }
        if !cur.isEmpty { tokens.append(cur) }

        var q = ClientSearchQuery()
        for raw in tokens {
            var token = raw
            var field: String?
            if let colon = token.firstIndex(of: ":"), colon != token.startIndex {
                let name = token[..<colon].lowercased()
                if ["von", "from", "an", "to", "betreff", "subject"].contains(name) {
                    field = name
                    token = String(token[token.index(after: colon)...])
                }
            }
            let value = token.replacingOccurrences(of: "\"", with: "").trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { continue }
            switch field {
            case "von", "from": q.from.append(value)
            case "an", "to": q.to.append(value)
            case "betreff", "subject": q.subject.append(value)
            default: q.terms.append(value)
            }
        }
        return q
    }
}

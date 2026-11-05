import AppKit
import Foundation
import UniformTypeIdentifiers

/// Inhalt eines `mailto:`-Links (RFC 6068).
struct MailtoDraft: Equatable {
    var to: [String] = []
    var cc: [String] = []
    var bcc: [String] = []
    var subject = ""
    var body = ""
}

enum MailtoURL {
    /// Zerlegt einen `mailto:`-Link. `+` bleibt ein Pluszeichen (es steht nicht für ein Leerzeichen). Parameter wie `attach` werden
    /// absichtlich ignoriert – ein Link darf keine Dateien an eine Nachricht hängen.
    static func parse(_ url: URL) -> MailtoDraft? {
        guard url.scheme?.lowercased() == "mailto" else { return nil }
        var rest = url.absoluteString.dropFirst("mailto:".count)
        if rest.hasPrefix("//") { rest = rest.dropFirst(2) }
        let parts = rest.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        func decode(_ s: Substring) -> String { String(s).removingPercentEncoding ?? String(s) }
        func addresses(_ s: String) -> [String] {
            s.split(whereSeparator: { $0 == "," || $0 == ";" }).map { clean(String($0)) }.filter { !$0.isEmpty }
        }
        /// Zeilenumbrüche in Adressen und Betreff würden Kopfzeilen einschleusen.
        func clean(_ s: String) -> String {
            s.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        }
        var d = MailtoDraft()
        if let first = parts.first { d.to = addresses(decode(first)) }
        if parts.count == 2 {
            for pair in parts[1].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard kv.count == 2 else { continue }
                let value = decode(kv[1])
                switch kv[0].lowercased() {
                case "to": d.to += addresses(value)
                case "cc": d.cc += addresses(value)
                case "bcc": d.bcc += addresses(value)
                case "subject": d.subject = clean(value)
                case "body": d.body = value.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
                default: break
                }
            }
        }
        return d
    }
}

/// Eine geöffnete `.eml`-Datei.
struct OpenedEML: Identifiable {
    var id = UUID()
    var fileName: String
    var header: MailHeaderInfo
    var parsed: ParsedMessage

    static func read(_ url: URL) -> OpenedEML? {
        guard let data = try? Data(contentsOf: url), data.count < 100_000_000 else { return nil }
        let bytes = Array(data)
        let header = MIME.headerInfo(MIME.splitHeadBody(bytes).head)
        return OpenedEML(fileName: url.lastPathComponent, header: header, parsed: MIME.extract(MIME.parse(bytes)))
    }
}

/// Von außen kommende Aufträge: `mailto:`-Links, `.eml`-Dateien, Dienste-Menü („Mit MailPilot senden“).
@MainActor
final class ExternalOpen: ObservableObject {
    static let shared = ExternalOpen()
    @Published var eml: OpenedEML?
    /// Meldung an den Nutzer, wenn ein Auftrag nicht ausgeführt werden konnte (z. B. noch kein Konto).
    @Published var notice: String?

    func handle(_ urls: [URL]) {
        for url in urls {
            if url.scheme?.lowercased() == "mailto" {
                if let d = MailtoURL.parse(url) { compose(to: d.to, cc: d.cc, bcc: d.bcc, subject: d.subject, body: d.body, attachments: []) }
            } else if url.scheme?.lowercased() == "mailpilot" {
                if let id = PlannerDraft.messageId(fromLink: url) { Engine.shared.openMessage(messageId: id) }
            } else if url.isFileURL {
                if url.pathExtension.lowercased() == "eml" {
                    if let m = OpenedEML.read(url) { eml = m; show() } else { notice = "„\(url.lastPathComponent)“ konnte nicht gelesen werden." ; show() }
                } else {
                    compose(to: [], cc: [], bcc: [], subject: "", body: "", attachments: [url])
                }
            }
        }
    }

    /// Öffnet das Verfassen-Fenster im Postfach mit dem Konto des gewählten Ordners (sonst dem ersten Konto).
    func compose(to: [String], cc: [String], bcc: [String], subject: String, body: String, attachments: [URL]) {
        let accounts = Engine.shared.settings.clientAccounts
        let model = ClientModel.shared
        let chosen = model.selectedFolder.flatMap { f in accounts.first { $0.id.uuidString == f.account } } ?? accounts.first
        guard let account = chosen else {
            notice = "Zum Schreiben braucht MailPilot ein verbundenes Konto (Postfach → Konto hinzufügen)."
            show()
            return
        }
        var draft = ComposeDraft(accountID: account.id)
        draft.to = to.joined(separator: ", ")
        draft.cc = cc.joined(separator: ", ")
        draft.bcc = bcc.joined(separator: ", ")
        draft.subject = subject
        draft.body = body
        for url in attachments {
            guard let data = try? Data(contentsOf: url) else { continue }
            let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            draft.attachments.append(OutgoingAttachment(name: url.lastPathComponent, mime: mime, data: data))
        }
        model.pendingCompose = draft
        show()
        Engine.shared.requestedSidebar = .mailbox
    }

    private func show() {
        Engine.shared.openDashboard?()
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Dienste-Menü: Dateien oder Text markieren → Dienste → „Mit MailPilot senden“.
final class MailServiceProvider: NSObject {
    @objc func composeFromPasteboard(_ pboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let files = (pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        let text = pboard.string(forType: .string) ?? ""
        Task { @MainActor in
            ExternalOpen.shared.compose(to: [], cc: [], bcc: [], subject: files.count == 1 ? files[0].deletingPathExtension().lastPathComponent : "",
                                        body: files.isEmpty ? text : "", attachments: files)
        }
    }
}

/// Standardprogramm für `mailto:` und `.eml` abfragen und festlegen.
enum DefaultMailApp {
    static var bundleURL: URL { Bundle.main.bundleURL }
    static let emlType = UTType(filenameExtension: "eml") ?? .emailMessage

    static func current(forScheme scheme: String) -> URL? {
        URL(string: "\(scheme):x@example.org").flatMap { NSWorkspace.shared.urlForApplication(toOpen: $0) }
    }

    static func currentForEML() -> URL? { NSWorkspace.shared.urlForApplication(toOpen: emlType) }

    static var isDefaultForMailto: Bool { current(forScheme: "mailto")?.standardizedFileURL == bundleURL.standardizedFileURL }
    static var isDefaultForEML: Bool { currentForEML()?.standardizedFileURL == bundleURL.standardizedFileURL }

    static func name(of url: URL?) -> String {
        guard let url else { return "unbekannt" }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    /// macOS fragt dabei selbst nach einer Bestätigung. Rückgabe: Fehlertext oder `nil`.
    static func makeDefault() async -> String? {
        guard Bundle.main.bundleIdentifier != nil, bundleURL.pathExtension == "app" else { return "Das geht nur aus der gebauten App (MailPilot.app), nicht beim Start aus dem Entwicklungsordner." }
        do {
            try await NSWorkspace.shared.setDefaultApplication(at: bundleURL, toOpenURLsWithScheme: "mailto")
            try await NSWorkspace.shared.setDefaultApplication(at: bundleURL, toOpen: emlType)
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

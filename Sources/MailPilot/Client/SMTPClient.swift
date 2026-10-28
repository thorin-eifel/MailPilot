import Foundation

enum SMTPSecurity: String, Codable, Hashable {
    /// Unverschlüsselt – nur für Tests gegen einen lokalen Server.
    case none
    /// Klartext beginnen, dann mit STARTTLS auf TLS wechseln (Port 587, iCloud).
    case startTLS
    /// Sofort TLS (Port 465).
    case tls
}

struct SMTPConfig: Hashable {
    var host: String
    var port: UInt16 = 587
    var security: SMTPSecurity = .startTLS
}

enum SMTPError: LocalizedError {
    case connection(String)
    case timeout
    case auth(String)
    case rejected(String)
    case server(String)

    var errorDescription: String? {
        switch self {
        case .connection(let m): return "Verbindung zum Postausgangsserver fehlgeschlagen: \(m)"
        case .timeout: return "Zeitüberschreitung beim Postausgangsserver."
        case .auth(let m): return "Anmeldung am Postausgangsserver fehlgeschlagen: \(m)"
        case .rejected(let m): return "Der Server hat einen Empfänger abgelehnt: \(m)"
        case .server(let m): return "Der Postausgangsserver meldet: \(m)"
        }
    }
}

/// Blockierende SMTP-Sitzung auf CFStream-Basis (STARTTLS lässt sich mit NWConnection nicht nachträglich einschalten).
/// Läuft immer auf einer Hintergrund-Queue.
final class SMTPSession {
    private let config: SMTPConfig
    private let input: InputStream
    private let output: OutputStream
    private var buffer: [UInt8] = []
    private let ioTimeout: TimeInterval = 30

    init(_ config: SMTPConfig) throws {
        self.config = config
        var r: Unmanaged<CFReadStream>?
        var w: Unmanaged<CFWriteStream>?
        CFStreamCreatePairWithSocketToHost(nil, config.host as CFString, UInt32(config.port), &r, &w)
        guard let r, let w else { throw SMTPError.connection("Socket konnte nicht angelegt werden") }
        input = r.takeRetainedValue() as InputStream
        output = w.takeRetainedValue() as OutputStream
        if config.security == .tls { secure() }
        input.open()
        output.open()
    }

    deinit {
        input.close()
        output.close()
    }

    /// TLS einschalten; Zertifikatskette und Hostname werden geprüft.
    private func secure() {
        let level = StreamSocketSecurityLevel.negotiatedSSL
        input.setProperty(level, forKey: .socketSecurityLevelKey)
        output.setProperty(level, forKey: .socketSecurityLevelKey)
        let settings: [String: Any] = [kCFStreamSSLPeerName as String: config.host, kCFStreamSSLValidatesCertificateChain as String: true]
        input.setProperty(settings, forKey: Stream.PropertyKey(rawValue: kCFStreamPropertySSLSettings as String))
        output.setProperty(settings, forKey: Stream.PropertyKey(rawValue: kCFStreamPropertySSLSettings as String))
    }

    // MARK: Ein- und Ausgabe

    private func failure(_ stream: Stream) -> SMTPError? {
        if stream.streamStatus == .error { return .connection(stream.streamError?.localizedDescription ?? "Fehler") }
        if stream.streamStatus == .closed || stream.streamStatus == .atEnd { return .connection("Der Server hat die Verbindung beendet.") }
        return nil
    }

    private func fill() throws {
        let deadline = Date().addingTimeInterval(ioTimeout)
        while !input.hasBytesAvailable {
            if let e = failure(input) { throw e }
            if Date() > deadline { throw SMTPError.timeout }
            usleep(5_000)
        }
        var chunk = [UInt8](repeating: 0, count: 16_384)
        let n = input.read(&chunk, maxLength: chunk.count)
        if n < 0 { throw SMTPError.connection(input.streamError?.localizedDescription ?? "Lesefehler") }
        if n == 0 { throw SMTPError.connection("Der Server hat die Verbindung beendet.") }
        buffer.append(contentsOf: chunk[0..<n])
    }

    private func write(_ data: Data) throws {
        let bytes = [UInt8](data)
        var offset = 0
        let deadline = Date().addingTimeInterval(ioTimeout + Double(bytes.count) / 200_000)
        while offset < bytes.count {
            if output.hasSpaceAvailable {
                let n = bytes.withUnsafeBufferPointer { output.write($0.baseAddress! + offset, maxLength: bytes.count - offset) }
                if n < 0 { throw SMTPError.connection(output.streamError?.localizedDescription ?? "Schreibfehler") }
                offset += n
            } else {
                if let e = failure(output) { throw e }
                if Date() > deadline { throw SMTPError.timeout }
                usleep(5_000)
            }
        }
    }

    struct Reply {
        var code: Int
        var lines: [String]
        var text: String { lines.joined(separator: " ") }
    }

    /// Eine (ggf. mehrzeilige) Antwort lesen.
    private func reply() throws -> Reply {
        var lines: [String] = []
        while true {
            guard let nl = buffer.firstIndex(of: 10) else { try fill(); continue }
            var line = Array(buffer[0..<nl])
            buffer.removeFirst(nl + 1)
            if line.last == 13 { line.removeLast() }
            let text = String(decoding: line, as: UTF8.self)
            guard text.count >= 3, let code = Int(text.prefix(3)) else { throw SMTPError.server(text) }
            lines.append(text.count > 4 ? String(text.dropFirst(4)) : "")
            if text.count == 3 || text[text.index(text.startIndex, offsetBy: 3)] == " " { return Reply(code: code, lines: lines) }
        }
    }

    private func command(_ text: String, expect: Set<Int>) throws -> Reply {
        try write(Data((text + "\r\n").utf8))
        let r = try reply()
        guard expect.contains(r.code) else { throw SMTPError.server("\(r.code) \(r.text)") }
        return r
    }

    // MARK: Versand

    /// Verbinden, anmelden und eine Nachricht senden.
    func send(user: String, password: String, from: String, recipients: [String], message: Data) throws {
        let greeting = try reply()
        guard greeting.code == 220 else { throw SMTPError.server("\(greeting.code) \(greeting.text)") }
        var ehlo = try command("EHLO mailpilot.local", expect: [250])
        if config.security == .startTLS {
            guard ehlo.lines.contains(where: { $0.uppercased() == "STARTTLS" }) else { throw SMTPError.server("Der Server bietet kein STARTTLS an.") }
            _ = try command("STARTTLS", expect: [220])
            secure()
            buffer.removeAll()
            ehlo = try command("EHLO mailpilot.local", expect: [250])
        }
        let auth = ehlo.lines.first { $0.uppercased().hasPrefix("AUTH ") }?.uppercased() ?? ""
        if !password.isEmpty {
            do {
                if auth.contains("PLAIN") {
                    let token = Data(("\0" + user + "\0" + password).utf8).base64EncodedString()
                    _ = try command("AUTH PLAIN \(token)", expect: [235])
                } else if auth.contains("LOGIN") {
                    _ = try command("AUTH LOGIN", expect: [334])
                    _ = try command(Data(user.utf8).base64EncodedString(), expect: [334])
                    _ = try command(Data(password.utf8).base64EncodedString(), expect: [235])
                } else {
                    throw SMTPError.auth("Der Server bietet kein unterstütztes Anmeldeverfahren an.")
                }
            } catch SMTPError.server(let m) {
                throw SMTPError.auth(m)
            }
        }
        _ = try command("MAIL FROM:<\(from)>", expect: [250])
        for r in recipients {
            do { _ = try command("RCPT TO:<\(r)>", expect: [250, 251]) }
            catch SMTPError.server(let m) { throw SMTPError.rejected("\(r): \(m)") }
        }
        _ = try command("DATA", expect: [354])
        try write(Self.dotStuffed(message))
        let done = try reply()
        guard done.code == 250 else { throw SMTPError.server("\(done.code) \(done.text)") }
        _ = try? command("QUIT", expect: [221])
    }

    /// Zeilen, die mit „.“ beginnen, verdoppeln; Abschluss mit „<CRLF>.<CRLF>“.
    static func dotStuffed(_ message: Data) -> Data {
        var out = Data()
        var atLineStart = true
        for b in message {
            if atLineStart, b == 46 { out.append(46) }
            out.append(b)
            atLineStart = b == 10
        }
        if !(out.suffix(2) == Data([13, 10])) { out.append(contentsOf: [13, 10]) }
        out.append(contentsOf: Array(".\r\n".utf8))
        return out
    }
}

enum SMTPClient {
    static func send(_ config: SMTPConfig, user: String, password: String, from: String, recipients: [String], message: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let session = try SMTPSession(config)
                    try session.send(user: user, password: password, from: from, recipients: recipients, message: message)
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }
}

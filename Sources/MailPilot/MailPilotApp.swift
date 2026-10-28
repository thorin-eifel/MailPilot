import SwiftUI

@main
enum EntryPoint {
    static func main() {
        if CommandLine.arguments.contains("--selftest") {
            SelfTest.run()
        } else {
            MailPilotApp.main()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Engine.shared.start()
    }
}

struct MailPilotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var engine = Engine.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(engine)
        } label: {
            let count = engine.needsReply.count
            Image(systemName: engine.isRunning ? "envelope.arrow.triangle.branch" : (count > 0 ? "envelope.badge" : "envelope"))
            if count > 0 { Text("\(count)") }
        }
        .menuBarExtraStyle(.window)

        Window("MailPilot", id: "dashboard") {
            DashboardView()
                .environmentObject(engine)
                .frame(minWidth: 1050, minHeight: 620)
        }
        .defaultLaunchBehavior(.presented)
    }
}

/// Kommandozeilentest: liest Mail ohne Änderungen und prüft die Claude-CLI.
enum SelfTest {
    static func run() {
        let sema = DispatchSemaphore(value: 0)
        Task.detached {
            let bridge = MailBridge()
            do {
                let start = Date()
                let r = try await bridge.fetch(since: Date().addingTimeInterval(-86400), known: [], maxNew: 5, includeSent: true, contentLimit: 200)
                print("Mail: \(r.messages.count) Nachrichten gelesen (+\(r.remaining) weitere) in \(String(format: "%.1f", Date().timeIntervalSince(start))) s")
                print("Eigene Adressen: \(r.myAddresses.count)")
                for m in r.messages {
                    print("  - \(m.isSent ? "OUT" : "IN ") \(m.account)/\(m.mailbox) refs=\(m.references.count) irt=\(m.inReplyTo != nil) content=\(m.content.count)")
                }
            } catch {
                print("Mail-Fehler: \(error.localizedDescription)")
            }
            let s = AppSettings.load(from: Paths.settings)
            if let path = ClaudeClient.locate(preferred: s.claudePath) {
                let client = ClaudeClient(executable: path, model: s.model)
                do {
                    print("Claude: \(try await client.ping())")
                } catch {
                    print("Claude-Fehler: \(error.localizedDescription)")
                }
                if CommandLine.arguments.contains("--batch") {
                    do {
                        let store = try Store()
                        let msgs = Array(try store.unprocessedMessages(limit: 10))
                        let start = Date()
                        let r = try await client.classifyBatch(msgs, settings: s, myAddresses: [])
                        print("Paket: \(r.count)/\(msgs.count) in \(Int(Date().timeIntervalSince(start))) s")
                    } catch {
                        print("Paket-Fehler: \(error.localizedDescription)")
                    }
                }
                if CommandLine.arguments.contains("--analyze") {
                    await analyze(client: client, settings: s)
                }
            } else {
                print("Claude: CLI nicht gefunden")
            }
            sema.signal()
        }
        sema.wait()
    }

    /// Analysiert drei aktuelle Mails mit einer temporären Datenbank, ohne Mail zu verändern.
    private static func analyze(client: ClaudeClient, settings: AppSettings) async {
        do {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mailpilot-selftest-\(UUID()).sqlite")
            let store = try Store(path: tmp)
            let r = try await MailBridge().fetch(since: Date().addingTimeInterval(-86400), known: [], maxNew: 3, includeSent: false)
            for raw in r.messages { try store.insert(raw, myAddresses: Set(r.myAddresses)) }
            for m in try store.unprocessedMessages(limit: 3) {
                let start = Date()
                let key = try store.resolveThreadKey(for: m)
                let a = try await client.analyze(message: m, thread: nil, history: [], settings: settings, myAddresses: r.myAddresses)
                print("  Analyse (\(String(format: "%.0f", Date().timeIntervalSince(start))) s): Kategorie=\(a.category) Priorität=\(a.priority.rawValue) Status=\(a.thread_status.rawValue) Antwort=\(a.needs_reply) Entwurf=\(a.reply_draft != nil) Frist=\(a.due_date ?? "-") Thread=\(key == m.messageId ? "neu" : "verknüpft")")
            }
            try? FileManager.default.removeItem(at: tmp)
        } catch {
            print("Analyse-Fehler: \(error.localizedDescription)")
        }
    }
}

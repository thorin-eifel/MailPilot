import SwiftUI

@main
enum EntryPoint {
    static func main() {
        if CommandLine.arguments.contains("--selftest-rules") {
            RulesSelfTest.run()
        } else if CommandLine.arguments.contains("--selftest-sync") {
            RulesSelfTest.runSync()
        } else if CommandLine.arguments.contains("--selftest") {
            SelfTest.run()
        } else if let i = CommandLine.arguments.firstIndex(of: "--render"), i + 1 < CommandLine.arguments.count {
            MainActor.assumeIsolated { RenderPreview.run(to: CommandLine.arguments[i + 1]) }
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
            Image(nsImage: MenuBarIcon.image(busy: engine.isRunning))
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
                let accounts = try await bridge.listAccounts()
                print("Konten: " + accounts.map { "\($0.name) (\($0.inboxCount))" }.joined(separator: ", "))
                let start = Date()
                let r = try await bridge.fetch(since: Date().addingTimeInterval(-86400), accounts: accounts.map(\.name), known: [],
                                               maxNew: 5, includeSent: true, contentLimit: 200)
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
                        let msgs = Array(try store.unprocessedMessages(limit: 10, accounts: try await MailBridge().listAccounts().map(\.name)))
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
            let bridge = MailBridge()
            let accounts = try await bridge.listAccounts().map(\.name)
            let r = try await bridge.fetch(since: Date().addingTimeInterval(-86400), accounts: accounts, known: [], maxNew: 3, includeSent: false)
            for raw in r.messages { try store.insert(raw, myAddresses: Set(r.myAddresses)) }
            for m in try store.unprocessedMessages(limit: 3, accounts: accounts) {
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

/// Rendert die wichtigsten Ansichten als PNG (hell und dunkel) – zur Sichtprüfung ohne Bildschirmaufnahme.
/// Liest nur; startet weder Scan noch Zeitplan.
@MainActor
enum RenderPreview {
    static func run(to dir: String) {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let engine = Engine.shared
        Task { @MainActor in
            await engine.refreshAccounts()
            engine.reload()
            engine.loadPreviewSamples()
            let out = URL(fileURLWithPath: dir)
            try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            let thread = engine.threads.first { $0.draft != nil } ?? engine.threads.first { $0.messageCount > 1 } ?? engine.threads.first
            for dark in [false, true] {
                let suffix = dark ? "dark" : "light"
                render(MenuBarView(), size: NSSize(width: 360, height: 420), dark: dark, to: out.appendingPathComponent("menubar-\(suffix).png"))
                render(DashboardView(initial: .all), size: NSSize(width: 1240, height: 760), dark: dark, to: out.appendingPathComponent("dashboard-\(suffix).png"))
                render(DashboardView(initial: .briefing), size: NSSize(width: 1240, height: 760), dark: dark, to: out.appendingPathComponent("briefing-\(suffix).png"))
                render(DashboardView(initial: .rules), size: NSSize(width: 1240, height: 1500), dark: dark, to: out.appendingPathComponent("rules-\(suffix).png"))
                render(DashboardView(initial: .settings), size: NSSize(width: 1240, height: 900), dark: dark, to: out.appendingPathComponent("settings-\(suffix).png"))
                if let thread {
                    render(ThreadDetailView(thread: thread), size: NSSize(width: 760, height: 900), dark: dark, to: out.appendingPathComponent("thread-\(suffix).png"))
                }
            }
            print("Gerendert nach \(out.path)")
            exit(0)
        }
        app.run()
    }

    private static func render<V: View>(_ view: V, size: NSSize, dark: Bool, to url: URL) {
        let host = NSHostingView(rootView: view.environmentObject(Engine.shared))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}

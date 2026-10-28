import Foundation

/// Ein Zeitfenster des Abo-Limits (aus den Rate-Limit-Meldungen der Claude-CLI).
struct PlanWindow: Codable, Equatable {
    /// 0…1
    var utilization: Double
    var resetsAt: Date?
    var status: String

    var isCurrent: Bool { resetsAt.map { $0 > Date() } ?? true }
    var percent: Int { Int((utilization * 100).rounded()) }
}

struct PlanLimits: Codable, Equatable {
    var fiveHour: PlanWindow?
    var sevenDay: PlanWindow?
    var updatedAt: Date

    /// Liest `rate_limit_info` aus der stream-json-Ausgabe der CLI.
    static func parse(_ info: [String: Any]) -> PlanLimits? {
        func window(_ d: [String: Any]?) -> PlanWindow? {
            guard let d, let u = d["utilization"] as? Double else { return nil }
            return PlanWindow(utilization: u, resetsAt: (d["resetsAt"] as? Double).map { Date(timeIntervalSince1970: $0) },
                              status: d["status"] as? String ?? "")
        }
        let windows = info["unifiedWindows"] as? [String: Any]
        var five = window(windows?["five_hour"] as? [String: Any])
        var seven = window(windows?["seven_day"] as? [String: Any])
        // Ohne Fensterliste gilt der gemeldete Typ.
        if five == nil, seven == nil, let type = info["rateLimitType"] as? String, let w = window(info) {
            if type == "five_hour" { five = w } else if type == "seven_day" { seven = w }
        }
        guard five != nil || seven != nil else { return nil }
        return PlanLimits(fiveHour: five, sevenDay: seven, updatedAt: Date())
    }
}

struct UsageRecord {
    var date = Date()
    var purpose: String
    var model: String
    var inputTokens: Int
    var outputTokens: Int
    var cacheReadTokens: Int
    var costUSD: Double
    var durationMs: Int
    var ok: Bool
    var interactive: Bool
}

struct UsageSummary: Equatable {
    var calls = 0
    var failures = 0
    var inputTokens = 0
    var outputTokens = 0
    var cacheReadTokens = 0
    var costUSD = 0.0
    var avgSeconds = 0.0

    var totalTokens: Int { inputTokens + outputTokens }
}

struct UsageByPurpose: Identifiable, Equatable {
    var purpose: String
    var calls: Int
    var tokens: Int
    var id: String { purpose }
}

struct UsageByDay: Identifiable, Equatable {
    var day: Date
    var calls: Int
    var tokens: Int
    var id: Date { day }
}

/// Schutz vor zu hoher Last auf das Abo: pausiert die automatische Claude-Arbeit, wenn die Grenzen erreicht sind.
struct UsageGuardSettings: Equatable {
    var enabled = true
    var fiveHourLimit = 0.9
    var sevenDayLimit = 0.9
    var maxCallsPerDay = 0
}

/// Zentrale Stelle für Claude-Nutzung: protokolliert Aufrufe, merkt sich die Abo-Auslastung und entscheidet,
/// ob automatische Aufrufe derzeit pausieren sollen. Vom Nutzer ausgelöste Aufrufe laufen immer.
final class UsageMonitor: @unchecked Sendable {
    static let shared = UsageMonitor()

    private let lock = NSLock()
    private var store: Store?
    private var limits: PlanLimits?
    private var blockedUntil: Date?
    private var guardSettings = UsageGuardSettings()
    var onChange: (@Sendable () -> Void)?

    func configure(store: Store) {
        lock.lock(); defer { lock.unlock() }
        self.store = store
        if let json = store.value("planLimits"), let l = try? JSONDecoder().decode(PlanLimits.self, from: Data(json.utf8)) { limits = l }
        if let t = store.value("claudeBlockedUntil").flatMap(Double.init) { blockedUntil = Date(timeIntervalSince1970: t) }
    }

    func update(_ s: UsageGuardSettings) {
        lock.lock(); defer { lock.unlock() }
        guardSettings = s
    }

    var currentLimits: PlanLimits? {
        lock.lock(); defer { lock.unlock() }
        return limits
    }

    /// Grund, warum automatische Aufrufe gerade pausieren; `nil` = frei.
    func blockReason(now: Date = Date()) -> String? {
        lock.lock(); defer { lock.unlock() }
        let time: (Date) -> String = { $0.formatted(date: .omitted, time: .shortened) }
        if let until = blockedUntil, until > now { return "Claude-Limit erreicht – pausiert bis \(time(until))" }
        guard guardSettings.enabled else { return capReason(now: now) }
        if let w = limits?.fiveHour, w.isCurrent, w.utilization >= guardSettings.fiveHourLimit {
            return "5-Stunden-Limit bei \(w.percent) % – Pause bis \(w.resetsAt.map(time) ?? "zum Zurücksetzen")"
        }
        if let w = limits?.sevenDay, w.isCurrent, w.utilization >= guardSettings.sevenDayLimit {
            return "7-Tage-Limit bei \(w.percent) % – Pause bis \(w.resetsAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "zum Zurücksetzen")"
        }
        return capReason(now: now)
    }

    private func capReason(now: Date) -> String? {
        guard guardSettings.maxCallsPerDay > 0, let store else { return nil }
        let n = store.autoCallsToday(now: now)
        return n >= guardSettings.maxCallsPerDay ? "Tageslimit von \(guardSettings.maxCallsPerDay) automatischen Aufrufen erreicht" : nil
    }

    func record(_ r: UsageRecord, limits newLimits: PlanLimits?) {
        lock.lock()
        if let newLimits {
            limits = newLimits
            if let data = try? JSONEncoder().encode(newLimits) { store?.setValue(String(decoding: data, as: UTF8.self), for: "planLimits") }
        }
        let store = store
        let callback = onChange
        lock.unlock()
        try? store?.addUsage(r)
        callback?()
    }

    /// Die CLI meldet ein erreichtes Limit: bis zum Zurücksetzen des Fensters (sonst 30 Minuten) keine automatischen Aufrufe.
    func noteRateLimited(now: Date = Date()) {
        lock.lock()
        var until = now.addingTimeInterval(30 * 60)
        if let w = limits?.fiveHour, w.utilization >= 0.99, let r = w.resetsAt, r > now { until = r }
        else if let w = limits?.sevenDay, w.utilization >= 0.99, let r = w.resetsAt, r > now { until = r }
        blockedUntil = until
        store?.setValue(String(until.timeIntervalSince1970), for: "claudeBlockedUntil")
        let callback = onChange
        lock.unlock()
        callback?()
    }

    func clearBlock() {
        lock.lock()
        blockedUntil = nil
        store?.setValue(nil, for: "claudeBlockedUntil")
        lock.unlock()
        onChange?()
    }
}

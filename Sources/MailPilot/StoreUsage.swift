import Foundation

extension Store {
    func addUsage(_ r: UsageRecord) throws {
        try db.exec("""
            INSERT INTO usage (ts, purpose, model, input_tokens, output_tokens, cache_read_tokens, cost_usd, duration_ms, ok, interactive)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [r.date, r.purpose, r.model, r.inputTokens, r.outputTokens, r.cacheReadTokens, r.costUSD, r.durationMs, r.ok, r.interactive])
    }

    /// Automatische (nicht vom Nutzer ausgelöste) Aufrufe seit Mitternacht.
    func autoCallsToday(now: Date = Date()) -> Int {
        let start = Calendar.current.startOfDay(for: now)
        return ((try? db.query("SELECT COUNT(*) AS n FROM usage WHERE ts >= ? AND interactive = 0", [start]))?.first?.int("n")) ?? 0
    }

    func usageSummary(since: Date) -> UsageSummary {
        guard let r = (try? db.query("""
            SELECT COUNT(*) AS n, SUM(ok = 0) AS fail, SUM(input_tokens) AS i, SUM(output_tokens) AS o, SUM(cache_read_tokens) AS c,
                   SUM(cost_usd) AS cost, AVG(duration_ms) AS ms FROM usage WHERE ts >= ?
            """, [since]))?.first else { return UsageSummary() }
        return UsageSummary(calls: r.int("n"), failures: r.int("fail"), inputTokens: r.int("i"), outputTokens: r.int("o"),
                            cacheReadTokens: r.int("c"), costUSD: r.double("cost"), avgSeconds: r.double("ms") / 1000)
    }

    func usageByPurpose(since: Date) -> [UsageByPurpose] {
        ((try? db.query("""
            SELECT purpose, COUNT(*) AS n, SUM(input_tokens + output_tokens) AS t FROM usage WHERE ts >= ?
            GROUP BY purpose ORDER BY n DESC
            """, [since])) ?? []).map { UsageByPurpose(purpose: $0.string("purpose") ?? "Sonstiges", calls: $0.int("n"), tokens: $0.int("t")) }
    }

    /// Aufrufe je Tag der letzten `days` Tage (auch Tage ohne Aufrufe).
    func usageByDay(days: Int, now: Date = Date()) -> [UsageByDay] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        guard let first = cal.date(byAdding: .day, value: -(days - 1), to: today) else { return [] }
        let rows = (try? db.query("""
            SELECT CAST((ts - ?) / 86400 AS INTEGER) AS d, COUNT(*) AS n, SUM(input_tokens + output_tokens) AS t FROM usage
            WHERE ts >= ? GROUP BY d
            """, [first.timeIntervalSince1970, first])) ?? []
        var byIndex: [Int: (Int, Int)] = [:]
        for r in rows { byIndex[r.int("d")] = (r.int("n"), r.int("t")) }
        return (0..<days).compactMap { i in
            guard let day = cal.date(byAdding: .day, value: i, to: first) else { return nil }
            return UsageByDay(day: day, calls: byIndex[i]?.0 ?? 0, tokens: byIndex[i]?.1 ?? 0)
        }
    }
}

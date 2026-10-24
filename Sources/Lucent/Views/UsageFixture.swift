#if DEBUG
import Foundation

/// 仅调试：`-usageFixture YES` 时给明细字段填示例数据，后端还没给数据时先看界面。真实数据有的字段保持不动。
enum UsageFixture {
    static func augment(_ tools: [ToolUsage]) -> [ToolUsage] {
        tools.map { t in
            guard t.tool != .cursor else { return t }
            var u = t
            var r = SeededRNG(t.tool == .claude ? 5 : 17)
            let cal = Calendar.current
            let today = cal.startOfDay(for: Date())
            func split(_ total: Int64) -> TokenCounts {
                TokenCounts(input: total / 300, output: total / 120, cacheRead: total * 96 / 100, cacheWrite: total * 3 / 100)
            }
            if u.daily.isEmpty {
                u.daily = (0..<30).map { DailyUsage(day: cal.date(byAdding: .day, value: $0 - 29, to: today)!) }
            }
            u.daily = u.daily.map { d in
                var d = d
                if d.requests == 0 { d.requests = Int(d.tokens.total / 160_000) }
                if d.cacheSavings == 0 { d.cacheSavings = Double(d.tokens.cacheRead) / 1e6 * 4.5 }
                if d.cacheWrite1h == 0 { d.cacheWrite1h = d.tokens.cacheWrite / 3 }
                return d
            }
            if u.history.isEmpty {
                let old: [DailyUsage] = (0..<335).map { i in
                    let day = cal.date(byAdding: .day, value: i - 364, to: today)!
                    let v = r.next(), used = r.next() > 0.35 && weekdayOK(day, &r)
                    let tok = used ? Int64(v * v * 300_000_000) : 0
                    return DailyUsage(day: day, tokens: split(tok), cost: Double(tok) / 1e6 * 0.32, requests: Int(tok / 160_000))
                }
                u.history = old + u.daily
            }
            if u.hourly.isEmpty {
                u.hourly = u.daily.flatMap { d -> [HourlyUsage] in
                    guard d.tokens.total > 0 else { return [] }
                    let weights: [Double] = (0..<24).map { h in h < 9 ? 0.02 : (h < 12 ? 0.8 : (h < 14 ? 0.4 : (h < 19 ? 1 : (h < 23 ? 1.3 : 0.5)))) }
                    let sum = weights.reduce(0, +)
                    return (0..<24).compactMap { h in
                        let f = weights[h] / sum * (0.6 + r.next() * 0.8)
                        guard f > 0.005 else { return nil }
                        let tok = Int64(Double(d.tokens.total) * f)
                        var tc = split(tok)
                        tc.cacheRead = Int64(Double(tok) * (0.85 + r.next() * 0.13))
                        return HourlyUsage(hour: cal.date(byAdding: .hour, value: h, to: d.day)!, tokens: tc, cost: d.cost * f, requests: max(Int(Double(d.requests) * f), 1))
                    }
                }
            }
            if u.recentRequests.isEmpty {
                let projects = ["Lucent", "web-app", "api-server", "mobile", "scripts"]
                let models = u.models.isEmpty ? ["model"] : u.models.prefix(3).map(\.model)
                var time = Date()
                u.recentRequests = (0..<300).map { i in
                    time = time.addingTimeInterval(-(5 + r.next() * 90))
                    let tok = Int64(20_000 + r.next() * r.next() * 400_000)
                    var tc = split(tok)
                    tc.cacheRead = Int64(Double(tok) * (r.next() > 0.1 ? 0.9 + r.next() * 0.09 : r.next() * 0.3))
                    tc.cacheWrite = tok - tc.cacheRead - tc.input - tc.output
                    return UsageRequest(id: "\(t.tool.rawValue)-\(i)", time: time, tool: t.tool, model: models[Int(r.next() * Double(models.count))],
                                        project: projects[Int(r.next() * r.next() * Double(projects.count))], sessionID: nil,
                                        tokens: tc, cost: Double(tok) / 1e6 * 0.4)
                }
            }
            if u.projects.isEmpty {
                let total = u.last30Tokens.total
                u.projects = [("Lucent", 0.46), ("web-app", 0.27), ("api-server", 0.14), ("mobile", 0.08), ("scripts", 0.05)].map { name, f in
                    ProjectShare(project: name, tool: t.tool, tokens: split(Int64(Double(total) * f)), cost: u.last30Cost * f,
                                 requests: Int(Double(total) * f / 160_000), lastActive: Date().addingTimeInterval(-r.next() * 86400 * 3))
                }
            }
            let provider = t.tool == .claude ? "Anthropic" : "openrouter"
            let names = u.models.isEmpty ? ["model"] : u.models.prefix(4).map(\.model)
            let weights = [0.62, 0.22, 0.11, 0.05].prefix(names.count)
            let wsum = weights.reduce(0, +)
            if u.hourlyDetail.isEmpty {
                u.hourlyDetail = u.hourly.flatMap { h in
                    zip(names, weights).map { name, w in
                        let f = w / wsum
                        var tc = h.tokens
                        tc.input = Int64(Double(tc.input) * f); tc.output = Int64(Double(tc.output) * f)
                        tc.cacheRead = Int64(Double(tc.cacheRead) * f); tc.cacheWrite = Int64(Double(tc.cacheWrite) * f)
                        return UsageBucket(start: h.hour, tool: t.tool, provider: provider, model: name, tokens: tc, cost: h.cost * f,
                                           requests: max(Int(Double(h.requests) * f), 1), cacheSavings: h.cost * f * 4,
                                           cacheWrite1h: tc.cacheWrite / 3, timedOutputTokens: tc.output, timedDurationMs: tc.output * 13)
                    }
                }
            }
            if u.dailyDetail.isEmpty {
                u.dailyDetail = u.history.filter { $0.tokens.total > 0 }.flatMap { d in
                    zip(names, weights).map { name, w in
                        let f = w / wsum
                        var tc = d.tokens
                        tc.input = Int64(Double(tc.input) * f); tc.output = Int64(Double(tc.output) * f)
                        tc.cacheRead = Int64(Double(tc.cacheRead) * f); tc.cacheWrite = Int64(Double(tc.cacheWrite) * f)
                        return UsageBucket(start: d.day, tool: t.tool, provider: provider, model: name, tokens: tc, cost: d.cost * f,
                                           requests: Int(Double(d.requests) * f), cacheSavings: d.cacheSavings * f,
                                           timedOutputTokens: tc.output, timedDurationMs: tc.output * 13)
                    }
                }
            }
            u.recentRequests = u.recentRequests.enumerated().map { i, r in
                var r = r
                if r.provider.isEmpty { r.provider = provider }
                if r.durationMs == nil && i % 4 != 1 { r.durationMs = Int(r.tokens.output * 12 + 900); r.durationIsEstimate = t.tool == .claude }
                return r
            }
            if u.pricing.isEmpty {
                u.pricing = names.map { n in
                    t.tool == .claude
                        ? PricingEntry(model: n, tool: t.tool, input: 5, output: 25, cacheRead: 0.5, cacheWrite5m: 6.25, cacheWrite1h: 10, source: "LiteLLM")
                        : PricingEntry(model: n, tool: t.tool, source: "OpenCode 自带记录（金额 $0）")
                }
            }
            u.models = u.models.map { m in
                var m = m
                if m.detail.total == 0 { m.detail = split(m.tokens); m.detail.cacheRead = m.tokens - m.detail.input - m.detail.output - m.detail.cacheWrite }
                if m.requests == 0 { m.requests = Int(m.tokens / 160_000) }
                return m
            }
            return u
        }
    }

    private static func weekdayOK(_ d: Date, _ r: inout SeededRNG) -> Bool {
        let wd = Calendar.current.component(.weekday, from: d)
        return wd == 1 || wd == 7 ? r.next() > 0.5 : true
    }
}
#endif

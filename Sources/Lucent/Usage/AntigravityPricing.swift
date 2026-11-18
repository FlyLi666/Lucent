import Foundation

// Antigravity 模型定价：对照 aistudio.google.com/docs/pricing 的标准档（美元 / token，costKind = .apiEquivalent）。
// 价按请求发生的时间取，不按「现在」。Carbon / Argon、3.8 Flash 有介绍价截止日期。
// orchestrator 没有单独挂牌价：orchestrator-carbon 按 Carbon 估算、orchestrator-argon 按 Argon 估算。
// 未公开单价的型号与 unknown 保持 $0，不跨家族猜价。

struct AntigravityModelRate: Sendable {
    var input: Double
    var output: Double
    var cacheRead: Double
    var cacheWrite: Double = 0
}

enum AntigravityPricingTable {
    /// 没有截止日期的 Gemini API 标准档（美元 / token；隐式缓存无写入费）
    static let gemini: [String: AntigravityModelRate] = [
        "gemini-3.7-flash": .init(input: 0.75e-6, output: 3.75e-6, cacheRead: 0.075e-6),
        "gemini-3.6-flash": .init(input: 0.75e-6, output: 3.75e-6, cacheRead: 0.075e-6),
        "gemini-3.5-flash": .init(input: 1.50e-6, output: 9.00e-6, cacheRead: 0.15e-6),
        "gemini-3.5-flash-lite": .init(input: 0.30e-6, output: 2.50e-6, cacheRead: 0.03e-6),
        "gemini-3.1-pro-preview": .init(input: 2.00e-6, output: 12.00e-6, cacheRead: 0.20e-6),
        "gemini-3.1-flash-lite": .init(input: 0.25e-6, output: 1.50e-6, cacheRead: 0.025e-6),
        "gemini-3.1-flash-lite-preview": .init(input: 0.25e-6, output: 1.50e-6, cacheRead: 0.025e-6),
        "gemini-3-pro-preview": .init(input: 2.00e-6, output: 12.00e-6, cacheRead: 0.20e-6),
        "gemini-3-flash-preview": .init(input: 0.50e-6, output: 3.00e-6, cacheRead: 0.05e-6),
        "gemini-2.5-pro": .init(input: 1.25e-6, output: 10.00e-6, cacheRead: 0.125e-6),
        "gemini-2.5-flash": .init(input: 0.30e-6, output: 2.50e-6, cacheRead: 0.03e-6),
        "gemini-2.5-flash-lite": .init(input: 0.10e-6, output: 0.40e-6, cacheRead: 0.01e-6),
        "gemini-2.0-flash": .init(input: 0.10e-6, output: 0.40e-6, cacheRead: 0.025e-6),
    ]

    /// -xhigh 必须排在 -high 前面，否则 `…-xhigh` 会被截成 `…-x`。
    /// -tiered 是原生库 field 19 的内部名（如 gemini-3.8-flash-tiered），和公开的同一档价。
    /// -orchestrator 挂在家族名后面时（gemini-4-hydrogen-orchestrator）没有单独价，按家族估算。
    private static let effortSuffixes = ["-xhigh", "-minimal", "-medium", "-high", "-low", "-thinking", "-orchestrator", "-tiered"]

    /// Carbon / Argon 介绍价到 2026-11-30 止（UTC），2026-12-01 起挂牌价。
    private static let carbonArgonListStarts = utcMidnight(2026, 12, 1)
    /// 3.8 Flash 介绍价到 2026-12-31 止（UTC），2027-01-01 起挂牌价。
    private static let flash38ListStarts = utcMidnight(2027, 1, 1)

    private static let introCarbonArgon = AntigravityModelRate(input: 2.00e-6, output: 10.00e-6, cacheRead: 0.10e-6)
    private static let listCarbonArgon = AntigravityModelRate(input: 4.00e-6, output: 20.00e-6, cacheRead: 0.20e-6)
    private static let hydrogen = AntigravityModelRate(input: 1.50e-6, output: 7.50e-6, cacheRead: 0.075e-6)
    private static let introFlash38 = AntigravityModelRate(input: 0.75e-6, output: 3.75e-6, cacheRead: 0.075e-6)
    private static let listFlash38 = AntigravityModelRate(input: 1.50e-6, output: 7.50e-6, cacheRead: 0.15e-6)

    /// 把 `Model Selection` 里的显示名（如 `Gemini 3.8 Flash (High)`）转成模型 ID（`gemini-3.8-flash-high`）；已是 ID 的原样保留。
    static func modelID(of display: String) -> String {
        let trimmed = display.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains(" ") else { return trimmed }
        return trimmed
            .lowercased()
            .replacingOccurrences(of: " (", with: "-")
            .replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: ")", with: "")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: "-")
    }

    static func rateWithSource(for rawModel: String, at requestTime: Date = Date()) -> (rate: AntigravityModelRate?, source: String) {
        let cleaned = cleanModelID(rawModel)
        if isPlaceholder(cleaned) {
            return (nil, L("模型未知，金额记 $0"))
        }

        let candidates = pricingCandidates(for: cleaned)
        for candidate in candidates {
            if let hit = datedGeminiRate(id: candidate, at: requestTime) { return (hit, "Gemini API") }
            if let hit = gemini[candidate] { return (hit, "Gemini API") }
            if let claude = ClaudePricingTable.bundled[candidate] {
                return (.init(input: claude.input, output: claude.output, cacheRead: claude.cacheRead, cacheWrite: claude.cacheWrite5m), "LiteLLM")
            }
            if let codex = CodexPricingTable.bundled[candidate] {
                return (.init(input: codex.input, output: codex.output, cacheRead: codex.cacheRead, cacheWrite: 0), "LiteLLM")
            }
        }

        // 如 gemini-3.1-pro -> gemini-3.1-pro-preview；至少两段连字符才允许前缀匹配，避免 gemini-4 误命中任意子型号
        for candidate in candidates where candidate.hasPrefix("gemini-") && candidate.filter({ $0 == "-" }).count >= 2 {
            let prefix = candidate + "-"
            if let key = gemini.keys.filter({ $0.hasPrefix(prefix) }).min(by: { $0.count < $1.count }),
               let hit = gemini[key] {
                return (hit, "Gemini API")
            }
        }

        return (nil, L("暂无公开 API 定价"))
    }

    /// Carbon、Argon、Hydrogen、3.8 Flash 的价随请求时间变，不能写进一张死表。
    private static func datedGeminiRate(id: String, at requestTime: Date) -> AntigravityModelRate? {
        switch id {
        case "gemini-4-carbon", "gemini-4-argon":
            return requestTime < carbonArgonListStarts ? introCarbonArgon : listCarbonArgon
        case "gemini-4-hydrogen":
            return hydrogen
        case "gemini-3.8-flash":
            return requestTime < flash38ListStarts ? introFlash38 : listFlash38
        default:
            return nil
        }
    }

    private static func cleanModelID(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let slash = s.lastIndex(of: "/") { s = String(s[s.index(after: slash)...]) }
        if let colon = s.firstIndex(of: ":") { s = String(s[..<colon]) }
        return s.replacingOccurrences(of: "@", with: "-").lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isPlaceholder(_ model: String) -> Bool {
        model.isEmpty || model == "unknown" || model == "none" || model == "null"
    }

    private static func pricingCandidates(for cleaned: String) -> [String] {
        var result: [String] = []
        var queue: [String] = [cleaned]
        while let current = queue.first {
            queue.removeFirst()
            guard !current.isEmpty, !result.contains(current) else { continue }
            result.append(current)

            // orchestrator-carbon / orchestrator-argon 没有自己的价，按底座模型估算。
            switch current {
            case "orchestrator-carbon": queue.append("gemini-4-carbon")
            case "orchestrator-argon": queue.append("gemini-4-argon")
            default: break
            }
            if let stripped = stripDateSuffix(current) { queue.append(stripped) }
            if let stripped = stripEffortSuffix(current) { queue.append(stripped) }
            if current.hasPrefix("claude-"), current.contains(".") {
                queue.append(ClaudePricingTable.normalizeAlias(current))
            }
        }
        return result
    }

    private static func stripDateSuffix(_ model: String) -> String? {
        for pattern in [#"-\d{4}-\d{2}-\d{2}$"#, #"-\d{8}$"#] {
            if let range = model.range(of: pattern, options: .regularExpression) {
                let base = String(model[model.startIndex..<range.lowerBound])
                if !base.isEmpty { return base }
            }
        }
        return nil
    }

    private static func stripEffortSuffix(_ model: String) -> String? {
        for suffix in effortSuffixes where model.hasSuffix(suffix) {
            let base = String(model.dropLast(suffix.count))
            if !base.isEmpty { return base }
        }
        return nil
    }

    private static func utcMidnight(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: DateComponents(year: year, month: month, day: day)) ?? .distantFuture
    }
}

enum AntigravityCost {
    /// Antigravity 导出的 input_tokens 已不含缓存、output_tokens 已含思考，直接按各自单价乘算，不可二次扣减或累加。
    /// 单价看请求时间：同一模型在介绍价截止日前后不是一个价。
    static func compute(model: String, at requestTime: Date, input: Int64, output: Int64, cacheRead: Int64, cacheWrite: Int64) -> (cost: Double, cacheSavings: Double) {
        guard let rate = AntigravityPricingTable.rateWithSource(for: model, at: requestTime).rate else { return (0, 0) }
        let cost = Double(input) * rate.input
            + Double(output) * rate.output
            + Double(cacheRead) * rate.cacheRead
            + Double(cacheWrite) * rate.cacheWrite
        let savings = max(0, Double(cacheRead) * (rate.input - rate.cacheRead))
        return (cost, savings)
    }
}

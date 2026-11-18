import Foundation

// xAI Grok Build 模型定价（美元 / token，costKind = .apiEquivalent）。
// 有 CLI 自报且完整的 costUsdTicks 时以自报为准；仅在缺失自报或自报为部分费用时按此表复算。
// 未收录的别名或内部代号不跨代猜价，有自报走自报，否则保持 $0。

struct GrokBuildModelRate: Sendable {
    var input: Double
    var output: Double
    var cacheRead: Double
}

enum GrokBuildPricingTable {
    /// 单位：美元 / token（对应每百万 token 单价 × 1e-6；4.5/4.6/4.7 取基础档 <200K）。
    static let bundled: [String: GrokBuildModelRate] = [
        "grok-4.7": .init(input: 2.00e-6, output: 6.00e-6, cacheRead: 0.50e-6),
        "grok-4.6": .init(input: 2.00e-6, output: 6.00e-6, cacheRead: 0.50e-6),
        "grok-4.5": .init(input: 2.00e-6, output: 6.00e-6, cacheRead: 0.30e-6),
        "grok-4.5-build": .init(input: 2.00e-6, output: 6.00e-6, cacheRead: 0.30e-6),
        "grok-4.3": .init(input: 1.25e-6, output: 2.50e-6, cacheRead: 0.20e-6),
        "grok-4.20-0309-reasoning": .init(input: 1.25e-6, output: 2.50e-6, cacheRead: 0.20e-6),
        "grok-4.20-0309-non-reasoning": .init(input: 1.25e-6, output: 2.50e-6, cacheRead: 0.20e-6),
        "grok-4-1-fast-reasoning": .init(input: 0.20e-6, output: 0.50e-6, cacheRead: 0.05e-6),
        "grok-4-1-fast-non-reasoning": .init(input: 0.20e-6, output: 0.50e-6, cacheRead: 0.05e-6),
        "grok-4": .init(input: 3.00e-6, output: 15.00e-6, cacheRead: 0.75e-6),
        "grok-code-fast-1": .init(input: 1.00e-6, output: 2.00e-6, cacheRead: 0.20e-6),
        "grok-build-0.1": .init(input: 1.00e-6, output: 2.00e-6, cacheRead: 0.20e-6),
        "grok-3": .init(input: 3.00e-6, output: 15.00e-6, cacheRead: 0.75e-6),
        "grok-3-mini": .init(input: 0.25e-6, output: 0.50e-6, cacheRead: 0.075e-6),
    ]

    /// -xhigh 必须排在 -high 前面，避免后缀被误截断。
    private static let effortSuffixes = ["-xhigh", "-minimal", "-medium", "-high", "-low"]

    static func rateWithSource(for rawModel: String) -> (rate: GrokBuildModelRate?, source: String) {
        let cleaned = cleanModelID(rawModel)
        if isPlaceholder(cleaned) {
            return (nil, L("模型未知，金额记 $0"))
        }

        for candidate in pricingCandidates(for: cleaned) {
            if let hit = bundled[candidate] {
                return (hit, "xAI API")
            }
        }

        // 不跨代前缀猜价：xAI 内部别名会随版本变动且无价时有自报 ticks 兜底，猜价反而容易串档。
        return (nil, L("暂无公开 API 定价"))
    }

    static func cleanModelID(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let slash = s.lastIndex(of: "/") { s = String(s[s.index(after: slash)...]) }
        if let colon = s.firstIndex(of: ":") { s = String(s[..<colon]) }
        return s.replacingOccurrences(of: "@", with: "-").lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isPlaceholder(_ model: String) -> Bool {
        let cleaned = cleanModelID(model)
        return cleaned.isEmpty || cleaned == "unknown" || cleaned == "none" || cleaned == "null"
    }

    private static func pricingCandidates(for cleaned: String) -> [String] {
        var result: [String] = []
        var queue: [String] = [cleaned]
        while let current = queue.first {
            queue.removeFirst()
            guard !current.isEmpty, !result.contains(current) else { continue }
            result.append(current)

            if let stripped = stripDateSuffix(current) { queue.append(stripped) }
            if let stripped = stripVersionSuffix(current) { queue.append(stripped) }
            if let stripped = stripEffortSuffix(current) { queue.append(stripped) }
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
        // 6 位 YYMMDD 额外校验月/日，降低把版本号数字尾巴误当日期的概率。
        if let range = model.range(of: #"-\d{6}$"#, options: .regularExpression) {
            let suffix = model[model.index(after: range.lowerBound)...]
            let monthStr = suffix.dropFirst(2).prefix(2)
            let dayStr = suffix.dropFirst(4).prefix(2)
            if let month = Int(monthStr), let day = Int(dayStr), (1...12).contains(month), (1...31).contains(day) {
                let base = String(model[model.startIndex..<range.lowerBound])
                if !base.isEmpty { return base }
            }
        }
        return nil
    }

    private static func stripVersionSuffix(_ model: String) -> String? {
        guard let range = model.range(of: #"-v\d+$"#, options: .regularExpression) else { return nil }
        let base = String(model[model.startIndex..<range.lowerBound])
        return base.isEmpty ? nil : base
    }

    private static func stripEffortSuffix(_ model: String) -> String? {
        for suffix in effortSuffixes where model.hasSuffix(suffix) {
            let base = String(model.dropLast(suffix.count))
            if !base.isEmpty { return base }
        }
        return nil
    }
}

enum GrokBuildCost {
    static let ticksPerUSD: Double = 10_000_000_000.0

    /// Grok Build 的 inputTokens 含 cachedReadTokens、outputTokens 已含 reasoningTokens：
    /// 调用方必须先扣减 cachedReadTokens 得到 freshInput，且不得重复加计 reasoningTokens。
    static func compute(
        model: String,
        freshInput: Int64,
        output: Int64,
        cacheRead: Int64,
        reportedTicks: Int64,
        costIsPartial: Bool
    ) -> (cost: Double, cacheSavings: Double) {
        let reportedUSD: Double? = reportedTicks > 0 ? Double(reportedTicks) / ticksPerUSD : nil
        let rate = GrokBuildPricingTable.rateWithSource(for: model).rate
        let savings = rate.map { max(0, Double(cacheRead) * ($0.input - $0.cacheRead)) } ?? 0

        if let reportedUSD, !costIsPartial {
            return (reportedUSD, savings)
        }
        if let rate {
            let localCost = Double(freshInput) * rate.input
                + Double(output) * rate.output
                + Double(cacheRead) * rate.cacheRead
            return (localCost, savings)
        }
        if let reportedUSD {
            return (reportedUSD, 0)
        }
        return (0, 0)
    }
}

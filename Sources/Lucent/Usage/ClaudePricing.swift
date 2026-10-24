import Foundation

// Claude 模型价目表：价格来源是 LiteLLM 的公开价目表
// https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json
// （2026-10-16 验证可访问）。这里只精简出 anthropic 直连的 claude-* 条目（Bedrock/Vertex region 前缀的不要）。
// 单位：美元 / token。1h 缓存写比 5m 贵，读缓存最便宜；都是公开 API 价目表，不代表订阅用户实际付费（costKind = .apiEquivalent）。
//
// 本机日志里见过 claude-opus-5-5 / claude-sonnet-5 / claude-opus-5 / claude-sonnet-5-5 / claude-haiku-5-5 /
// claude-opus-5-20260927（带日期的快照号，LiteLLM 没有）等型号，所以额外做"按家族回退到价目表里最新一版"。

struct ClaudeModelRate: Sendable {
    var input: Double
    var output: Double
    var cacheWrite5m: Double
    var cacheWrite1h: Double
    var cacheRead: Double
}

enum ClaudePricingTable {
    /// 精简自 LiteLLM model_prices_and_context_window.json，只保留 litellm_provider == "anthropic" 且
    /// 型号名以 claude- 开头、非 bedrock/vertex 区域前缀的条目
    static let bundled: [String: ClaudeModelRate] = [
        "claude-fable-5": .init(input: 1e-05, output: 5e-05, cacheWrite5m: 1.25e-05, cacheWrite1h: 2e-05, cacheRead: 1e-06),
        "claude-fable-5-1": .init(input: 1e-05, output: 5e-05, cacheWrite5m: 1.25e-05, cacheWrite1h: 2e-05, cacheRead: 2.5e-07),
        "claude-haiku-4-5": .init(input: 1e-06, output: 5e-06, cacheWrite5m: 1.25e-06, cacheWrite1h: 2e-06, cacheRead: 1e-07),
        "claude-haiku-4-5-20251001": .init(input: 1e-06, output: 5e-06, cacheWrite5m: 1.25e-06, cacheWrite1h: 2e-06, cacheRead: 1e-07),
        "claude-haiku-5-5": .init(input: 1e-07, output: 5e-07, cacheWrite5m: 1.25e-07, cacheWrite1h: 2e-07, cacheRead: 1e-08),
        "claude-mythos-5": .init(input: 1e-05, output: 5e-05, cacheWrite5m: 1.25e-05, cacheWrite1h: 2e-05, cacheRead: 1e-06),
        "claude-mythos-5-1": .init(input: 1e-05, output: 5e-05, cacheWrite5m: 1.25e-05, cacheWrite1h: 2e-05, cacheRead: 2.5e-07),
        "claude-mythos-preview": .init(input: 1e-05, output: 5e-05, cacheWrite5m: 1.25e-05, cacheWrite1h: 2e-05, cacheRead: 1e-06),
        "claude-opus-4-5": .init(input: 5e-06, output: 2.5e-05, cacheWrite5m: 6.25e-06, cacheWrite1h: 1e-05, cacheRead: 5e-07),
        "claude-opus-4-5-20251101": .init(input: 5e-06, output: 2.5e-05, cacheWrite5m: 6.25e-06, cacheWrite1h: 1e-05, cacheRead: 5e-07),
        "claude-opus-4-6": .init(input: 5e-06, output: 2.5e-05, cacheWrite5m: 6.25e-06, cacheWrite1h: 1e-05, cacheRead: 5e-07),
        "claude-opus-4-6-20260205": .init(input: 5e-06, output: 2.5e-05, cacheWrite5m: 6.25e-06, cacheWrite1h: 1e-05, cacheRead: 5e-07),
        "claude-opus-4-7": .init(input: 5e-06, output: 2.5e-05, cacheWrite5m: 6.25e-06, cacheWrite1h: 1e-05, cacheRead: 5e-07),
        "claude-opus-4-7-20260416": .init(input: 5e-06, output: 2.5e-05, cacheWrite5m: 6.25e-06, cacheWrite1h: 1e-05, cacheRead: 5e-07),
        "claude-opus-4-8": .init(input: 5e-06, output: 2.5e-05, cacheWrite5m: 6.25e-06, cacheWrite1h: 1e-05, cacheRead: 5e-07),
        "claude-opus-5": .init(input: 5e-06, output: 2.5e-05, cacheWrite5m: 6.25e-06, cacheWrite1h: 1e-05, cacheRead: 5e-07),
        "claude-opus-5-5": .init(input: 4e-06, output: 2e-05, cacheWrite5m: 5e-06, cacheWrite1h: 8e-06, cacheRead: 2e-07),
        "claude-sonnet-4-5": .init(input: 3e-06, output: 1.5e-05, cacheWrite5m: 3.75e-06, cacheWrite1h: 6e-06, cacheRead: 3e-07),
        "claude-sonnet-4-5-20250929": .init(input: 3e-06, output: 1.5e-05, cacheWrite5m: 3.75e-06, cacheWrite1h: 6e-06, cacheRead: 3e-07),
        "claude-sonnet-4-6": .init(input: 3e-06, output: 1.5e-05, cacheWrite5m: 3.75e-06, cacheWrite1h: 6e-06, cacheRead: 3e-07),
        "claude-sonnet-5": .init(input: 2e-06, output: 1e-05, cacheWrite5m: 2.5e-06, cacheWrite1h: 4e-06, cacheRead: 2e-07),
        "claude-sonnet-5-5": .init(input: 2e-06, output: 1e-05, cacheWrite5m: 2.5e-06, cacheWrite1h: 4e-06, cacheRead: 1e-07),
    ]

    /// 同一家族里价目表最新的一版，型号认不出来时按家族回退到这个价
    private static let newestByFamily: [String: String] = [
        "opus": "claude-opus-5-5",
        "sonnet": "claude-sonnet-5-5",
        "haiku": "claude-haiku-5-5",
        "fable": "claude-fable-5-1",
        "mythos": "claude-mythos-5-1",
    ]

    /// 去掉型号名尾部的日期快照号，例如 claude-opus-5-20260927 -> claude-opus-5
    private static func stripDateSuffix(_ model: String) -> String {
        guard let range = model.range(of: #"-\d{8}$"#, options: .regularExpression) else { return model }
        return String(model[model.startIndex..<range.lowerBound])
    }

    /// 日志里见过 `claude-opus-5.5` 这种点号写法，价目表的键是 `claude-opus-5-5`。
    /// 只把「数字.数字」换成「数字-数字」，其它字符不动。
    static func normalizeAlias(_ model: String) -> String {
        var out = ""
        out.reserveCapacity(model.count)
        let chars = Array(model)
        var i = 0
        while i < chars.count {
            if i + 2 < chars.count, chars[i].isNumber, chars[i + 1] == ".", chars[i + 2].isNumber {
                out.append(chars[i])
                out.append("-")
                i += 2
                continue
            }
            out.append(chars[i])
            i += 1
        }
        return out
    }

    /// 返回价目和"是不是按家族回退猜的"
    static func rate(for model: String) -> (rate: ClaudeModelRate, isFallback: Bool) {
        let (rate, isFallback, _) = rateWithSource(for: model)
        return (rate, isFallback)
    }

    /// 同上，外加"实际按哪个型号的价目算的"——给 PricingEntry.source 用
    static func rateWithSource(for raw: String) -> (rate: ClaudeModelRate, isFallback: Bool, matchedModel: String) {
        let model = normalizeAlias(raw)
        if let exact = bundled[model] { return (exact, false, model) }
        let stripped = stripDateSuffix(model)
        if stripped != model, let exact = bundled[stripped] { return (exact, false, stripped) }
        for (family, newest) in newestByFamily where model.contains(family) {
            if let r = bundled[newest] { return (r, true, newest) }
        }
        // 完全认不出来：按 sonnet 价位兜底，好过算成 0
        return (bundled["claude-sonnet-5-5"]!, true, "claude-sonnet-5-5")
    }

    /// 给 PricingEntry.source 用的一句话
    static func source(for model: String) -> String {
        let (_, isFallback, matched) = rateWithSource(for: model)
        return isFallback ? "同系列回退（按 \(matched)）" : "LiteLLM"
    }
}

/// 一条 assistant 用量行的缓存拆分（5m / 1h 分开算价）
struct ClaudeCacheBreakdown: Sendable {
    var write5m: Int64 = 0
    var write1h: Int64 = 0
    var read: Int64 = 0
}

enum ClaudeCost {
    /// 算一条消息的美元花费 + 缓存省了多少钱；fallback 为真时调用方应把这个型号记进"按家族回退定价"的集合。
    /// 省的钱 = 缓存读的 token 如果按原价（input 价）算要多花多少，不会是负数（缓存读价格恒低于 input 价）。
    static func compute(model: String, input: Int64, output: Int64, cache: ClaudeCacheBreakdown) -> (cost: Double, cacheSavings: Double, isFallback: Bool) {
        let (rate, isFallback) = ClaudePricingTable.rate(for: model)
        let cost = Double(input) * rate.input
            + Double(output) * rate.output
            + Double(cache.write5m) * rate.cacheWrite5m
            + Double(cache.write1h) * rate.cacheWrite1h
            + Double(cache.read) * rate.cacheRead
        let savings = max(0, Double(cache.read) * (rate.input - rate.cacheRead))
        return (cost, savings, isFallback)
    }
}

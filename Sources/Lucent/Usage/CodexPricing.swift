import Foundation

// Codex（OpenAI）模型价目表：同 ClaudePricing.swift 的路数，价格来源一样是 LiteLLM 的公开价目表
// https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json
// （2026-10-16 验证可访问），只精简出 litellm_provider == "openai" 且型号名以 gpt-5/o3/o4/codex 开头的条目。
// 单位：美元 / token，都是 apiEquivalent（订阅 ChatGPT/Codex 的用户不按这个直接付钱）。
//
// OpenAI 的账单里没有"按 1h/5m 分层的缓存写"这种东西（跟 Anthropic 不一样，缓存是自动的，
// 只有"缓存读"打折，没有"缓存写"额外收费），所以这里没有 cacheWrite5m/1h 字段，固定按 0 算。
//
// 像 "gpt-5.6-terra" 这类代号 / 地区变体，LiteLLM 表里有就直接命中，没有才走家族回退。

struct CodexModelRate: Sendable {
    var input: Double
    var output: Double
    var cacheRead: Double
}

enum CodexPricingTable {
    static let bundled: [String: CodexModelRate] = [
        "gpt-5": .init(input: 1.25e-06, output: 1e-05, cacheRead: 1.25e-07),
        "gpt-5-mini": .init(input: 2.5e-07, output: 2e-06, cacheRead: 2.5e-08),
        "gpt-5-nano": .init(input: 5e-08, output: 4e-07, cacheRead: 5e-09),
        "gpt-5-pro": .init(input: 1.5e-05, output: 1.2e-04, cacheRead: 0),
        "gpt-5-codex": .init(input: 1.25e-06, output: 1e-05, cacheRead: 1.25e-07),
        "gpt-5-chat-latest": .init(input: 1.25e-06, output: 1e-05, cacheRead: 1.25e-07),
        "gpt-5.1": .init(input: 1.25e-06, output: 1e-05, cacheRead: 1.25e-07),
        "gpt-5.1-codex": .init(input: 1.25e-06, output: 1e-05, cacheRead: 1.25e-07),
        "gpt-5.1-codex-max": .init(input: 1.25e-06, output: 1e-05, cacheRead: 1.25e-07),
        "gpt-5.1-codex-mini": .init(input: 2.5e-07, output: 2e-06, cacheRead: 2.5e-08),
        "gpt-5.1-chat-latest": .init(input: 1.25e-06, output: 1e-05, cacheRead: 1.25e-07),
        "gpt-5.2": .init(input: 1.75e-06, output: 1.4e-05, cacheRead: 1.75e-07),
        "gpt-5.2-codex": .init(input: 1.75e-06, output: 1.4e-05, cacheRead: 1.75e-07),
        "gpt-5.2-pro": .init(input: 2.1e-05, output: 1.68e-04, cacheRead: 0),
        "gpt-5.2-chat-latest": .init(input: 1.75e-06, output: 1.4e-05, cacheRead: 1.75e-07),
        "gpt-5.3-codex": .init(input: 1.75e-06, output: 1.4e-05, cacheRead: 1.75e-07),
        "gpt-5.3-chat-latest": .init(input: 1.75e-06, output: 1.4e-05, cacheRead: 1.75e-07),
        "gpt-5.4": .init(input: 2.5e-06, output: 1.5e-05, cacheRead: 2.5e-07),
        "gpt-5.4-mini": .init(input: 7.5e-07, output: 4.5e-06, cacheRead: 7.5e-08),
        "gpt-5.4-nano": .init(input: 2e-07, output: 1.25e-06, cacheRead: 2e-08),
        "gpt-5.4-pro": .init(input: 3e-05, output: 1.8e-04, cacheRead: 0),
        "gpt-5.5": .init(input: 5e-06, output: 3e-05, cacheRead: 5e-07),
        "gpt-5.5-pro": .init(input: 3e-05, output: 1.8e-04, cacheRead: 0),
        "gpt-5.5-cyber": .init(input: 1.25e-05, output: 7.5e-05, cacheRead: 1.25e-06),
        "gpt-5.6": .init(input: 4e-06, output: 2e-05, cacheRead: 4e-07),
        "gpt-5.6-sol": .init(input: 4e-06, output: 2e-05, cacheRead: 4e-07),
        "gpt-5.6-terra": .init(input: 2e-06, output: 1.2e-05, cacheRead: 2e-07),
        "gpt-5.6-luna": .init(input: 2e-07, output: 1.2e-06, cacheRead: 2e-08),
        "gpt-5.6-cyber": .init(input: 1.25e-05, output: 7.5e-05, cacheRead: 1.25e-06),
        "o3": .init(input: 2e-06, output: 8e-06, cacheRead: 5e-07),
        "o3-mini": .init(input: 1.1e-06, output: 4.4e-06, cacheRead: 5.5e-07),
        "o3-pro": .init(input: 2e-05, output: 8e-05, cacheRead: 0),
        "o3-deep-research": .init(input: 1e-05, output: 4e-05, cacheRead: 2.5e-06),
        "o4-mini": .init(input: 1.1e-06, output: 4.4e-06, cacheRead: 2.75e-07),
        "o4-mini-deep-research": .init(input: 2e-06, output: 8e-06, cacheRead: 5e-07),
    ]

    /// 同一家族里价目表最新的一版，型号认不出来时按家族回退到这个价（codex 后缀是单独一支，
    /// 跟同版本号的裸 gpt-5.x 价格往往一样但不一定，分开判断更准）。
    /// 本机 sqlite 里还有 gpt-5.3-codex-spark、codex-auto-review、gemini-*、grok-*：
    /// Spark 是研究预览，OpenAI 写明启动时不进 API，没有官方单价，不在这里编一个价，
    /// 名字里带 codex 的走下面的 codex 回退；gemini/grok 对不上任何家族，走最后的 gpt-5.6 回退。
    private static let newestByFamily: [(match: String, newest: String)] = [
        ("codex", "gpt-5.3-codex"),
        ("o4", "o4-mini"),
        ("o3", "o3"),
        ("gpt-5", "gpt-5.6"),
    ]

    private static func stripDateSuffix(_ model: String) -> String {
        // 两种日期后缀都见过："-20260927"（Claude 那边的格式）和 "-2025-08-07"（这边 LiteLLM 常见格式）
        for pattern in [#"-\d{4}-\d{2}-\d{2}$"#, #"-\d{8}$"#] {
            if let range = model.range(of: pattern, options: .regularExpression) {
                return String(model[model.startIndex..<range.lowerBound])
            }
        }
        return model
    }

    static func rateWithSource(for model: String) -> (rate: CodexModelRate, isFallback: Bool, matchedModel: String) {
        if let exact = bundled[model] { return (exact, false, model) }
        let stripped = stripDateSuffix(model)
        if stripped != model, let exact = bundled[stripped] { return (exact, false, stripped) }
        for (family, newest) in newestByFamily where model.contains(family) {
            if let r = bundled[newest] { return (r, true, newest) }
        }
        return (bundled["gpt-5.6"]!, true, "gpt-5.6")
    }

    static func rate(for model: String) -> (rate: CodexModelRate, isFallback: Bool) {
        let (rate, isFallback, _) = rateWithSource(for: model)
        return (rate, isFallback)
    }

    static func source(for model: String) -> String {
        let (_, isFallback, matched) = rateWithSource(for: model)
        return isFallback ? "同系列回退（按 \(matched)）" : "LiteLLM"
    }
}

enum CodexCost {
    /// 没有缓存写这一档（OpenAI 的缓存是自动命中折扣，不是像 Anthropic 那样按 1h/5m 单独计费写入）
    static func compute(model: String, input: Int64, output: Int64, cacheRead: Int64) -> (cost: Double, cacheSavings: Double, isFallback: Bool) {
        let (rate, isFallback) = CodexPricingTable.rate(for: model)
        let cost = Double(input) * rate.input + Double(output) * rate.output + Double(cacheRead) * rate.cacheRead
        let savings = max(0, Double(cacheRead) * (rate.input - rate.cacheRead))
        return (cost, savings, isFallback)
    }
}

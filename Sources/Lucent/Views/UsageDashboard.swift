import SwiftUI

// AI 用量 · 看板：信息量对齐 CC Switch 的用量页（时间范围、工具 / 供应商 / 模型筛选、核心指标、趋势、
// 请求日志 / 供应商 / 模型 / 项目 / 定价），样式沿用 Lucent 自己的设计稿。

enum UsageRange: String, CaseIterable, Identifiable {
    case today, last24h, week, month, all
    var id: String { rawValue }
    var title: String {
        switch self {
        case .today: return "当天"
        case .last24h: return "24 小时"
        case .week: return "7 天"
        case .month: return "30 天"
        case .all: return "全部"
        }
    }

    /// 范围起点；全部 = nil
    func start(_ now: Date) -> Date? {
        let cal = Calendar.current, day = cal.startOfDay(for: now)
        switch self {
        case .today: return day
        case .last24h: return cal.date(byAdding: .hour, value: -23, to: cal.dateInterval(of: .hour, for: now)!.start)
        case .week: return cal.date(byAdding: .day, value: -6, to: day)
        case .month: return cal.date(byAdding: .day, value: -29, to: day)
        case .all: return nil
        }
    }

    /// 30 天以内用逐小时明细，全部用逐日明细
    var hourly: Bool { self != .all }
}

enum UsageSubTab: String, CaseIterable, Identifiable {
    case log, providers, models, projects, pricing
    var id: String { rawValue }
    var title: String {
        switch self {
        case .log: return "请求日志"
        case .providers: return "供应商"
        case .models: return "模型"
        case .projects: return "项目"
        case .pricing: return "定价"
        }
    }
}

extension UsageMetric {
    func value(_ b: UsageBucket) -> Double {
        switch self {
        case .tokens: return Double(b.tokens.total)
        case .cost: return b.cost
        case .requests: return Double(b.requests)
        }
    }

    /// 坐标轴上的短写法
    func axis(_ v: Double) -> String {
        switch self {
        case .tokens: return UsageFmt.tokens(Int64(v))
        case .cost: return v >= 100 ? String(format: "$%.0f", v) : String(format: "$%.1f", v)
        case .requests: return "\(Int(v.rounded()))"
        }
    }
}

// MARK: - 按筛选取数

/// 一次筛选的结果：明细格子、请求、合计
struct UsageSlice {
    var buckets: [UsageBucket] = []
    var requests: [UsageRequest] = []
    var tokens = TokenCounts()
    var cost = 0.0
    var count = 0
    var savings = 0.0
    var write1h: Int64 = 0
    var timedOutput: Int64 = 0
    var timedMs: Int64 = 0

    /// 平均输出速度 tok/s
    var speed: Double? { timedMs > 0 ? Double(timedOutput) / (Double(timedMs) / 1000) : nil }

    static func make(_ tools: [ToolUsage], range: UsageRange, filter: UsageFilter, provider: String?, model: String?, now: Date = Date()) -> UsageSlice {
        let start = range.start(now)
        var s = UsageSlice()
        for t in tools where filter.includes(t.tool) {
            for b in (range.hourly ? t.hourlyDetail : t.dailyDetail) {
                if let start, b.start < start { continue }
                if let provider, b.provider != provider { continue }
                if let model, b.model != model { continue }
                s.buckets.append(b)
                s.tokens = s.tokens + b.tokens
                s.cost += b.cost
                s.count += b.requests
                s.savings += b.cacheSavings
                s.write1h += b.cacheWrite1h
                s.timedOutput += b.timedOutputTokens
                s.timedMs += b.timedDurationMs
            }
            s.requests += t.recentRequests.filter { r in
                (start.map { r.time >= $0 } ?? true) && (provider.map { r.provider == $0 } ?? true) && (model.map { r.model == $0 } ?? true)
            }
        }
        s.requests.sort { $0.time > $1.time }
        return s
    }
}

// MARK: - 看板

struct UsageDashboard: View {
    let tools: [ToolUsage]
    @AppStorage("usage.range") private var range: UsageRange = .today
    @AppStorage("usage.filter") private var filter: UsageFilter = .all
    @AppStorage("usage.metric") private var metric: UsageMetric = .tokens
    @AppStorage("usage.sub") private var sub: UsageSubTab = .log
    @AppStorage("usage.more") private var more = false
    @State private var provider: String?
    @State private var model: String?

    var body: some View {
        let f = filter.effective(tools)
        let slice = UsageSlice.make(tools, range: range, filter: f, provider: provider, model: model)
        let all = UsageSlice.make(tools, range: .month, filter: f, provider: nil, model: nil)
        VStack(spacing: 12) {
            filterBar(all)
            kpis(slice)
            if more { MoreMetrics(slice: slice) }
            TrendPanel(slice: slice, range: range, metric: $metric)
                .frame(height: more ? 180 : 210)
            DetailPanel(slice: slice, tools: tools.filter { f.includes($0.tool) }, sub: $sub, range: range)
                .frame(maxHeight: .infinity)
        }
    }

    private func filterBar(_ all: UsageSlice) -> some View {
        let providers = Array(Set(all.buckets.map(\.provider))).sorted()
        let models = Array(Set(all.buckets.filter { provider == nil || $0.provider == provider }.map(\.model))).sorted()
        return HStack(spacing: 8) {
            Segmented(items: UsageFilter.options(tools), selection: Binding(get: { filter.effective(tools) }, set: { filter = $0 }), compact: true)
            Spacer()
            Button { UIMotion.run(.easeOut(duration: 0.2)) { more.toggle() } } label: {
                HStack(spacing: 4) {
                    Text(more ? "收起指标" : "更多指标")
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).rotationEffect(.degrees(more ? 180 : 0))
                }
                .font(.system(size: 11.5)).foregroundStyle(Theme.dim(0.84))
                .padding(.horizontal, 10).frame(height: 28)
                .background(.white.opacity(more ? 0.14 : 0.06), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(.white.opacity(0.1), lineWidth: 1))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            PickMenu(title: "供应商", value: $provider, options: providers)
            PickMenu(title: "模型", value: $model, options: models)
            Segmented(items: UsageRange.allCases.map { ($0, $0.title) }, selection: $range, compact: true)
        }
        .onChange(of: filter) { provider = nil; model = nil }
    }

    private func kpis(_ s: UsageSlice) -> some View {
        HStack(spacing: 12) {
            StatTile(title: "COST · 总成本", value: costParts(s.cost),
                     caption: s.count > 0 ? "平均每次 \(UsageFmt.cost(s.cost / Double(s.count)))" : "这段时间没有请求")
            StatTile(title: "REQUESTS · 请求数", value: (s.count.formatted(), "次"),
                     caption: s.speed.map { String(format: "平均输出 ≈%.0f tok/s", $0) } ?? "没有可用的耗时数据")
            StatTile(title: "TOKENS · 总量", value: UsageFmt.tokenParts(s.tokens.total),
                     caption: "输入 \(UsageFmt.tokens(s.tokens.input)) · 输出 \(UsageFmt.tokens(s.tokens.output))")
            StatTile(title: "HIT RATE · 缓存命中", value: (s.tokens.hitRate.map { String(format: "%.1f", $0 * 100) } ?? "--", "%"),
                     caption: "缓存省下 \(UsageFmt.cost(s.savings))")
        }
        .frame(height: 118)
    }

    private func costParts(_ c: Double) -> (String, String) {
        c >= 10_000 ? (String(format: "%.1f", c / 1000), "K USD") : (String(format: c >= 100 ? "%.0f" : "%.2f", c), "USD")
    }
}

/// 下拉筛选（供应商 / 模型），没选时显示“全部”
private struct PickMenu: View {
    let title: String
    @Binding var value: String?
    let options: [String]

    var body: some View {
        Menu {
            Button("全部\(title)") { value = nil }
            if !options.isEmpty { Divider() }
            ForEach(options, id: \.self) { o in
                Button { value = o } label: {
                    if value == o { Label(o, systemImage: "checkmark") } else { Text(o) }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text(value ?? title).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
            }
            .font(.system(size: 11.5, weight: value == nil ? .regular : .semibold))
            .foregroundStyle(value == nil ? Theme.dim(0.84) : .white)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(.white.opacity(value == nil ? 0.06 : 0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(.white.opacity(0.1), lineWidth: 1))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

/// 展开的“更多指标”：一排小数字
private struct MoreMetrics: View {
    let slice: UsageSlice

    var body: some View {
        let t = slice.tokens, n = max(slice.count, 1)
        let items: [(String, String)] = [
            ("输入", UsageFmt.tokens(t.input)),
            ("输出", UsageFmt.tokens(t.output)),
            ("缓存读", UsageFmt.tokens(t.cacheRead)),
            ("缓存写", UsageFmt.tokens(t.cacheWrite)),
            ("其中 1 小时缓存", t.cacheWrite > 0 ? Fmt.percent(Double(slice.write1h) / Double(t.cacheWrite)) : "—"),
            ("平均每次 token", UsageFmt.tokens(t.total / Int64(n))),
            ("平均每次输出", UsageFmt.tokens(t.output / Int64(n))),
            ("活跃小时", "\(Set(slice.buckets.map(\.start)).count)"),
        ]
        Card(radius: 16, padding: EdgeInsets(top: 12, leading: 18, bottom: 12, trailing: 18)) {
            HStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.0).font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                        Text(item.1).font(.system(size: 15, weight: .semibold)).monospacedDigit()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if i < items.count - 1 { Rectangle().fill(.white.opacity(0.08)).frame(width: 1, height: 28).padding(.horizontal, 8) }
                }
            }
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}

// MARK: - 趋势

private struct TrendPanel: View {
    let slice: UsageSlice
    let range: UsageRange
    @Binding var metric: UsageMetric
    @State private var hover: Int?

    var body: some View {
        let bins = Self.bins(slice, range: range)
        let values = bins.map { b in b.items.reduce(0) { $0 + metric.value($1) } }
        let top = max(values.max() ?? 0, 1) * 1.12
        Panel {
            HStack(spacing: 12) {
                Eyebrow("TREND · 使用趋势 · \(range.title)")
                Text(hover.map { i in "\(bins[i].label) · \(metric.format(values[i]))" + detail(bins[i].items) } ?? " ")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.secondary).monospacedDigit().lineLimit(1)
                Spacer()
                Segmented(items: UsageMetric.allCases.map { ($0, $0.title) }, selection: $metric, compact: true)
            }
            GeometryReader { g in
                let axisW: CGFloat = 44, bottom: CGFloat = 16
                let w = g.size.width - axisW, h = g.size.height - bottom
                let n = max(bins.count, 1)
                let step = w / CGFloat(n), bar = max(step * 0.62, 1.5)
                Canvas { ctx, _ in
                    for f in [0.0, 0.5, 1.0] {
                        let y = h - CGFloat(f) * h * 0.9
                        var p = Path(); p.move(to: .init(x: axisW, y: y)); p.addLine(to: .init(x: g.size.width, y: y))
                        ctx.stroke(p, with: .color(.white.opacity(f == 0 ? 0.14 : 0.07)), style: StrokeStyle(lineWidth: 0.6, dash: f == 0 ? [] : [2, 4]))
                        ctx.draw(Text(metric.axis(top * 0.9 * f)).font(Theme.mono(9.5)).foregroundStyle(Theme.tertiary),
                                 at: CGPoint(x: axisW - 8, y: y), anchor: .trailing)
                    }
                    let peak = values.indices.max { values[$0] < values[$1] }
                    var glow = Path()
                    for (i, v) in values.enumerated() {
                        let bh = CGFloat(v / top) * h
                        let rect = CGRect(x: axisW + CGFloat(i) * step + (step - bar) / 2, y: h - bh, width: bar, height: max(bh, v > 0 ? 1.5 : 0))
                        guard rect.height > 0 else { continue }
                        let p = Path(roundedRect: rect, cornerRadius: min(bar / 3, 3))
                        let on = hover == nil || hover == i
                        ctx.fill(p, with: .color(.white.opacity(on ? (i == peak ? 0.95 : 0.7) : 0.35)))
                        if i == peak || hover == i { glow.addPath(p) }
                    }
                    var gctx = ctx
                    gctx.addFilter(.shadow(color: .white.opacity(0.7), radius: 5))
                    gctx.fill(glow, with: .color(.white))
                    // 横轴：最多 7 个标签
                    let every = max(n / 6, 1)
                    for i in stride(from: 0, to: n, by: every) {
                        ctx.draw(Text(bins[i].tick).font(Theme.mono(9.5)).foregroundStyle(Theme.tertiary),
                                 at: CGPoint(x: axisW + CGFloat(i) * step + step / 2, y: g.size.height - 5))
                    }
                }
                .onContinuousHover { phase in
                    switch phase {
                    case let .active(p):
                        let i = Int((p.x - axisW) / step)
                        hover = (p.x >= axisW && i >= 0 && i < bins.count) ? i : nil
                    case .ended: hover = nil
                    }
                }
            }
        }
    }

    private func detail(_ items: [UsageBucket]) -> String {
        let t = items.reduce(TokenCounts()) { $0 + $1.tokens }
        let r = items.reduce(0) { $0 + $1.requests }
        return " · \(r) 次 · 命中 \(t.hitRate.map { String(format: "%.0f%%", $0 * 100) } ?? "—") · \(UsageFmt.cost(items.reduce(0) { $0 + $1.cost }))"
    }

    struct Bin { var start: Date; var label: String; var tick: String; var items: [UsageBucket] = [] }

    /// 当天 / 24 小时按小时，7 天按 6 小时，30 天按天，全部按天（超过 120 天按周）
    static func bins(_ s: UsageSlice, range: UsageRange, now: Date = Date()) -> [Bin] {
        let cal = Calendar.current
        let hourF = DateFormatter(); hourF.dateFormat = "HH:00"
        let dayF = DateFormatter(); dayF.dateFormat = "M/d"
        let fullF = DateFormatter(); fullF.dateFormat = "M 月 d 日 HH:00"
        let dayFull = DateFormatter(); dayFull.dateFormat = "M 月 d 日"
        var start: Date, step: TimeInterval, count: Int
        var tick: (Date) -> String, label: (Date) -> String
        switch range {
        case .today:
            start = cal.startOfDay(for: now); step = 3600; count = 24
            tick = { hourF.string(from: $0) }; label = { fullF.string(from: $0) }
        case .last24h:
            start = range.start(now)!; step = 3600; count = 24
            tick = { hourF.string(from: $0) }; label = { fullF.string(from: $0) }
        case .week:
            start = range.start(now)!; step = 6 * 3600; count = 28
            tick = { dayF.string(from: $0) }; label = { fullF.string(from: $0) + " 起 6 小时" }
        case .month:
            start = range.start(now)!; step = 86400; count = 30
            tick = { dayF.string(from: $0) }; label = { dayFull.string(from: $0) }
        case .all:
            let first = s.buckets.map(\.start).min() ?? cal.startOfDay(for: now)
            let days = (cal.dateComponents([.day], from: cal.startOfDay(for: first), to: cal.startOfDay(for: now)).day ?? 0) + 1
            let weekly = days > 120
            step = weekly ? 7 * 86400 : 86400
            start = cal.startOfDay(for: first)
            count = max(Int(ceil(Double(days) * 86400 / step)), 1)
            tick = { dayF.string(from: $0) }; label = { dayFull.string(from: $0) + (weekly ? " 起一周" : "") }
        }
        var bins = (0..<count).map { i -> Bin in
            let d = start.addingTimeInterval(Double(i) * step)
            return Bin(start: d, label: label(d), tick: tick(d))
        }
        for b in s.buckets {
            let i = Int(b.start.timeIntervalSince(start) / step)
            if i >= 0 && i < bins.count { bins[i].items.append(b) }
        }
        return bins
    }
}

// MARK: - 明细（子页签）

private struct DetailPanel: View {
    let slice: UsageSlice
    let tools: [ToolUsage]
    @Binding var sub: UsageSubTab
    let range: UsageRange

    var body: some View {
        Panel {
            HStack {
                Segmented(items: UsageSubTab.allCases.map { ($0, $0.title) }, selection: $sub, compact: true)
                Spacer()
                Text(note).font(.system(size: 11.5)).foregroundStyle(Theme.tertiary).monospacedDigit()
            }
            switch sub {
            case .log: RequestLog(requests: slice.requests, today: range == .today || range == .last24h)
            case .providers: GroupTable(rows: group(slice.buckets) { "\($0.tool.title)|\($0.provider)" }, kind: .provider)
            case .models: GroupTable(rows: group(slice.buckets) { "\($0.tool.title)|\($0.model)" }, kind: .model)
            case .projects: ProjectTable(projects: tools.flatMap(\.projects))
            case .pricing: PricingTable(entries: tools.flatMap(\.pricing))
            }
        }
    }

    private var note: String {
        switch sub {
        case .log: return "共 \(slice.count.formatted()) 次请求，列出最近 \(slice.requests.count) 条"
        case .projects: return "近 30 天（不随时间范围变化）"
        case .pricing: return "美元 / 百万 token"
        default: return range.title
        }
    }

    private func group(_ buckets: [UsageBucket], key: (UsageBucket) -> String) -> [GroupRow] {
        var map: [String: GroupRow] = [:]
        for b in buckets {
            let k = key(b)
            var r = map[k] ?? GroupRow(key: k)
            r.tokens = r.tokens + b.tokens
            r.cost += b.cost
            r.requests += b.requests
            r.timedOutput += b.timedOutputTokens
            r.timedMs += b.timedDurationMs
            map[k] = r
        }
        return map.values.sorted { $0.tokens.total > $1.tokens.total }
    }
}

struct GroupRow: Identifiable {
    var key: String
    var tokens = TokenCounts()
    var cost = 0.0
    var requests = 0
    var timedOutput: Int64 = 0
    var timedMs: Int64 = 0
    var id: String { key }
    var parts: (String, String) { let p = key.split(separator: "|", maxSplits: 1).map(String.init); return (p.first ?? "", p.count > 1 ? p[1] : "") }
    var speed: Double? { timedMs > 0 ? Double(timedOutput) / (Double(timedMs) / 1000) : nil }
}

/// 供应商 / 模型 汇总表
private struct GroupTable: View {
    enum Kind { case provider, model }
    let rows: [GroupRow]
    let kind: Kind

    var body: some View {
        let total = Double(max(rows.reduce(Int64(0)) { $0 + $1.tokens.total }, 1))
        TableHeader(cols: [(kind == .provider ? "供应商" : "模型", nil, .leading), ("占比", 150, .leading), ("请求", 64, .trailing),
                           ("输入", 64, .trailing), ("输出", 64, .trailing), ("命中", 50, .trailing), ("速度", 70, .trailing),
                           ("TOKEN", 64, .trailing), ("成本", 74, .trailing)])
        if rows.isEmpty { Empty() }
        ScrollView {
            VStack(spacing: 2) {
                ForEach(rows) { r in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.parts.1.isEmpty ? "—" : r.parts.1).lineLimit(1).truncationMode(.middle)
                            Text(r.parts.0).font(.system(size: 10.5)).foregroundStyle(Theme.tertiary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        ShareBar(share: Double(r.tokens.total) / total).frame(width: 150, alignment: .leading)
                        cell(r.requests.formatted(), 64)
                        cell(UsageFmt.tokens(r.tokens.input), 64)
                        cell(UsageFmt.tokens(r.tokens.output), 64)
                        cell(r.tokens.hitRate.map { String(format: "%.0f%%", $0 * 100) } ?? "—", 50)
                        cell(r.speed.map { String(format: "≈%.0f", $0) } ?? "—", 70, unit: r.speed == nil ? nil : "tok/s")
                        cell(UsageFmt.tokens(r.tokens.total), 64)
                        cell(r.cost > 0 ? UsageFmt.cost(r.cost) : "—", 74, strong: true)
                    }
                    .font(.system(size: 12)).monospacedDigit()
                    .padding(.horizontal, 8).padding(.vertical, 5)
                }
            }
        }
        .scrollIndicators(.automatic)
    }
}

/// 请求日志
private struct RequestLog: View {
    let requests: [UsageRequest]
    let today: Bool
    @State private var hover: String?

    static let cols: [(String, CGFloat?, Alignment)] = [
        ("时间", 86, .leading), ("应用", 66, .leading), ("供应商", 76, .leading), ("模型 · 项目", nil, .leading),
        ("新增输入", 60, .trailing), ("输出", 56, .trailing), ("缓存命中", 64, .trailing), ("缓存写", 56, .trailing),
        ("成本", 64, .trailing), ("速度", 84, .trailing),
    ]

    var body: some View {
        TableHeader(cols: Self.cols)
        if requests.isEmpty { Empty() }
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(requests) { r in
                    let t = r.tokens
                    HStack(spacing: 8) {
                        cell((today ? Self.timeF : Self.dateF).string(from: r.time), 86, align: .leading)
                        cell(r.tool.shortTitle, 66, align: .leading)
                        cell(r.provider.isEmpty ? "—" : r.provider, 76, align: .leading, dim: true)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(r.model).lineLimit(1).truncationMode(.middle)
                            if let p = r.project { Text(p).font(.system(size: 10.5)).foregroundStyle(Theme.tertiary).lineLimit(1).truncationMode(.middle) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        cell(UsageFmt.tokens(t.input), 60)
                        cell(UsageFmt.tokens(t.output), 56)
                        cell(UsageFmt.tokens(t.cacheRead), 64)
                        cell(UsageFmt.tokens(t.cacheWrite), 56)
                        cell(r.cost > 0 ? String(format: "$%.4f", r.cost) : "—", 64, strong: true)
                        cell(speed(r).0, 84, unit: speed(r).1)
                    }
                    .font(.system(size: 12)).monospacedDigit()
                    .padding(.horizontal, 8)
                    .frame(height: 36)
                    .background(hover == r.id ? .white.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 6))
                    .onHover { hover = $0 ? r.id : (hover == r.id ? nil : hover) }
                }
            }
        }
        .scrollIndicators(.automatic)
    }

    private func speed(_ r: UsageRequest) -> (String, String?) {
        guard let ms = r.durationMs, ms > 0, r.tokens.output >= SpeedRule.minOutputTokens else { return ("—", nil) }
        let v = Double(r.tokens.output) / (Double(ms) / 1000)
        return ((r.durationIsEstimate ? "≈" : "") + String(format: "%.0f", v), "tok/s")
    }

    static let timeF: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f }()
    static let dateF: DateFormatter = { let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm"; return f }()
}

private struct ProjectTable: View {
    let projects: [ProjectShare]
    var body: some View {
        let rows = projects.sorted { $0.tokens.total > $1.tokens.total }
        let total = Double(max(rows.reduce(Int64(0)) { $0 + $1.tokens.total }, 1))
        TableHeader(cols: [("项目", nil, .leading), ("占比", 150, .leading), ("请求", 64, .trailing), ("命中", 50, .trailing),
                           ("最近活动", 84, .trailing), ("TOKEN", 64, .trailing), ("成本", 74, .trailing)])
        if rows.isEmpty { Empty() }
        ScrollView {
            VStack(spacing: 2) {
                ForEach(rows) { p in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.project).lineLimit(1).truncationMode(.middle)
                            Text(p.tool.title).font(.system(size: 10.5)).foregroundStyle(Theme.tertiary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        ShareBar(share: Double(p.tokens.total) / total).frame(width: 150, alignment: .leading)
                        cell(p.requests.formatted(), 64)
                        cell(p.tokens.hitRate.map { String(format: "%.0f%%", $0 * 100) } ?? "—", 50)
                        cell(UsageFmt.ago(p.lastActive), 84, dim: true)
                        cell(UsageFmt.tokens(p.tokens.total), 64)
                        cell(p.cost > 0 ? UsageFmt.cost(p.cost) : "—", 74, strong: true)
                    }
                    .font(.system(size: 12)).monospacedDigit()
                    .padding(.horizontal, 8).padding(.vertical, 5)
                }
            }
        }
    }
}

private struct PricingTable: View {
    let entries: [PricingEntry]
    var body: some View {
        TableHeader(cols: [("模型", nil, .leading), ("输入", 70, .trailing), ("输出", 70, .trailing), ("缓存读", 70, .trailing),
                           ("缓存写 5 分钟", 92, .trailing), ("缓存写 1 小时", 92, .trailing), ("来源", 190, .leading)])
        if entries.isEmpty { Empty() }
        ScrollView {
            VStack(spacing: 2) {
                ForEach(entries) { e in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(e.model).lineLimit(1).truncationMode(.middle)
                            Text(e.tool.title).font(.system(size: 10.5)).foregroundStyle(Theme.tertiary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        cell(price(e.input), 70)
                        cell(price(e.output), 70)
                        cell(price(e.cacheRead), 70)
                        cell(price(e.cacheWrite5m), 92)
                        cell(price(e.cacheWrite1h), 92)
                        cell(e.source, 190, align: .leading, dim: true)
                    }
                    .font(.system(size: 12)).monospacedDigit()
                    .padding(.horizontal, 8).padding(.vertical, 5)
                }
            }
        }
    }

    private func price(_ v: Double?) -> String {
        guard let v else { return "—" }
        return v < 1 ? String(format: "$%.3f", v) : String(format: "$%.2f", v)
    }
}

// MARK: - 表格小部件

private struct TableHeader: View {
    let cols: [(String, CGFloat?, Alignment)]
    var body: some View {
        HStack(spacing: cols.count > 9 ? 8 : 10) {
            ForEach(Array(cols.enumerated()), id: \.offset) { _, c in
                Text(c.0)
                    .frame(width: c.1, alignment: c.2)
                    .frame(maxWidth: c.1 == nil ? .infinity : nil, alignment: c.2)
            }
        }
        .font(Theme.mono(10)).tracking(0.8).foregroundStyle(Theme.dim(0.58)).lineLimit(1)
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
        .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.1)).frame(height: 1) }
    }
}

private struct Empty: View {
    var body: some View {
        Text("这段时间没有记录").font(.system(size: 12)).foregroundStyle(Theme.tertiary).padding(.top, 6)
    }
}

private struct ShareBar: View {
    let share: Double
    var body: some View {
        HStack(spacing: 6) {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.08))
                    Capsule().fill(Theme.accent).frame(width: max(g.size.width * share, 2))
                        .shadow(color: Theme.accent.opacity(0.8), radius: 3)
                }
            }
            .frame(height: 3)
            Text(Fmt.percent(share)).font(.system(size: 11)).foregroundStyle(Theme.secondary).frame(width: 38, alignment: .trailing)
        }
    }
}

/// 表格的一格：等宽数字，可带灰色单位
@ViewBuilder
private func cell(_ text: String, _ width: CGFloat, align: Alignment = .trailing, dim: Bool = false, strong: Bool = false, unit: String? = nil) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 2) {
        Text(text).lineLimit(1).truncationMode(.middle)
            .foregroundStyle(dim ? Theme.secondary : (strong ? Theme.text : Theme.dim(0.86)))
            .fontWeight(strong ? .semibold : .regular)
        if let unit { Text(unit).font(.system(size: 10)).foregroundStyle(Theme.tertiary) }
    }
    .frame(width: width, alignment: align)
}

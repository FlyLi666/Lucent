import SwiftUI

// AI 用量的详细数据看板：页签切换（概览 / 热力图 / 缓存 / 请求 / 模型与项目），不把所有东西堆在一页。

enum UsageTab: String, CaseIterable, Identifiable {
    case dashboard, overview, heatmap, cache
    var id: String { rawValue }
    var title: String {
        switch self {
        case .dashboard: return "看板"
        case .overview: return "工具与额度"
        case .heatmap: return "热力图"
        case .cache: return "缓存"
        }
    }
}

/// 只看哪个工具
enum UsageFilter: String, CaseIterable, Identifiable {
    case all, claude, cursor, opencode, codex
    var id: String { rawValue }
    var tool: AITool? { AITool(rawValue: rawValue) }
    var title: String { tool?.title ?? "全部" }
    func includes(_ t: AITool) -> Bool {
        guard let tool else { return t.hasLocalLogs }
        return t == tool
    }

    /// 筛选按钮：全部 + 当前显示的、有本机记录的工具（隐藏或没装的不出空按钮）
    static func options(_ tools: [ToolUsage]) -> [(UsageFilter, String)] {
        [(.all, "全部")] + tools.compactMap { u in
            u.tool.hasLocalLogs ? UsageFilter(rawValue: u.tool.rawValue).map { ($0, $0.title) } : nil
        }
    }

    /// 选中的工具被隐藏了就当作“全部”
    func effective(_ tools: [ToolUsage]) -> UsageFilter {
        guard let tool else { return .all }
        return tools.contains { $0.tool == tool } ? self : .all
    }
}

/// 设置里选择“AI 用量显示哪些工具”
enum UsageVisibility {
    static func hidden(_ raw: String) -> Set<AITool> {
        Set(raw.split(separator: ",").compactMap { AITool(rawValue: String($0)) })
    }

    static func raw(_ hidden: Set<AITool>) -> String {
        AITool.allCases.filter(hidden.contains).map(\.rawValue).joined(separator: ",")
    }

    /// 界面上显示的工具：没被隐藏、本机装了、而且有过记录（没装或从没用过的不出空按钮、空面板；有了第一条记录自动出现）
    static func shown(_ tools: [ToolUsage], hiddenRaw: String) -> [ToolUsage] {
        let h = hidden(hiddenRaw)
        return tools.filter { !h.contains($0.tool) && $0.status != .notInstalled && !$0.isEmptyLocal }
    }

    static var enabled: Set<AITool> {
        Set(AITool.allCases).subtracting(hidden(UserDefaults.standard.string(forKey: Prefs.usageHidden) ?? ""))
    }
}

enum UsageMetric: String, CaseIterable, Identifiable {
    case tokens, cost, requests
    var id: String { rawValue }
    var title: String {
        switch self {
        case .tokens: return "Token"
        case .cost: return "金额"
        case .requests: return "请求数"
        }
    }
    func value(_ d: DailyUsage) -> Double {
        switch self {
        case .tokens: return Double(d.tokens.total)
        case .cost: return d.cost
        case .requests: return Double(d.requests)
        }
    }
    func value(_ h: HourlyUsage) -> Double {
        switch self {
        case .tokens: return Double(h.tokens.total)
        case .cost: return h.cost
        case .requests: return Double(h.requests)
        }
    }
    func format(_ v: Double) -> String {
        switch self {
        case .tokens: return UsageFmt.tokens(Int64(v)) + " tok"
        case .cost: return UsageFmt.cost(v)
        case .requests: return "\(Int(v)) 次"
        }
    }
}

extension ToolUsage {
    /// 有本机记录的工具读完了却一条记录都没有（例如装了 Codex 但没用过）
    var isEmptyLocal: Bool {
        tool.hasLocalLogs && status == .ok && dailyDetail.isEmpty && recentRequests.isEmpty
            && !history.contains { $0.tokens.total > 0 } && !daily.contains { $0.tokens.total > 0 }
    }
}

extension TokenCounts {
    /// 缓存命中率：缓存读 /（输入 + 缓存读 + 缓存写）
    var hitRate: Double? {
        let d = input + cacheRead + cacheWrite
        return d > 0 ? Double(cacheRead) / Double(d) : nil
    }
}

// MARK: - 页签切换器（放在主窗口标题右侧）

struct UsageTabPicker: View {
    @AppStorage("usage.tab") private var tab: UsageTab = .dashboard
    var body: some View {
        Segmented(items: UsageTab.allCases.map { ($0, $0.title) }, selection: $tab)
            .fixedSize()
    }
}

/// 设计稿风格的分段选择（和时间范围选择器一个样子）
struct Segmented<T: Hashable>: View {
    let items: [(T, String)]
    @Binding var selection: T
    var compact = false
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.0) { value, title in
                let on = value == selection
                Button { UIMotion.run { selection = value } } label: {
                    Text(title)
                        .font(.system(size: compact ? 11.5 : 12.5, weight: on ? .semibold : .regular))
                        .foregroundStyle(on ? .white : Theme.dim(0.84))
                        .padding(.horizontal, compact ? 10 : 14)
                        .frame(height: compact ? 24 : 30)
                        .background {
                            // 选中块滑到新位置
                            if on {
                                RoundedRectangle(cornerRadius: compact ? 7 : 9, style: .continuous).fill(.white.opacity(0.16))
                                    .matchedGeometryEffect(id: "thumb", in: ns)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(compact ? 2 : 3)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: compact ? 9 : 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: compact ? 9 : 12, style: .continuous).strokeBorder(.white.opacity(0.1), lineWidth: 1))
    }
}

// MARK: - 分区入口

struct UsageSection: View {
    let store: UsageStore
    @AppStorage("usage.tab") private var tab: UsageTab = .dashboard
    @AppStorage("usage.filter") private var filter: UsageFilter = .all
    @AppStorage(Prefs.usageHidden) private var hiddenRaw = ""   // 改设置时让界面跟着刷新

    @AppStorage(UsageAccounts.selectedKey) private var accountID = ""   // 换账号时让界面跟着刷新

    var body: some View {
        let tools = UsageData.tools(store)
        let picked = tools.filter { filter.effective(tools).includes($0.tool) }
        VStack(spacing: 12) {
            AccountSuggestionBanner(store: store)
                .transition(.opacity.combined(with: .move(edge: .top)))
            ZStack(alignment: .topLeading) {
                Group {
                    switch tab {
                    case .dashboard: UsageDashboard(tools: tools)
                    case .overview: UsageOverviewTab(store: store, tools: tools)
                    case .heatmap: HeatmapTab(tools: picked, filter: $filter)
                    case .cache: CacheTab(tools: picked, filter: $filter)
                    }
                }
                .id(tab)
                .transition(UIMotion.contentSwap)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

/// 调试版可以用 `-usageFixture YES` 填充示例明细，先看界面效果
enum UsageData {
    /// 界面用的工具列表：已按设置去掉隐藏的、没装的
    @MainActor static func tools(_ store: UsageStore) -> [ToolUsage] {
        let hiddenRaw = UserDefaults.standard.string(forKey: Prefs.usageHidden) ?? ""
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "usageFixture") {
            return UsageVisibility.shown(UsageFixture.augment(store.tools), hiddenRaw: hiddenRaw)
        }
        #endif
        // 选了某个账号：只看这一个账号（其余工具不显示），各页签不用知道账号的存在
        if let a = UsageAccounts.selected(store) {
            return UsageVisibility.shown([store.usage(a.tool, account: a.id)], hiddenRaw: hiddenRaw)
        }
        return UsageVisibility.shown(store.tools, hiddenRaw: hiddenRaw)
    }

    /// 多个工具的逐日数据按天合并（最早在前）
    static func mergedHistory(_ tools: [ToolUsage]) -> [DailyUsage] {
        var byDay: [Date: DailyUsage] = [:]
        for t in tools {
            for d in (t.history.isEmpty ? t.daily : t.history) {
                var m = byDay[d.day] ?? DailyUsage(day: d.day)
                m.tokens = m.tokens + d.tokens
                m.cost += d.cost
                m.requests += d.requests
                m.cacheSavings += d.cacheSavings
                m.cacheWrite1h += d.cacheWrite1h
                byDay[d.day] = m
            }
        }
        return byDay.values.sorted { $0.day < $1.day }
    }

    static func mergedDaily(_ tools: [ToolUsage]) -> [DailyUsage] {
        let cut = Calendar.current.date(byAdding: .day, value: -29, to: Calendar.current.startOfDay(for: Date()))!
        return mergedHistory(tools).filter { $0.day >= cut }
    }

    static func mergedHourly(_ tools: [ToolUsage]) -> [HourlyUsage] {
        var byHour: [Date: HourlyUsage] = [:]
        for t in tools {
            for h in t.hourly {
                var m = byHour[h.hour] ?? HourlyUsage(hour: h.hour)
                m.tokens = m.tokens + h.tokens
                m.cost += h.cost
                m.requests += h.requests
                byHour[h.hour] = m
            }
        }
        return byHour.values.sorted { $0.hour < $1.hour }
    }
}

// MARK: - 共用

/// 面板右上角的小号工具筛选
private struct FilterBar: View {
    @Binding var filter: UsageFilter
    @AppStorage(Prefs.usageHidden) private var hiddenRaw = ""
    var body: some View {
        let tools = UsageData.tools(UsageStore.shared)
        Segmented(items: UsageFilter.options(tools), selection: Binding(get: { filter.effective(tools) }, set: { filter = $0 }), compact: true)
    }
}

/// 一个统计块：小标题 + 点阵大数字 + 一行说明
struct StatTile: View {
    let title: String
    let value: (String, String)
    var caption: String?
    var alert = false

    var body: some View {
        Panel {
            Eyebrow(title)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                RollingNumber(text: value.0, font: Theme.dotoNS(34), color: NSColor(alert ? Theme.heat : Theme.text), glow: 0.3, glowRadius: 6)
                    .baseline(of: Theme.dotoNS(34))
                Text(value.1).font(Theme.mono(11)).foregroundStyle(Theme.tertiary).fixedSize()
            }
            if let caption {
                Text(caption).font(.system(size: 11.5)).foregroundStyle(Theme.secondary).lineLimit(1)
            }
        }
    }
}

/// 热力格子的亮度：0 级几乎看不见，4 级最亮并发光
enum HeatLevel {
    static let opacity: [Double] = [0.05, 0.2, 0.4, 0.66, 1]

    /// 按非零值的四分位分 1~4 级
    static func thresholds(_ values: [Double]) -> [Double] {
        let v = values.filter { $0 > 0 }.sorted()
        guard !v.isEmpty else { return [1, 1, 1] }
        func q(_ p: Double) -> Double { v[min(Int(Double(v.count - 1) * p), v.count - 1)] }
        return [q(0.25), q(0.5), q(0.75)]
    }

    static func level(_ x: Double, _ t: [Double]) -> Int {
        guard x > 0 else { return 0 }
        if x <= t[0] { return 1 }
        if x <= t[1] { return 2 }
        if x <= t[2] { return 3 }
        return 4
    }
}

/// 热力图图例：少 ▪▪▪▪▪ 多
private struct HeatLegend: View {
    var body: some View {
        HStack(spacing: 4) {
            Text("少")
            ForEach(0..<5, id: \.self) { i in
                RoundedRectangle(cornerRadius: 2.5).fill(.white.opacity(HeatLevel.opacity[i])).frame(width: 10, height: 10)
                    .shadow(color: i == 4 ? .white.opacity(0.6) : .clear, radius: 3)
            }
            Text("多")
        }
        .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
    }
}

let weekdayNames = ["一", "二", "三", "四", "五", "六", "日"]

/// 周一 = 0 … 周日 = 6
func weekdayIndex(_ d: Date) -> Int { (Calendar.current.component(.weekday, from: d) + 5) % 7 }

func dayLabel(_ d: Date) -> String {
    let c = Calendar.current.dateComponents([.month, .day], from: d)
    return "\(c.month ?? 0) 月 \(c.day ?? 0) 日 · 周\(weekdayNames[weekdayIndex(d)])"
}

// MARK: - 热力图

private struct HeatmapTab: View {
    let tools: [ToolUsage]
    @Binding var filter: UsageFilter
    @AppStorage("usage.metric") private var metric: UsageMetric = .tokens

    var body: some View {
        let history = UsageData.mergedHistory(tools)
        let hourly = UsageData.mergedHourly(tools)
        VStack(spacing: 14) {
            Panel {
                HStack {
                    Eyebrow("ACTIVITY · 近一年每天")
                    Spacer()
                    Segmented(items: UsageMetric.allCases.map { ($0, $0.title) }, selection: $metric, compact: true)
                    FilterBar(filter: $filter)
                }
                CalendarHeatmap(history: history, metric: metric)
                    .frame(height: 150)
                HStack {
                    Text(history.contains { $0.tokens.total > 0 } ? "数据从 \(firstDay(history)) 开始；Claude Code 自己只保留约 30 天日志，Lucent 会从现在起持续积累" : "还没有数据")
                        .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                    Spacer()
                    HeatLegend()
                }
            }
            .frame(height: 248)
            HStack(alignment: .top, spacing: 14) {
                Panel {
                    HStack {
                        Eyebrow("RHYTHM · 星期 × 时段（近 30 天）")
                        Spacer()
                        HeatLegend()
                    }
                    HourHeatmap(hourly: hourly, metric: metric)
                }
                .frame(maxWidth: .infinity)
                HabitStats(history: history, hourly: hourly, metric: metric)
                    .frame(width: 300)
            }
            .frame(maxHeight: .infinity)
        }
    }

    private func firstDay(_ h: [DailyUsage]) -> String {
        guard let d = h.first(where: { $0.tokens.total > 0 })?.day else { return "—" }
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return "\(c.year ?? 0) 年 \(c.month ?? 0) 月 \(c.day ?? 0) 日"
    }
}

/// GitHub 式日历热力图：列是周，行是星期一到日
private struct CalendarHeatmap: View {
    let history: [DailyUsage]
    let metric: UsageMetric
    @State private var hover: Date?

    var body: some View {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let weeks = 53
        // 第一列的周一
        let thisMonday = cal.date(byAdding: .day, value: -weekdayIndex(today), to: today)!
        let start = cal.date(byAdding: .day, value: -7 * (weeks - 1), to: thisMonday)!
        let byDay = Dictionary(history.map { ($0.day, $0) }, uniquingKeysWith: { a, _ in a })
        let values = history.map { metric.value($0) }
        let t = HeatLevel.thresholds(values)

        VStack(alignment: .leading, spacing: 6) {
            Text(hover.map { d in "\(dayLabel(d)) · " + (byDay[d].map { metric.format(metric.value($0)) + " · " + UsageFmt.cost($0.cost) + " · \($0.requests) 次请求" } ?? "无记录") } ?? " ")
                .font(.system(size: 11.5)).foregroundStyle(Theme.secondary).monospacedDigit()
            GeometryReader { g in
                let labelW: CGFloat = 22, top: CGFloat = 16
                let step = min((g.size.width - labelW) / CGFloat(weeks), (g.size.height - top) / 7)
                let cell = step - 3
                Canvas { ctx, _ in
                    // 月份
                    var lastMonth = -1
                    for w in 0..<weeks {
                        let d = cal.date(byAdding: .day, value: 7 * w, to: start)!
                        let m = cal.component(.month, from: d)
                        if m != lastMonth && cal.component(.day, from: d) <= 7 {
                            ctx.draw(Text("\(m)月").font(Theme.mono(9.5)).foregroundStyle(Theme.tertiary),
                                     at: CGPoint(x: labelW + CGFloat(w) * step, y: 6), anchor: .leading)
                        }
                        lastMonth = m
                    }
                    for (i, n) in weekdayNames.enumerated() where i % 2 == 0 {
                        ctx.draw(Text(n).font(.system(size: 9.5)).foregroundStyle(Theme.tertiary),
                                 at: CGPoint(x: 0, y: top + CGFloat(i) * step + cell / 2), anchor: .leading)
                    }
                    var glowCells = Path()
                    for w in 0..<weeks {
                        for r in 0..<7 {
                            let d = cal.date(byAdding: .day, value: 7 * w + r, to: start)!
                            if d > today { continue }
                            let lv = HeatLevel.level(byDay[d].map(metric.value) ?? 0, t)
                            let rect = CGRect(x: labelW + CGFloat(w) * step, y: top + CGFloat(r) * step, width: cell, height: cell)
                            let p = Path(roundedRect: rect, cornerRadius: cell * 0.22)
                            ctx.fill(p, with: .color(.white.opacity(HeatLevel.opacity[lv])))
                            if lv == 4 { glowCells.addPath(p) }
                            if d == today || d == hover {
                                ctx.stroke(Path(roundedRect: rect.insetBy(dx: -1.5, dy: -1.5), cornerRadius: cell * 0.3),
                                           with: .color(d == hover ? .white : Theme.heat.opacity(0.9)), lineWidth: 1)
                            }
                        }
                    }
                    var glow = ctx
                    glow.addFilter(.shadow(color: .white.opacity(0.7), radius: 4))
                    glow.fill(glowCells, with: .color(.white))
                }
                .onContinuousHover { phase in
                    switch phase {
                    case let .active(p):
                        let w = Int((p.x - labelW) / step), r = Int((p.y - top) / step)
                        if w >= 0, w < weeks, r >= 0, r < 7, let d = cal.date(byAdding: .day, value: 7 * w + r, to: start), d <= today {
                            hover = d
                        } else { hover = nil }
                    case .ended: hover = nil
                    }
                }
            }
        }
    }
}

/// 星期 × 24 小时
private struct HourHeatmap: View {
    let hourly: [HourlyUsage]
    let metric: UsageMetric
    @State private var hover: (Int, Int)?

    var body: some View {
        let cal = Calendar.current
        var grid = Array(repeating: Array(repeating: 0.0, count: 24), count: 7)
        for h in hourly {
            grid[weekdayIndex(h.hour)][cal.component(.hour, from: h.hour)] += metric.value(h)
        }
        let t = HeatLevel.thresholds(grid.flatMap { $0 })
        return VStack(alignment: .leading, spacing: 6) {
            Text(hover.map { "周\(weekdayNames[$0.0]) \($0.1):00–\($0.1 + 1):00 · 近 30 天合计 " + metric.format(grid[$0.0][$0.1]) } ?? " ")
                .font(.system(size: 11.5)).foregroundStyle(Theme.secondary).monospacedDigit()
            GeometryReader { g in
                let labelW: CGFloat = 22, bottom: CGFloat = 16
                let stepX = (g.size.width - labelW) / 24, stepY = (g.size.height - bottom) / 7
                Canvas { ctx, _ in
                    for (i, n) in weekdayNames.enumerated() {
                        ctx.draw(Text(n).font(.system(size: 9.5)).foregroundStyle(Theme.tertiary),
                                 at: CGPoint(x: 0, y: CGFloat(i) * stepY + stepY / 2), anchor: .leading)
                    }
                    for hr in stride(from: 0, through: 21, by: 3) {
                        ctx.draw(Text("\(hr)").font(Theme.mono(9.5)).foregroundStyle(Theme.tertiary),
                                 at: CGPoint(x: labelW + CGFloat(hr) * stepX, y: g.size.height - 6), anchor: .leading)
                    }
                    var glowCells = Path()
                    for r in 0..<7 {
                        for c in 0..<24 {
                            let lv = HeatLevel.level(grid[r][c], t)
                            let rect = CGRect(x: labelW + CGFloat(c) * stepX, y: CGFloat(r) * stepY, width: stepX - 3, height: stepY - 3)
                            let p = Path(roundedRect: rect, cornerRadius: 3)
                            ctx.fill(p, with: .color(.white.opacity(HeatLevel.opacity[lv])))
                            if lv == 4 { glowCells.addPath(p) }
                            if let h = hover, h.0 == r, h.1 == c {
                                ctx.stroke(Path(roundedRect: rect.insetBy(dx: -1.5, dy: -1.5), cornerRadius: 4), with: .color(.white), lineWidth: 1)
                            }
                        }
                    }
                    var glow = ctx
                    glow.addFilter(.shadow(color: .white.opacity(0.7), radius: 4))
                    glow.fill(glowCells, with: .color(.white))
                }
                .onContinuousHover { phase in
                    switch phase {
                    case let .active(p):
                        let c = Int((p.x - labelW) / stepX), r = Int(p.y / stepY)
                        hover = (c >= 0 && c < 24 && r >= 0 && r < 7) ? (r, c) : nil
                    case .ended: hover = nil
                    }
                }
            }
        }
    }
}

/// 使用习惯：活跃天数、连续天数、高峰日、高峰时段
private struct HabitStats: View {
    let history: [DailyUsage]
    let hourly: [HourlyUsage]
    let metric: UsageMetric

    var body: some View {
        let active = history.filter { $0.tokens.total > 0 }
        let peak = history.max { metric.value($0) < metric.value($1) }
        let hours = hourTotals
        let peakHour = hours.indices.max { hours[$0] < hours[$1] }
        let total = active.reduce(0) { $0 + metric.value($1) }
        Panel {
            Eyebrow("HABITS · 使用习惯")
            VStack(spacing: 12) {
                row("活跃天数", "\(active.count) 天")
                row("当前连续", "\(streak(current: true)) 天")
                row("最长连续", "\(streak(current: false)) 天")
                row("最忙的一天", peak.flatMap { metric.value($0) > 0 ? dayLabel($0.day) : nil } ?? "—")
                row("当天用量", peak.map { metric.format(metric.value($0)) } ?? "—")
                row("高峰时段", peakHour.flatMap { hours[$0] > 0 ? "\($0):00–\($0 + 1):00" : nil } ?? "—")
                row("活跃日均", active.isEmpty ? "—" : metric.format(total / Double(active.count)))
            }
        }
    }

    private var hourTotals: [Double] {
        var hours = Array(repeating: 0.0, count: 24)
        for h in hourly { hours[Calendar.current.component(.hour, from: h.hour)] += metric.value(h) }
        return hours
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack { Text(k).foregroundStyle(Theme.secondary); Spacer(); Text(v).monospacedDigit() }
            .font(.system(size: 12.5))
    }

    /// 连续使用的天数；current 时从今天（今天没用就从昨天）往回数
    private func streak(current: Bool) -> Int {
        let used = history.map { $0.tokens.total > 0 }
        if current {
            var i = used.count - 1
            if i >= 0 && !used[i] { i -= 1 }
            var n = 0
            while i >= 0 && used[i] { n += 1; i -= 1 }
            return n
        }
        var best = 0, run = 0
        for u in used { run = u ? run + 1 : 0; best = max(best, run) }
        return best
    }
}

// MARK: - 缓存

private struct CacheTab: View {
    let tools: [ToolUsage]
    @Binding var filter: UsageFilter

    var body: some View {
        let daily = UsageData.mergedDaily(tools)
        let t30 = daily.reduce(TokenCounts()) { $0 + $1.tokens }
        let today = daily.last?.tokens ?? TokenCounts()
        let savings = daily.reduce(0) { $0 + $1.cacheSavings }
        let w1h = daily.reduce(Int64(0)) { $0 + $1.cacheWrite1h }
        let hit30 = t30.hitRate ?? 0, hitToday = today.hitRate
        VStack(spacing: 14) {
            HStack(spacing: 14) {
                StatTile(title: "HIT RATE · 近 30 天", value: (String(format: "%.1f", hit30 * 100), "%"),
                         caption: "缓存读 \(UsageFmt.tokens(t30.cacheRead)) / 输入侧 \(UsageFmt.tokens(t30.input + t30.cacheRead + t30.cacheWrite))")
                StatTile(title: "HIT RATE · 今日", value: (hitToday.map { String(format: "%.1f", $0 * 100) } ?? "--", "%"),
                         caption: hitToday.map { h in h >= hit30 ? "比 30 天平均高 \(String(format: "%.1f", (h - hit30) * 100)) 点" : "比 30 天平均低 \(String(format: "%.1f", (hit30 - h) * 100)) 点" } ?? "今天还没有请求",
                         alert: (hitToday ?? 1) < hit30 - 0.1)
                StatTile(title: "SAVED · 缓存省下", value: costParts(savings), caption: "按 API 价折算")
                StatTile(title: "CACHE WRITE", value: UsageFmt.tokenParts(t30.cacheWrite),
                         caption: t30.cacheWrite > 0 ? "1 小时缓存占 \(Fmt.percent(Double(w1h) / Double(t30.cacheWrite))) · 其余 5 分钟" : "近 30 天没有缓存写入")
            }
            .frame(height: 128)
            .fixedSize(horizontal: false, vertical: true)
            Panel {
                HStack {
                    Eyebrow("COMPOSITION · 每天的 token 构成与命中率")
                    Spacer()
                    FilterBar(filter: $filter)
                }
                CompositionChart(daily: daily)
            }
            .frame(maxHeight: .infinity)
            HStack(alignment: .top, spacing: 14) {
                Panel {
                    Eyebrow("LAST 48H · 每小时命中率")
                    HourlyHitChart(hourly: UsageData.mergedHourly(tools))
                }
                ModelCachePanel(tools: tools)
            }
            .frame(height: 210)
        }
    }

    private func costParts(_ c: Double) -> (String, String) {
        c >= 1000 ? (String(format: "%.1f", c / 1000), "K USD") : (String(format: "%.0f", c), "USD")
    }
}

/// 30 天的 100% 堆叠柱（缓存读 / 缓存写 / 输入 / 输出）+ 命中率丝线
private struct CompositionChart: View {
    let daily: [DailyUsage]
    @State private var hover: Int?

    private static let parts: [(String, Double)] = [("缓存读", 0.85), ("缓存写", 0.45), ("输入", 0.25), ("输出", 0.12)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                ForEach(Self.parts, id: \.0) { name, o in
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 2).fill(.white.opacity(o)).frame(width: 10, height: 10)
                        Text(name)
                    }
                }
                HStack(spacing: 5) {
                    Capsule().fill(Theme.heat).frame(width: 14, height: 2).shadow(color: Theme.heat, radius: 3)
                    Text("命中率")
                }
                Spacer()
                Text(hover.map { i in detail(daily[i]) } ?? "把鼠标移到柱子上看当天明细")
                    .foregroundStyle(hover == nil ? Theme.tertiary : Theme.secondary)
                    .monospacedDigit()
            }
            .font(.system(size: 11.5))
            GeometryReader { g in
                let n = max(daily.count, 1)
                let rightAxis: CGFloat = 40, bottom: CGFloat = 16, top: CGFloat = 8
                let w = g.size.width - rightAxis, h = g.size.height - bottom - top
                let step = w / CGFloat(n), bar = step * 0.56
                let maxTotal = Double(max(daily.map(\.tokens.total).max() ?? 1, 1))
                let lo = Self.hitFloor(daily)
                Canvas { ctx, _ in
                    // 右轴是命中率（自动取下限，平时都在 90% 以上，从 0 画会是一条直线）
                    for f in [0.0, 0.5, 1.0] {
                        let y = top + h - CGFloat(f) * h
                        var p = Path(); p.move(to: .init(x: 0, y: y)); p.addLine(to: .init(x: w, y: y))
                        ctx.stroke(p, with: .color(.white.opacity(0.08)), style: StrokeStyle(lineWidth: 0.6, dash: [2, 4]))
                        ctx.draw(Text("\(Int(((lo + (1 - lo) * f) * 100).rounded()))%").font(Theme.mono(9.5)).foregroundStyle(Theme.heat.opacity(0.8)),
                                 at: CGPoint(x: g.size.width, y: y), anchor: .trailing)
                    }
                    var hitPts: [CGPoint] = []
                    for (i, d) in daily.enumerated() {
                        let t = d.tokens
                        let x = CGFloat(i) * step + (step - bar) / 2
                        let dim = hover == nil || hover == i ? 1.0 : 0.55
                        // 柱高 = 当天总量（相对 30 天最大值），柱内按缓存读 / 缓存写 / 输入 / 输出分段
                        var y = top + h
                        for (v, o) in [(t.cacheRead, 0.85), (t.cacheWrite, 0.45), (t.input, 0.25), (t.output, 0.12)] {
                            let bh = CGFloat(Double(v) / maxTotal) * h
                            guard bh > 0 else { continue }
                            y -= bh
                            ctx.fill(Path(roundedRect: CGRect(x: x, y: y, width: bar, height: max(bh - (bh > 3 ? 1 : 0), 0.8)), cornerRadius: 1.5),
                                     with: .color(.white.opacity(o * dim)))
                        }
                        if t.total == 0 {
                            ctx.fill(Path(roundedRect: CGRect(x: x, y: top + h - 2, width: bar, height: 2), cornerRadius: 1), with: .color(.white.opacity(0.08)))
                        }
                        if let r = t.hitRate { hitPts.append(CGPoint(x: x + bar / 2, y: top + h - CGFloat(max(r - lo, 0) / (1 - lo)) * h)) }
                        if i % 5 == 0 || i == n - 1 {
                            let c = Calendar.current.dateComponents([.month, .day], from: d.day)
                            ctx.draw(Text(i == n - 1 ? "今天" : "\(c.month ?? 0)/\(c.day ?? 0)").font(Theme.mono(9.5)).foregroundStyle(Theme.tertiary),
                                     at: CGPoint(x: x + bar / 2, y: g.size.height - 5))
                        }
                    }
                    var line = ctx
                    line.addFilter(.shadow(color: Theme.heat.opacity(0.9), radius: 3))
                    line.stroke(smoothPath(hitPts), with: .color(Theme.heat), lineWidth: 1.4)
                    for p in hitPts {
                        ctx.fill(Path(ellipseIn: CGRect(x: p.x - 2, y: p.y - 2, width: 4, height: 4)), with: .color(Theme.heat))
                    }
                }
                .onContinuousHover { phase in
                    switch phase {
                    case let .active(p):
                        let i = Int(p.x / step)
                        hover = (i >= 0 && i < daily.count && p.x <= w) ? i : nil
                    case .ended: hover = nil
                    }
                }
            }
        }
    }

    /// 命中率轴的下限：比最低的一天再低 5 个点，取整到 10%
    static func hitFloor(_ daily: [DailyUsage]) -> Double {
        let m = daily.compactMap(\.tokens.hitRate).min() ?? 0.9
        return max(min((floor((m - 0.05) * 10) / 10), 0.9), 0)
    }

    private func detail(_ d: DailyUsage) -> String {
        let t = d.tokens
        return "\(dayLabel(d.day)) · 命中 \(t.hitRate.map { String(format: "%.1f%%", $0 * 100) } ?? "—") · 读 \(UsageFmt.tokens(t.cacheRead)) · 写 \(UsageFmt.tokens(t.cacheWrite)) · 入 \(UsageFmt.tokens(t.input)) · 出 \(UsageFmt.tokens(t.output))"
    }
}

/// 最近 48 小时每小时的命中率（没请求的小时沿用上一小时，图不断开）
private struct HourlyHitChart: View {
    let hourly: [HourlyUsage]

    var body: some View {
        let cal = Calendar.current
        let now = cal.dateInterval(of: .hour, for: Date())!.start
        let byHour = Dictionary(hourly.map { ($0.hour, $0) }, uniquingKeysWith: { a, _ in a })
        var last = 0.0
        var reqs: [Double] = []
        let rates: [Double] = (0..<48).map { k in
            let h = cal.date(byAdding: .hour, value: k - 47, to: now)!
            reqs.append(Double(byHour[h]?.requests ?? 0))
            if let r = byHour[h]?.tokens.hitRate { last = r }
            return last
        }
        let maxReq = max(reqs.max() ?? 1, 1)
        let lo = max(min(floor(((rates.filter { $0 > 0 }.min() ?? 0.9) - 0.05) * 10) / 10, 0.9), 0)
        GeometryReader { g in
            let h = g.size.height
            ZStack(alignment: .bottomLeading) {
                ThreadChart(layers: [
                    ThreadLayer(data: rates.map { max($0 - lo, 0) / (1 - lo) }, base: h - 4, amp: h - 12, spread: 4, seed: 61, energy: 0.3,
                                strokes: [(Theme.accent, 0.6), (Theme.accent, 0.45), (Theme.accent, 0.4)]),
                    ThreadLayer(data: reqs.map { $0 / maxReq * 0.35 }, base: h - 4, amp: h - 12, spread: 2, seed: 67, energy: 0.2,
                                strokes: [(Theme.dim(0.4), 0.5)], markers: .none),
                ], baseline: h - 4, period: 5.6)
                HStack {
                    Text("48 小时前"); Spacer(); Text("纵轴 \(Int(lo * 100))%–100% · 细线 = 请求数")
                    Spacer(); Text("现在")
                }
                .font(Theme.mono(9.5)).foregroundStyle(Theme.tertiary)
                .offset(y: 14)
            }
        }
        .padding(.bottom, 12)
    }
}

/// 各模型的缓存命中率
private struct ModelCachePanel: View {
    let tools: [ToolUsage]

    var body: some View {
        let models = tools.flatMap(\.models).filter { $0.detail.total > 0 }.sorted { $0.detail.total > $1.detail.total }.prefix(5)
        Panel {
            HStack {
                Eyebrow("BY MODEL · 模型命中率")
                Spacer()
                Text("缓存读 · 缓存写").font(Theme.mono(9.5)).tracking(0.8).foregroundStyle(Theme.tertiary)
            }
            if models.isEmpty {
                Text("还没有分模型的缓存数据").font(.system(size: 12)).foregroundStyle(Theme.tertiary)
            }
            VStack(spacing: 9) {
                ForEach(Array(models)) { m in
                    HStack(spacing: 10) {
                        Text(m.model).lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
                        DotMeter(fraction: m.detail.hitRate ?? 0, count: 10, seed: 3)
                        Text(m.detail.hitRate.map { String(format: "%.0f%%", $0 * 100) } ?? "—").frame(width: 36, alignment: .trailing)
                        Text("\(UsageFmt.tokens(m.detail.cacheRead)) · \(UsageFmt.tokens(m.detail.cacheWrite))")
                            .foregroundStyle(Theme.secondary).frame(width: 96, alignment: .trailing)
                    }
                }
            }
            .font(.system(size: 12)).monospacedDigit()
        }
    }
}

// MARK: - 请求明细

// MARK: - 共用表格行

/// 一行：名称（下方小字标签）+ 占比条 + 请求 / token / 金额
struct ShareRow: View {
    let name: String
    let tag: String
    let share: Double
    let requests: Int
    let tokens: Int64
    let cost: Double

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name).lineLimit(1).truncationMode(.middle)
                Text(tag).font(.system(size: 10.5)).foregroundStyle(Theme.tertiary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.08))
                        Capsule().fill(Theme.accent).frame(width: max(g.size.width * share, 2))
                            .shadow(color: Theme.accent.opacity(0.8), radius: 3)
                    }
                }
                .frame(width: 170, height: 3)
                Text(Fmt.percent(share)).font(.system(size: 11)).foregroundStyle(Theme.secondary).frame(width: 40, alignment: .trailing)
            }
            .frame(width: 220, alignment: .leading)
            Text(requests > 0 ? "\(requests)" : "—").frame(width: 56, alignment: .trailing)
            Text(UsageFmt.tokens(tokens)).frame(width: 64, alignment: .trailing)
            Text(cost > 0 ? UsageFmt.cost(cost) : "—").frame(width: 72, alignment: .trailing)
        }
        .font(.system(size: 12)).monospacedDigit()
        .padding(.vertical, 5)
    }
}
